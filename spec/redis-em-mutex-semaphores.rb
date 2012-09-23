$:.unshift "lib"
require 'securerandom'
require 'em-synchrony'
require 'em-synchrony/fiber_iterator'
require 'redis-em-mutex'

describe Redis::EM::Mutex do

  it "should lock and prevent locking on the same semaphore" do
    described_class.new(@lock_names.first).owned?.should be false
    mutex = described_class.lock(@lock_names.first)
    mutex.names.should eq [@lock_names.first]
    mutex.locked?.should be true
    mutex.owned?.should be true
    mutex.should be_an_instance_of described_class
    described_class.new(@lock_names.first).try_lock.should be false
    expect {
      mutex.lock
    }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
    mutex.unlock.should be_an_instance_of described_class
    mutex.locked?.should be false
    mutex.owned?.should be false
    mutex.try_lock.should be true
    mutex.unlock if mutex
  end

  it "should lock and prevent locking on the same multiple semaphores" do
    mutex = described_class.lock(*@lock_names)
    mutex.names.should eq @lock_names
    mutex.locked?.should be true
    mutex.owned?.should be true
    mutex.should be_an_instance_of described_class
    described_class.new(*@lock_names).try_lock.should be false
    @lock_names.each do |name|
      described_class.new(name).try_lock.should be false
    end
    mutex.try_lock.should be false
    expect {
      mutex.lock
    }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
    @lock_names.each do |name|
      expect {
        described_class.new(name).lock
      }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
    end
    mutex.unlock.should be_an_instance_of described_class
    mutex.locked?.should be false
    mutex.owned?.should be false
    mutex.try_lock.should be true
    mutex.unlock if mutex
  end

  it "should lock and prevent other fibers to lock on the same semaphore" do
    mutex = described_class.lock(@lock_names.first)
    mutex.should be_an_instance_of described_class
    mutex.owned?.should be true
    locked = true
    ::EM::Synchrony.next_tick do
      begin
        mutex.try_lock.should be false
        mutex.owned?.should be false
        start = Time.now
        mutex.synchronize do
          (Time.now - start).should be_within(0.015).of(0.26)
          locked.should be false
          locked = nil
        end
      rescue Exception => e
        @exception = e
      end
    end
    ::EM::Synchrony.sleep 0.25
    locked = false
    mutex.owned?.should be true
    mutex.unlock.should be_an_instance_of described_class
    mutex.owned?.should be false
    ::EM::Synchrony.sleep 0.2
    locked.should be_nil
  end

  it "should lock and prevent other fibers to lock on the same multiple semaphores" do
    mutex = described_class.lock(*@lock_names)
    mutex.should be_an_instance_of described_class
    mutex.owned?.should be true
    locked = true
    ::EM::Synchrony.next_tick do
      begin
        locked.should be true
        mutex.try_lock.should be false
        mutex.owned?.should be false
        start = Time.now
        mutex.synchronize do
          mutex.owned?.should be true
          (Time.now - start).should be_within(0.015).of(0.26)
          locked.should be false
        end
        mutex.owned?.should be false
        ::EM::Synchrony.sleep 0.1
        start = Time.now
        ::EM::Synchrony::FiberIterator.new(@lock_names, @lock_names.length).each do |name|
          begin
            locked.should be true
            described_class.new(name).synchronize do
              (Time.now - start).should be_within(0.015).of(0.26)
              locked.should be_an_instance_of Fixnum
              locked-= 1
            end
          rescue Exception => e
            @exception = e
          end
        end
      rescue Exception => e
        @exception = e
      end
    end
    ::EM::Synchrony.sleep 0.25
    locked = false
    mutex.owned?.should be true
    mutex.unlock.should be_an_instance_of described_class
    mutex.owned?.should be false
    ::EM::Synchrony.sleep 0.1

    locked = true
    mutex.lock.should be true
    ::EM::Synchrony.sleep 0.25
    locked = 10
    mutex.unlock.should be_an_instance_of described_class
    ::EM::Synchrony.sleep 0.1
    locked.should eq 0
  end

  it "should lock and prevent other fibers to lock on the same semaphore with block timeout" do
    mutex = described_class.lock(*@lock_names)
    mutex.should be_an_instance_of described_class
    mutex.owned?.should be true
    locked = true
    ::EM::Synchrony.next_tick do
      begin
        start = Time.now
        mutex.lock(0.25).should be false
        mutex.owned?.should be false
        (Time.now - start).should be_within(0.01).of(0.26)
        locked.should be true
        locked = nil
      rescue Exception => e
        @exception = e
      end
    end
    ::EM::Synchrony.sleep 0.26
    locked.should be_nil
    locked = false
    mutex.locked?.should be true
    mutex.owned?.should be true
    mutex.unlock.should be_an_instance_of described_class
    mutex.locked?.should be false
    mutex.owned?.should be false
  end

  it "should lock and expire while other fiber lock on the same semaphore with block timeout" do
    mutex = described_class.lock(*@lock_names, expire: 0.2499999)
    mutex.expire_timeout.should eq 0.2499999
    mutex.should be_an_instance_of described_class
    mutex.owned?.should be true
    locked = true
    ::EM::Synchrony.next_tick do
      begin
        mutex.owned?.should be false
        start = Time.now
        mutex.lock(0.25).should be true
        (Time.now - start).should be_within(0.011).of(0.26)
        locked.should be true
        locked = nil
        mutex.locked?.should be true
        mutex.owned?.should be true
        ::EM::Synchrony.sleep 0.2
        locked.should be false
        mutex.unlock.should be_an_instance_of described_class
        mutex.owned?.should be false
        mutex.locked?.should be false
      rescue Exception => e
        @exception = e
      end
    end
    ::EM::Synchrony.sleep 0.26
    locked.should be_nil
    locked = false
    mutex.locked?.should be true
    mutex.owned?.should be false
    mutex.unlock.should be_an_instance_of described_class
    mutex.locked?.should be true
    mutex.owned?.should be false
    ::EM::Synchrony.sleep 0.5
  end

  it "should lock and prevent (with refresh) other fibers to lock on the same semaphore with block timeout" do
    mutex = described_class.lock(*@lock_names, expire: 0.11)
    mutex.should be_an_instance_of described_class
    mutex.owned?.should be true
    locked = true
    ::EM::Synchrony.next_tick do
      begin
        start = Time.now
        mutex.lock(0.3).should be false
        mutex.owned?.should be false
        (Time.now - start).should be_within(0.01).of(0.31)
        locked.should be true
        locked = nil
      rescue Exception => e
        @exception = e
      end
    end
    ::EM::Synchrony.sleep 0.08
    mutex.owned?.should be true
    mutex.refresh.should be true
    ::EM::Synchrony.sleep 0.08
    mutex.owned?.should be true
    mutex.refresh(0.5).should be true
    ::EM::Synchrony.sleep 0.15
    locked.should be_nil
    locked = false
    mutex.locked?.should be true
    mutex.owned?.should be true
    mutex.unlock.should be_an_instance_of described_class
    mutex.locked?.should be false
    mutex.owned?.should be false
  end

  it "should lock some resource and play with it safely" do
    mutex = described_class.new(*@lock_names)
    play_name = SecureRandom.random_bytes
    result = []
    ::EM::Synchrony::FiberIterator.new((0..9).to_a, 10).each do |i|
      begin
        was_locked = false
        redis = Redis.new @redis_options
        mutex.owned?.should be false
        mutex.synchronize do
          mutex.owned?.should be true
          was_locked = true
          redis.setnx(play_name, i).should be true
          ::EM::Synchrony.sleep 0.1
          redis.get(play_name).should eq i.to_s
          redis.del(play_name).should eq 1
        end
        was_locked.should be true
        mutex.owned?.should be false
        result << i
      rescue Exception => e
        @exception = e
      end
    end
    mutex.locked?.should be false
    result.sort.should eq (0..9).to_a
  end

  it "should lock and the other fiber should acquire lock as soon as possible" do
    mutex = described_class.lock(*@lock_names)
    mutex.should be_an_instance_of described_class
    time = nil
    EM::Synchrony.next_tick do
      begin
        time.should be_nil
        was_locked = false
        mutex.synchronize do
          time.should be_an_instance_of Time
          (Time.now - time).should be < 0.0009
          was_locked = true
        end
        was_locked.should be true
      rescue Exception => e
        @exception = e
      end
    end
    EM::Synchrony.sleep 0.1
    mutex.owned?.should be true
    mutex.unlock.should be_an_instance_of described_class
    time = Time.now
    mutex.owned?.should be false
    EM::Synchrony.sleep 0.1
  end

  it "should lock and the other process should acquire lock as soon as possible" do
    mutex = described_class.lock(*@lock_names)
    mutex.should be_an_instance_of described_class
    time_key1 = SecureRandom.random_bytes
    time_key2 = SecureRandom.random_bytes
    ::EM.fork_reactor do
      Fiber.new do
        begin
          redis = Redis.new @redis_options
          redis.set time_key1, Time.now.to_f.to_s
          mutex.synchronize do
            redis.set time_key2, Time.now.to_f.to_s
          end
          described_class.stop_watcher(false)
        # rescue => e
        #   warn e.inspect
        ensure
          EM.stop
        end
      end.resume
    end
    EM::Synchrony.sleep 0.25
    mutex.owned?.should be true
    mutex.unlock.should be_an_instance_of described_class
    time = Time.now.to_f
    mutex.owned?.should be false
    EM::Synchrony.sleep 0.25
    redis = Redis.new @redis_options
    t1, t2 = redis.mget(time_key1, time_key2)
    t1.should be_an_instance_of String
    t1.to_f.should be < time - 0.25
    t2.should be_an_instance_of String
    t2.to_f.should be > time
    t2.to_f.should be_within(0.001).of(time)
    redis.del(time_key1, time_key2)
  end

  it "should lock and provide current expiration timeout correctly" do
    begin
      mutex = described_class.new(@lock_names.first)
      mutex.unlock!.should be_nil
      mutex.expired?.should be_nil
      mutex.locked?.should be false
      mutex.owned?.should be false
      mutex.expires_in.should be_nil
      mutex.expires_at.should be_nil
      mutex.expiration_timestamp.should be_nil
      mutex.expire_timeout.should eq described_class.default_expire
      mutex.expire_timeout = 0.5
      mutex.expire_timeout.should eq 0.5
      start = Time.now
      mutex.lock
      mutex.expired?.should be false
      now = Time.now
      mutex.expires_in.should be_within(0.01).of(mutex.expire_timeout - (now - start))
      mutex.expiration_timestamp.should be_within(0.01).of(start.to_f + mutex.expire_timeout)
      mutex.expires_at.should eq Time.at(mutex.expiration_timestamp)
      mutex.locked?.should be true
      mutex.owned?.should be true
      mutex.unlock!.should be_an_instance_of described_class
      mutex.locked?.should be false
      mutex.owned?.should be false
      mutex.unlock.should be_an_instance_of described_class
      mutex.unlock!.should be_nil
      mutex.expired?.should be_nil
      mutex.expires_in.should be_nil
      mutex.expires_at.should be_nil
      mutex.expiration_timestamp.should be_nil
      start = Time.now
      mutex.lock
      now = Time.now
      mutex.expires_in.should be_within(0.01).of(mutex.expire_timeout - (now - start))
      EM::Synchrony.sleep mutex.expires_in + 0.001
      mutex.expired?.should be true
      mutex.expires_in.should be < 0
      mutex.expiration_timestamp.should be < Time.now.to_f
      mutex.expires_at.should eq Time.at(mutex.expiration_timestamp)
      mutex.expires_at.should be < Time.now
      start = Time.now
      mutex.refresh.should be true
      now = Time.now
      mutex.expires_in.should be_within(0.01).of(mutex.expire_timeout - (now - start))
      EM::Synchrony.sleep mutex.expires_in + 0.001
      mutex.expired?.should be true
      mutex.expires_in.should be < 0
      mutex.expiration_timestamp.should be < Time.now.to_f
      mutex.expires_at.should eq Time.at(mutex.expiration_timestamp)
      mutex.expires_at.should be < Time.now
      fiber = Fiber.current
      EM::Synchrony.next_tick {
        described_class.lock(@lock_names.first).unlock
        fiber.resume
      }
      Fiber.yield
      mutex.refresh.should be false
      mutex.unlock!.should be false
      mutex.refresh.should be_nil
      mutex.unlock!.should be_nil
      mutex.unlock.should be_an_instance_of described_class
    ensure
      mutex.unlock if mutex
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
