$:.unshift "lib"
require 'securerandom'
require 'em-synchrony'
require 'em-synchrony/fiber_iterator'
require 'redis-em-mutex'

describe Redis::EM::Mutex do

  it "should share a custom owner lock between fibers" do
    begin
      mutex = described_class.lock(*@lock_names, owner: 'my')
      mutex.should be_an_instance_of described_class
      mutex.names.should eq @lock_names
      mutex.locked?.should be true
      mutex.owned?.should be true
      expect {
        mutex.lock
      }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
      fiber = Fiber.current
      ::EM::Synchrony.next_tick do
        begin
          mutex.try_lock.should be false
          mutex.locked?.should be true
          mutex.owned?.should be true
          expect {
            mutex.lock
          }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
          mutex.refresh.should be true
        rescue Exception => e
          @exception = e
        ensure
          ::EM.next_tick { fiber.resume }
        end
      end
      Fiber.yield
      mutex.locked?.should be true
      mutex.owned?.should be true
      mutex.unlock.should be_an_instance_of described_class
      ::EM::Synchrony.next_tick do
        begin
          mutex.locked?.should be false
          mutex.owned?.should be false
          mutex.lock.should be true
          mutex.locked?.should be true
          mutex.owned?.should be true
          expect {
            mutex.lock
          }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
        rescue Exception => e
          @exception = e
        ensure
          ::EM.next_tick { fiber.resume }
        end
      end
      Fiber.yield
      mutex.locked?.should be true
      mutex.owned?.should be true
      expect {
        mutex.lock
      }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
      mutex.unlock.should be_an_instance_of described_class
      mutex.locked?.should be false
      mutex.owned?.should be false
      mutex.try_lock.should be true
    ensure
      mutex.unlock if mutex
    end
  end

  it "should share custom owner locks concurrently between group of fibers" do
    begin
      mutex1 = described_class.new(*@lock_names, owner: 'my1', block: 0)
      mutex2 = described_class.new(*@lock_names, owner: 'my2', block: 0)
      [mutex1, mutex2].each do |mutex|
        mutex.should be_an_instance_of described_class
        mutex.names.should eq @lock_names
        mutex.locked?.should be false
        mutex.owned?.should be false
      end
      mutex1.lock.should be true
      mutex2.lock.should be false
      mutex1.locked?.should be true
      mutex1.owned?.should be true
      mutex2.locked?.should be true
      mutex2.owned?.should be false
      expect {
        mutex1.lock
      }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
      fiber = Fiber.current
      ::EM::Synchrony.next_tick do
        begin
          mutex1.locked?.should be true
          mutex1.owned?.should be true
          mutex2.locked?.should be true
          mutex2.owned?.should be false
          expect {
            mutex1.lock
          }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
          mutex2.lock.should be false
          mutex1.refresh.should be true
          mutex2.refresh.should be_nil
          mutex2.block_timeout = nil
          ::EM.next_tick { fiber.resume }
          start = Time.now
          mutex2.lock.should be true
          (Time.now - start).should be_within(0.01).of(0.5)
        rescue Exception => e
          @exception = e
        ensure
          ::EM.next_tick { fiber.resume }
        end
      end
      Fiber.yield
      EM::Synchrony.sleep 0.5
      mutex1.refresh.should be true
      mutex2.refresh.should be_nil
      mutex1.unlock.should be_an_instance_of described_class
      Fiber.yield
      mutex1.refresh.should be_nil
      mutex2.refresh.should be true
    ensure
      mutex1.unlock if mutex1
      mutex2.unlock if mutex2
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
    @redis_options = {:driver => :synchrony}
    described_class.setup @redis_options.merge(size: 11)
    @lock_names = 10.times.map {
      SecureRandom.random_bytes
    }
  end

  after(:all) do
    # @lock_names
  end
end
