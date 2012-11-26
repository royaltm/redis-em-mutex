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
    described_class.setup(redis: @redis_pool)
    described_class.class_variable_get(:'@@redis_pool').should be @redis_pool
    redis = described_class.class_variable_get(:'@@redis_watcher')
    described_class.stop_watcher
    redis.should be_an_instance_of Redis
    redis.client.host.should eq 'localhost'
    redis.client.db.should eq 1
    redis.client.scheme.should eq 'redis'
  end

  it "should setup with various options" do
    described_class.setup do |cfg|
      cfg.expire = 42 #   - sets global Mutex.default_expire 
      cfg.ns = 'redis rulez!' #       - sets global Mutex.namespace
      cfg.reconnect_max = -1 # - maximum num. of attempts to re-establish
      cfg.url = 'redis://127.0.0.1/2'
      cfg.size = 10
    end
    described_class.namespace.should eq 'redis rulez!'
    described_class.default_expire.should eq 42
    described_class.class_variable_get(:'@@connection_retry_max').should eq -1
    redis_pool = described_class.class_variable_get(:'@@redis_pool')
    redis_pool.should be_an_instance_of EM::Synchrony::ConnectionPool
    redis_pool.should_not be @redis_pool
    redis_pool.client.host.should eq '127.0.0.1'
    redis_pool.client.db.should eq 2
    redis_pool.client.port.should eq 6379
    redis_pool.client.scheme.should eq 'redis'
    redis = described_class.class_variable_get(:'@@redis_watcher')
    described_class.stop_watcher
    redis.should be_an_instance_of Redis
    redis.client.host.should eq '127.0.0.1'
    redis.client.db.should eq 2
    redis.client.port.should eq 6379
    redis.client.scheme.should eq 'redis'
  end

  it "should setup with separate redis options" do
    described_class.setup do |cfg|
      cfg.scheme = 'redis'
      cfg.host = 'localhost'
      cfg.port = 6379
      cfg.db = 3
    end
    redis_pool = described_class.class_variable_get(:'@@redis_pool')
    redis_pool.should be_an_instance_of EM::Synchrony::ConnectionPool
    redis_pool.should_not be @redis_pool
    redis_pool.client.host.should eq 'localhost'
    redis_pool.client.db.should eq 3
    redis_pool.client.port.should eq 6379
    redis_pool.client.scheme.should eq 'redis'
    redis = described_class.class_variable_get(:'@@redis_watcher')
    redis.should be_an_instance_of Redis
    described_class.stop_watcher
    redis.client.host.should eq 'localhost'
    redis.client.db.should eq 3
    redis.client.port.should eq 6379
    redis.client.scheme.should eq 'redis'  
  end

  it "should be able to sleep" do
    t = Time.now
    described_class.sleep 0.11
    (Time.now - t).should be_within(0.02).of(0.11)
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

  before(:all) do
    @redis_pool = EM::Synchrony::ConnectionPool.new(size: 10) { Redis.new url: 'redis://localhost/1' }
  end
end
