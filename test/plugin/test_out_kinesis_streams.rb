#
# Copyright 2014-2017 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You
# may not use this file except in compliance with the License. A copy of
# the License is located at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# or in the "license" file accompanying this file. This file is
# distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF
# ANY KIND, either express or implied. See the License for the specific
# language governing permissions and limitations under the License.

require_relative '../helper'
require 'fluent/plugin/out_kinesis_streams'

class KinesisStreamsOutputTest < Test::Unit::TestCase
  KB = 1024
  MB = 1024 * KB

  def setup
    ENV['AWS_REGION'] = 'ap-northeast-1'
    ENV['AWS_ACCESS_KEY_ID'] = 'AAAAAAAAAAAAAAAAAAAA'
    ENV['AWS_SECRET_ACCESS_KEY'] = 'ffffffffffffffffffffffffffffffffffffffff'
    Fluent::Test.setup
    @server = DummyServer.start
  end

  def teardown
    ENV.delete('AWS_REGION')
    ENV.delete('AWS_ACCESS_KEY_ID')
    ENV.delete('AWS_SECRET_ACCESS_KEY')
    @server.clear
  end

  def default_config
    %[
      stream_name test-stream
      log_level error

      retries_on_batch_request 10
      endpoint https://localhost:#{@server.port}
      ssl_verify_peer false
    ]
  end

  def create_driver(conf = default_config)
    if fluentd_v0_12?
      Fluent::Test::BufferedOutputTestDriver.new(Fluent::KinesisStreamsOutput) do
      end.configure(conf)
    else
      Fluent::Test::Driver::Output.new(Fluent::KinesisStreamsOutput) do
      end.configure(conf)
    end
  end

  def self.data_of(size, char = 'a')
    partition_key_size = 32
    char.b * ((size - partition_key_size)/char.b.size)
  end

  def data_of(size, char = 'a')
    self.class.data_of(size, char)
  end

  def test_configure
    d = create_driver
    assert_equal 'test-stream', d.instance.stream_name
    assert_equal 'ap-northeast-1' , d.instance.region
  end

  def test_region
    d = create_driver(default_config + "region us-east-1")
    assert_equal 'us-east-1', d.instance.region
  end

  data(
    'json' => ['json', '{"a":1,"b":2}'],
    'ltsv' => ['ltsv', "a:1\tb:2"],
  )
  def test_format(data)
    formatter, expected = data
    d = create_driver(default_config + "format #{formatter}")
    driver_run(d, [{"a"=>1,"b"=>2}])
    assert_equal expected + "\n", @server.records.first
  end

  def test_partition_key_not_found
    d = create_driver(default_config + "partition_key partition_key")
    driver_run(d, [{"a"=>1}])
    assert_equal 0, @server.records.size
    assert_equal 1, d.instance.log.out.logs.size
  end

  def test_data_key
    d = create_driver(default_config + "data_key a")
    driver_run(d, [{"a"=>1,"b"=>2}, {"b"=>2}])
    assert_equal "1", @server.records.first
    assert_equal 1, @server.records.size
    assert_equal 1, d.instance.log.out.logs.size
  end

  def test_max_record_size
    d = create_driver(default_config + "data_key a")
    driver_run(d, [
      {"a"=>data_of(1*MB)},
      {"a"=>data_of(1*MB+1)}, # exceeded
    ])
    assert_equal 1, @server.records.size
    assert_equal 1, d.instance.log.out.logs.size
  end

  def test_max_record_size_multi_bytes
    d = create_driver(default_config + "data_key a")
    driver_run(d, [
      {"a"=>data_of(1*MB, 'あ')},
      {"a"=>data_of(1*MB+6, 'あ')}, # exceeded
    ])
    assert_equal 1, @server.records.size
    assert_equal 1, d.instance.log.out.logs.size
  end

  def test_single_max_record_size
    d = create_driver(default_config + "data_key a")
    driver_run(d, [
      {"a"=>data_of(1*MB+1)}, # exceeded
    ])
    assert_equal 0, @server.records.size
    assert_equal 0, @server.error_count
    assert_equal 1, d.instance.log.out.logs.size
  end

  data(
    'split_by_count'           => [Array.new(501, data_of(1*KB)),                     [500,1]],
    'split_by_size'            => [Array.new(257, data_of(20*KB)),                    [256,1]],
    'split_by_size_with_space' => [Array.new(255, data_of(20*KB))+[data_of(20*KB+1)], [255,1]],
    'no_split_by_size'         => [Array.new(256, data_of(20*KB)),                    [256]],
  )
  def test_batch_request(data)
    records, expected = data
    d = create_driver(default_config + "data_key a")
    driver_run(d, records.map{|record| {'a' => record}})
    assert_equal records.size, @server.records.size
    assert_equal expected, @server.count_per_requests
    @server.size_per_requests.each do |size|
      assert size <= 5*MB
    end
    @server.count_per_requests.each do |count|
      assert count <= 500
    end
  end

  def test_multibyte_input
    d = create_driver(default_config)
    record = {"a" => "てすと"}
    driver_run(d, [record])
    assert_equal 0, d.instance.log.out.logs.size
    assert_equal (record.to_json + "\n").b, @server.records.first 
  end

  def test_record_count
    @server.enable_random_error
    d = create_driver
    count = 10
    driver_run(d, count.times.map{|i|{"a"=>1}})
    assert_equal count, @server.records.size
    assert @server.failed_count > 0
    assert @server.error_count > 0
  end
end
