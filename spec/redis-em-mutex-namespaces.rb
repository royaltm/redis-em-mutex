$:.unshift "lib"
require 'securerandom'
require 'em-synchrony'
require 'redis-em-mutex'

describe Redis::EM::Mutex do

  it "should have namespaced semaphores" do
    described_class.ns = 'MutexTEST'
    described_class.ns.should eq 'MutexTEST'
    mutex = described_class.new(*@lock_names)
    mutex.instance_variable_get(:'@ns_names').each_with_index.all? do |ns_name, index|
      ns_name.should eq "MutexTEST:#{@lock_names[index]}"
    end
    described_class.ns = nil
    described_class.ns.should be_nil
    mutex = described_class.new(*@lock_names)
    mutex.instance_variable_get(:'@ns_names').each_with_index.all? do |ns_name, index|
      ns_name.should eq "#{@lock_names[index]}"
    end
    mutex = described_class.new(*@lock_names, ns: 'MutexLocalTEST')
    mutex.instance_variable_get(:'@ns_names').each_with_index.all? do |ns_name, index|
      ns_name.should eq "MutexLocalTEST:#{@lock_names[index]}"
    end
    ns = described_class::NS.new(:MutexCustomTEST)
    mutex = ns.new(*@lock_names)
    mutex.instance_variable_get(:'@ns_names').each_with_index.all? do |ns_name, index|
      ns_name.should eq "MutexCustomTEST:#{@lock_names[index]}"
    end
  end

  it "should lock and allow locking on the same semaphore name with different namespace" do
    begin
      mutex = described_class.lock(*@lock_names)
      mutex.locked?.should be true
      mutex.owned?.should be true
      ns_mutex = described_class.lock(*@lock_names, ns: :MutexLocalTEST)
      ns_mutex.locked?.should be true
      ns_mutex.owned?.should be true
      expect {
        mutex.lock
      }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
      expect {
        ns_mutex.lock
      }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
      mutex.unlock
      mutex.locked?.should be false
      mutex.owned?.should be false
      ns_mutex.unlock
      ns_mutex.locked?.should be false
      ns_mutex.owned?.should be false
    ensure
      mutex.unlock if mutex
      ns_mutex.unlock if ns_mutex
    end
  end

  it "should lock and allow locking on different semaphore name with the same namespace" do
    begin
      ns = described_class::NS.new(:MutexCustomTEST)
      mutex1 = ns.lock(@lock_names.first)
      mutex1.locked?.should be true
      mutex1.owned?.should be true
      mutex2 = ns.lock(@lock_names.last)
      mutex2.locked?.should be true
      mutex2.owned?.should be true
      expect {
        mutex1.lock
      }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
      expect {
        mutex2.lock
      }.to raise_error(Redis::EM::Mutex::MutexError, /deadlock; recursive locking/)
      mutex1.unlock
      mutex1.locked?.should be false
      mutex1.owned?.should be false
      mutex2.unlock
      mutex2.locked?.should be false
      mutex2.owned?.should be false
    ensure
      mutex1.unlock if mutex1
      mutex2.unlock if mutex2
    end
  end


  around(:each) do |testcase|
    @after_em_stop = nil
    ::EM.synchrony do
      begin
        testcase.call
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
