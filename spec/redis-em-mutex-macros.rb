$:.unshift "lib"
require 'securerandom'
require 'em-synchrony'
require 'em-synchrony/fiber_iterator'
require 'redis-em-mutex'

class Test
  include Redis::EM::Mutex::Macro
  auto_mutex :method5
  def method1; end
  auto_mutex
  def method2; end
  no_auto_mutex
  def method3; end
  def method4; end
  def method5; end
  auto_mutex :method4
  def method6; end
  auto_mutex :method6, :method7, block: 10, on_timeout: proc { }
  def method7; end

  auto_mutex block: 20

  auto_mutex
  def test(redis, key, value)
    redis.set key, value
    ::EM::Synchrony.sleep 0.1
    redis.get key
  end

  def recursive(n=1, &blk)
    if n < 10
      recursive(n+1, &blk)
    else
      yield n
    end
  end

  no_auto_mutex
  def test_no_mutex(redis, key, value)
    redis.set key, value
    ::EM::Synchrony.sleep 0.1
    redis.get key
  end

  auto_mutex :may_timeout, block: 0, on_timeout: proc { false }
  def may_timeout; yield; end

  auto_mutex :may_timeout_no_fallback, block: 0
  def may_timeout_no_fallback; yield; end

  auto_mutex :may_timeout_method_fallback, block: 0, on_timeout: :may_timeout_timed_out
  def may_timeout_method_fallback; yield; end
  def may_timeout_timed_out; false; end

end

describe Redis::EM::Mutex::Macro do

  it "should define auto_mutex methods" do
    Test.auto_mutex_methods.keys.should eq [:method5, :method4, :method6, :method7, :may_timeout,
        :may_timeout_no_fallback, :may_timeout_method_fallback]
    [:method5, :method2, :method4, :test, :recursive,
        :may_timeout_no_fallback, :may_timeout_method_fallback].each do |name|
      Test.method_defined?(name).should be_true
      Test.method_defined?("#{name}_without_auto_mutex").should be_true
      Test.method_defined?("#{name}_with_auto_mutex").should be_true
      Test.method_defined?("#{name}_on_timeout_auto_mutex").should be_false
    end
    [:method6, :method7, :may_timeout].each do |name|
      Test.method_defined?(name).should be_true
      Test.method_defined?("#{name}_without_auto_mutex").should be_true
      Test.method_defined?("#{name}_with_auto_mutex").should be_true
      Test.method_defined?("#{name}_on_timeout_auto_mutex").should be_true
    end
    [:method1, :method3, :test_no_mutex, :may_timeout_timed_out].each do |name|
      Test.method_defined?(name).should be_true
      Test.method_defined?("#{name}_without_auto_mutex").should be_false
      Test.method_defined?("#{name}_with_auto_mutex").should be_false
      Test.method_defined?("#{name}_on_timeout_auto_mutex").should be_false
    end
  end

  it "should method run unprotected" do
    iterate = 10.times.map { Test.new }
    test_key = @test_key
    results = {}
    ::EM::Synchrony::FiberIterator.new(iterate, iterate.length).each do |test|
      begin
        redis = Redis.new @redis_options
        value = test.__id__.to_s
        results[value] = test.test_no_mutex(redis, test_key, value)
      rescue Exception => e
        @exception = e
      end
    end
    results.length.should eq iterate.length
    results.each_pair do |k, v|
      v.should eq results.values.last
    end
  end

  it "should protect auto_mutex method" do
    iterate = 10.times.map { Test.new }
    test_key = @test_key
    results = {}
    ::EM::Synchrony::FiberIterator.new(iterate, iterate.length).each do |test|
      begin
        redis = Redis.new @redis_options
        value = test.__id__.to_s
        results[value] = test.test(redis, test_key, value)
      rescue Exception => e
        @exception = e
      end
    end
    results.length.should eq iterate.length
    results.each_pair do |k, v|
      k.should eq v
    end
  end

  it "should allow recursive calls to protected methods" do
    iterate = 10.times.map { Test.new }
    test_key = @test_key
    results = {}
    ::EM::Synchrony::FiberIterator.new(iterate, iterate.length).each do |test|
      begin
        redis = Redis.new @redis_options
        value = test.__id__.to_s
        results[value] = test.recursive do |n|
          redis.set test_key, value
          ::EM::Synchrony.sleep 0.1
          [redis.get(test_key), n]
        end
      rescue Exception => e
        @exception = e
      end
    end
    results.length.should eq iterate.length
    results.each_pair do |k, v|
      v.should eq [k, 10]
    end
  end

  it "should call on_timout lambda when locking times out" do
    ::EM::Synchrony.next_tick do
      begin
        Test.new.may_timeout do
          ::EM::Synchrony.sleep 0.2
          true
        end.should be_true
      rescue Exception => e
        @exception = e
      end
    end
    ::EM::Synchrony.sleep 0.1
    Test.new.may_timeout do
      true
    end.should be_false
    ::EM::Synchrony.sleep 0.15
  end

  it "should raise MutexTimeout when locking times out" do
    ::EM::Synchrony.next_tick do
      begin
        Test.new.may_timeout_no_fallback do
          ::EM::Synchrony.sleep 0.2
          true
        end.should be_true
      rescue Exception => e
        @exception = e
      end
    end
    ::EM::Synchrony.sleep 0.1
    expect {
      Test.new.may_timeout_no_fallback do
        true
      end
    }.to raise_error(Redis::EM::Mutex::MutexTimeout)
    ::EM::Synchrony.sleep 0.15
  end

  it "should call on_timout method when locking times out" do
    ::EM::Synchrony.next_tick do
      begin
        Test.new.may_timeout_method_fallback do
          ::EM::Synchrony.sleep 0.2
          true
        end.should be_true
      rescue Exception => e
        @exception = e
      end
    end
    ::EM::Synchrony.sleep 0.1
    Test.new.may_timeout_method_fallback do
      true
    end.should be_false
    ::EM::Synchrony.sleep 0.15
  end

  around(:each) do |testcase|
    @after_em_stop = nil
    @exception = nil
    ::EM.synchrony do
      begin
        testcase.call
        raise @exception if @exception
        Redis::EM::Mutex.stop_watcher(false)
      rescue => e
        Redis::EM::Mutex.stop_watcher(true)
        raise e
      ensure
        ::EM.stop
      end
    end
    @after_em_stop.call if @after_em_stop
  end

  before(:all) do
    @redis_options = {:driver => :synchrony}
    @test_key = SecureRandom.base64(24)
    Redis::EM::Mutex.setup @redis_options.merge(size: 11, ns: SecureRandom.base64(15))
  end

  after(:all) do
    ::EM.synchrony do
      Redis.new(@redis_options).del @test_key
      EM.stop
    end
    # @lock_names
  end
end
