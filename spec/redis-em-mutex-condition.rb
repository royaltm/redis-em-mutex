$:.unshift "lib"
require 'securerandom'
require 'em-synchrony'
require 'em-synchrony/thread'
require 'redis-em-mutex'

describe Redis::EM::Mutex do

  it "should lock and sleep forever until woken up" do
    begin
      mutex = described_class.lock(*@lock_names)
      mutex.owned?.should be true
      fiber = Fiber.current
      start = Time.now
      ::EM.add_timer(0.25) do
        mutex.wakeup(fiber)
      end
      mutex.sleep.should be_within(0.01).of(0.25)
      (Time.now - start).should be_within(0.01).of(0.25)
      mutex.owned?.should be true
      mutex.unlock!.should be_true
    ensure
      mutex.unlock if mutex
    end
  end

  it "should lock and sleep with timeout" do
    begin
      mutex = described_class.lock(*@lock_names)
      mutex.owned?.should be true
      start = Time.now
      mutex.sleep(0.25).should be_within(0.01).of(0.25)
      (Time.now - start).should be_within(0.01).of(0.25)
      mutex.owned?.should be true
      mutex.unlock!.should be_true
    ensure
      mutex.unlock if mutex
    end
  end

  it "should lock and sleep with timeout but woken up in the middle of a sleep" do
    begin
      mutex = described_class.lock(*@lock_names)
      mutex.owned?.should be true
      fiber = Fiber.current
      start = Time.now
      ::EM.add_timer(0.15) do
        mutex.wakeup(fiber)
      end
      mutex.sleep(0.25).should be_within(0.001).of(0.15)
      (Time.now - start).should be_within(0.001).of(0.15)
      mutex.owned?.should be true
      mutex.unlock!.should be_true
    ensure
      mutex.unlock if mutex
    end
  end

  it "should work with EM::Synchrony::Thread::ConditionVariable" do
    mutex = described_class.new(*@lock_names)
    resource = ::EM::Synchrony::Thread::ConditionVariable.new
    signal = nil
    fiber = Fiber.current
    ::EM::Synchrony.next_tick do
      mutex.synchronize {
        resource.wait(mutex)
        fiber.resume Time.now
      }
    end
    ::EM::Synchrony.next_tick do
      mutex.synchronize {
        ::EM::Synchrony.sleep(0.2)
        resource.signal
        signal = Time.now
      }
    end
    start = Time.now
    now = Fiber.yield
    (now - signal).should be_within(0.001).of(0.001)
    (now - start).should be_within(0.01).of(0.2)
    mutex.synchronize do
      signal = nil
    end
    signal.should be_nil
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
    @redis_options = {:driver => :synchrony}
    described_class.setup @redis_options.merge(size: 4)
    @lock_names = 2.times.map {
      SecureRandom.random_bytes
    }
  end

  after(:all) do
    # @lock_names
  end
end
