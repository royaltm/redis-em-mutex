$:.unshift "lib"
require 'em-synchrony'
require 'em-synchrony/connection_pool'
require 'redis-em-mutex'

describe Redis::EM::Mutex do

  it "should raise MutexError while redis server not found on setup" do
    expect {
      described_class.setup(host: 'abcdefghijklmnopqrstuvwxyz', reconnect_max: 0)
    }.to raise_error(described_class::MutexError, /Can not establish watcher channel connection!/)

    expect {
      described_class.setup(host: '255.255.255.255', reconnect_max: 0)
    }.to raise_error(described_class::MutexError, /Can not establish watcher channel connection!/)

    expect {
      described_class.setup(port: 65535, reconnect_max: 0)
    }.to raise_error(described_class::MutexError, /Can not establish watcher channel connection!/)
  end

  it "should setup with redis connection pool" do
    redis_pool = EM::Synchrony::ConnectionPool.new(size: 10) { Redis.new url: 'redis://localhost/1' }
    described_class.setup(redis: redis_pool)
    described_class.class_variable_get(:'@@redis_pool').should be redis_pool
    redis = described_class.class_variable_get(:'@@redis_watcher')
    described_class.stop_watcher
    redis.should be_an_instance_of Redis
    redis.client.host.should eq 'localhost'
    redis.client.db.should eq 1
    redis.client.scheme.should eq 'redis'
  end

  around(:each) do |testcase|
    @after_em_stop = nil
    ::EM.synchrony do
      begin
        testcase.call
      ensure
        ::EM.stop
      end
    end
    @after_em_stop.call if @after_em_stop
  end

end
