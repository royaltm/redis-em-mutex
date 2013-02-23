$:.unshift "lib"
require 'em-synchrony'
require 'redis/em-connection-pool'
require 'redis-em-mutex'

class TestDummyConnectionPool < Redis::EM::ConnectionPool; end

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
    redis = described_class.instance_variable_get(:'@redis_watcher')
    described_class.stop_watcher
    redis.should be_an_instance_of Redis
    redis.client.host.should eq 'localhost'
    redis.client.db.should eq 1
    redis.client.scheme.should eq 'redis'
  end

  it "should setup with various options" do
    described_class.setup do |cfg|
      cfg.expire = 42                # - sets global Mutex.default_expire
      cfg.ns = 'redis rulez!'        # - sets global Mutex.namespace
      cfg.reconnect_max = :forever   # - maximum num. of attempts to re-establish
      cfg.url = 'redis://127.0.0.1/2'
      cfg.size = 10
    end
    described_class.namespace.should eq 'redis rulez!'
    described_class.default_expire.should eq 42
    described_class.reconnect_forever?.should be true
    described_class.instance_variable_get(:'@reconnect_max_retries').should eq -1
    described_class.reconnect_max_retries = 0
    described_class.reconnect_forever?.should be false
    redis_pool = described_class.class_variable_get(:'@@redis_pool')
    redis_pool.should be_an_instance_of Redis::EM::ConnectionPool
    redis_pool.should_not be @redis_pool
    redis_pool.client.host.should eq '127.0.0.1'
    redis_pool.client.db.should eq 2
    redis_pool.client.port.should eq 6379
    redis_pool.client.scheme.should eq 'redis'
    redis = described_class.instance_variable_get(:'@redis_watcher')
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
      cfg.connection_pool_class = TestDummyConnectionPool
    end
    redis_pool = described_class.class_variable_get(:'@@redis_pool')
    redis_pool.should be_an_instance_of TestDummyConnectionPool
    redis_pool.should_not be @redis_pool
    redis_pool.client.host.should eq 'localhost'
    redis_pool.client.db.should eq 3
    redis_pool.client.port.should eq 6379
    redis_pool.client.scheme.should eq 'redis'
    redis = described_class.instance_variable_get(:'@redis_watcher')
    redis.should be_an_instance_of Redis
    described_class.stop_watcher
    redis.client.host.should eq 'localhost'
    redis.client.db.should eq 3
    redis.client.port.should eq 6379
    redis.client.scheme.should eq 'redis'  
  end

  it "should be able to setup with redis factory" do
    counter = 0
    described_class.setup do |cfg|
      cfg.redis = @redis_pool
      cfg.redis_factory = proc do |opts|
        counter += 1
        Redis.new opts
      end
    end
    counter.should eq 1
    counter = 0
    described_class.setup do |cfg|
      cfg.size = 5
      cfg.redis_factory = proc do |opts|
        counter += 1
        Redis.new opts
      end
    end
    counter.should eq 6
  end

  it "should be able to sleep" do
    t = Time.now
    described_class.sleep 0.11
    (Time.now - t).should be_within(0.02).of(0.11)
  end

  it "should not change uuid" do
    @uuid.should be_an_instance_of String
    described_class.class_variable_get(:@@uuid).should eq @uuid
  end

  it "owner_ident should begin with uuid and end with owner id" do
    ident = described_class.new(:dummy).owner_ident
    ident.should start_with(@uuid)
    ident.should end_with(Fiber.current.__id__.to_s)
    ident = described_class.new(:dummy, owner:'__me__').owner_ident
    ident.should start_with(@uuid)
    ident.should end_with('__me__')
  end

  context "Mutex implementation handlers:" do
    it "should select desired handler" do
      described_class.setup
      expected_name = case ENV['REDIS_EM_MUTEX_HANDLER']
      when /pure/i
        described_class.handler.should eq 'Redis::EM::Mutex::PureHandlerMixin'
      when /script/i
        described_class.handler.should eq 'Redis::EM::Mutex::ScriptHandlerMixin'
      end
      described_class.setup(handler: :pUrE)
      described_class.handler.should eq Redis::EM::Mutex::PureHandlerMixin.name
      described_class.setup
      described_class.handler.should eq Redis::EM::Mutex::PureHandlerMixin.name
      described_class.setup {|opts| opts.handler = 'ScRiPt'}
      described_class.handler.should eq Redis::EM::Mutex::ScriptHandlerMixin.name
      described_class.setup
      described_class.handler.should eq Redis::EM::Mutex::ScriptHandlerMixin.name
      described_class.setup {|opts| opts.handler = Redis::EM::Mutex::PureHandlerMixin}
      described_class.handler.should eq Redis::EM::Mutex::PureHandlerMixin.name
      described_class.setup(handler: Redis::EM::Mutex::ScriptHandlerMixin)
      described_class.handler.should eq Redis::EM::Mutex::ScriptHandlerMixin.name
      described_class.setup {|opts| opts.handler = :auto}
      other_handler, other_name = case described_class.handler
      when Redis::EM::Mutex::ScriptHandlerMixin.name
        [:pure, Redis::EM::Mutex::PureHandlerMixin.name]
      when Redis::EM::Mutex::PureHandlerMixin.name
        [:script, Redis::EM::Mutex::ScriptHandlerMixin.name]
      end
      other_handler.should_not be_nil
      other_name.should_not be_nil
      described_class.setup(handler: other_handler)
      described_class.handler.should eq other_name
      described_class.setup(handler: :auto)
      described_class.handler.should_not eq other_name
    end

    it "should select pure handler with SCRIPT unsupporting redis-server" do
      pool = Redis::EM::ConnectionPool.new(size: 1) { Redis.new }
      pool.should_receive(:script).with(:exists).
        and_raise(Redis::CommandError)
      described_class.setup(redis: pool, handler: :auto)
      described_class.handler.should eq Redis::EM::Mutex::PureHandlerMixin.name
    end

    it "should select script handler with SCRIPT aware redis-server" do
      pool = Redis::EM::ConnectionPool.new(size: 1) { Redis.new }
      pool.should_receive(:script).with(:exists).
        and_return(false)
      described_class.setup(redis: pool, handler: :auto)
      described_class.handler.should eq Redis::EM::Mutex::ScriptHandlerMixin.name
    end

  end

  around(:each) do |testcase|
    @after_em_stop = nil
    @exception = nil
    ::EM.synchrony do
      begin
        testcase.call
        raise @exception if @exception
        described_class.stop_watcher
      rescue => e
        described_class.stop_watcher(true)
        raise e
      ensure
        ::EM.stop
      end
    end
    @after_em_stop.call if @after_em_stop
  end

  before(:all) do
    @redis_pool = Redis::EM::ConnectionPool.new(size: 10) { Redis.new url: 'redis://localhost/1' }
    @uuid = described_class.class_variable_get(:@@uuid)
  end
end
