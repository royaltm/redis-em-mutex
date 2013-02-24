$:.unshift "lib"
gem 'redis', '~>3.0.2'
require 'securerandom'
require 'benchmark'
require 'em-synchrony'
require 'em-synchrony/fiber_iterator'
require 'redis-em-mutex'

RMutex = Redis::EM::Mutex
include Benchmark

MUTEX_OPTIONS = {
  expire: 10000,
  ns: '__Benchmark',
}

TEST_KEY = '__TEST__'

def assert(condition)
  raise "Assertion failed: #{__FILE__}:#{__LINE__}" unless condition
end

# lock and unlock 1000 times
def test1(keys, concurrency = 10)
  count = 0
  mutex = RMutex.new(*keys)
  EM::Synchrony::FiberIterator.new((1..1000).to_a, concurrency).each do |i|
    mutex.synchronize { count+=1 }
  end
  assert(count == 1000)
end

# lock, set, incr, read, del, unlock, sleep as many times as possible in 5 seconds
# the cooldown period will be included in total time
def test2(keys, redis)
  running = true
  count = 0
  playing = 0
  mutex = RMutex.new(*keys)
  f = Fiber.current
  (1..100).map {|i| i/100000+0.001}.shuffle.each do |i|
    EM::Synchrony.next_tick do
      while running
        playing+=1
        EM::Synchrony.sleep(i)
        mutex.synchronize do
          # print "."
          value = rand(1000000000000000000)
          redis.set(TEST_KEY, value)
          redis.incr(TEST_KEY)
          assert redis.get(TEST_KEY).to_i == value+1
          redis.del(TEST_KEY)
          count += 1
        end
        playing-=1
      end
    end
  end
  EM::Synchrony.add_timer(5) do
    running = false
    # print "0"
    EM::Synchrony.sleep(0.001) while playing > 0
    EM.next_tick { f.resume }
  end
  Fiber.yield
  print '%5d' % count
end

EM.synchrony do
  concurrency = 10
  RMutex.setup(MUTEX_OPTIONS) {|opts| opts.size = concurrency}
  if RMutex.respond_to? :handler
    puts "Version: #{RMutex::VERSION}, handler: #{RMutex.handler}"
  else
    puts "Version: #{RMutex::VERSION}, handler: N/A"
  end

  puts "lock/unlock 1000 times with concurrency: #{concurrency}"
  Benchmark.benchmark(CAPTION, 7, FORMAT) do |x|
    [1,2,3,5,10].each do |n|
      keys = n.times.map { SecureRandom.random_bytes + '.lck' }
      x.report("keys:%2d " % n) { test1(keys, concurrency) }
      EM::Synchrony.sleep(1)
    end
  end

  puts
  puts "lock/write/incr/read/del/unlock in 5 seconds + cooldown period:"
  Benchmark.benchmark(CAPTION, 8, FORMAT) do |x|
    redis = Redis.new
    [1,2,3,5,10].each do |n|
      keys = n.times.map { SecureRandom.random_bytes + '.lck' }
      x.report("keys:%2d " % n) { test2(keys, redis) }
      EM::Synchrony.sleep(1)
    end
  end
  RMutex.stop_watcher(true)
  EM.stop
end
