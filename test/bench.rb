#!/usr/bin/env ruby
require 'bundler/setup'
require 'securerandom'
require 'benchmark'
require 'minitest/unit'

include Benchmark
include MiniTest::Assertions

REDIS_OPTIONS = {}

TEST_KEY = '__TEST__'

# lock and unlock 1000 times
def test1(iterator, synchronize, counter, concurrency = 10)
  iterator.call((1..1000).to_a, concurrency) do
    synchronize.call { counter.call }
  end
  assert_equal(counter.call(0), 1000)
end

# lock, set, incr, read, del, unlock, sleep as many times as possible in 5 seconds
# the cooldown period will be included in total time
def test2(iterator, synchronize, sleeper, counter, redis)
  finish_at = Time.now + 5.0
  iterator.call((1..100).map {|i| i/100000.0+0.001}.shuffle, 100) do |i|
    while Time.now - finish_at < 0
      sleeper.call(i)
      synchronize.call do
        # print "."
        value = rand(1000000000000000000)
        redis.set(TEST_KEY, value)
        redis.incr(TEST_KEY)
        assert_equal redis.get(TEST_KEY).to_i, value+1
        redis.del(TEST_KEY)
        counter.call
      end
    end
  end
end


def test_all(iterator, synchronize, sleeper, counter, concurrency = 10, keysets = [1,2,3,5,10])
  puts "lock/unlock 1000 times with concurrency: #{concurrency}"
  Benchmark.benchmark(CAPTION, 7, FORMAT) do |x|
    keysets.each do |n|
      counter.call -counter.call(0)
      x.report("keys:%2d/%2d " % [n, n*2-1]) { test1(iterator, synchronize[n], counter, concurrency) }
      sleeper.call 1
    end
  end

  puts
  puts "lock/write/incr/read/del/unlock in 5 seconds + cooldown period:"
  Benchmark.benchmark(CAPTION, 8, FORMAT) do |x|
    redis = Redis.new REDIS_OPTIONS
    keysets.each do |n|
      counter.call -counter.call(0)
      x.report("keys:%2d/%2d " % [n, n*2-1]) {
        test2(iterator, synchronize[n], sleeper, counter, redis)
        print '%5d' % counter.call(0)
      }
      sleeper.call 1
    end
  end
end

$:.unshift "lib"
gem 'redis', '~>3.0.2'
require 'em-synchrony'
require 'em-synchrony/fiber_iterator'
require 'redis-em-mutex'

REDIS_OPTIONS.replace(driver: :synchrony)
MUTEX_OPTIONS = {
  expire: 10000,
  ns: '__Benchmark',
}

RMutex = Redis::EM::Mutex
EM.synchrony do
  concurrency = 10
  RMutex.setup(REDIS_OPTIONS.merge(MUTEX_OPTIONS)) {|opts| opts.size = concurrency}
  if RMutex.respond_to? :handler
    puts "Version: #{RMutex::VERSION}, handler: #{RMutex.handler}"
  else
    puts "Version: #{RMutex::VERSION}, handler: N/A"
  end
  counter = 0
  test_all(
    proc do |iter, concurrency, &blk|
      EM::Synchrony::FiberIterator.new(iter, concurrency).each(&blk)
    end,
    proc do |n|
      m = n*2-1
      keys = m.times.map { SecureRandom.random_bytes + '.lck' }
      proc do |&blk|
        RMutex.synchronize(*keys.sample(n), &blk)
      end
    end,
    EM::Synchrony.method(:sleep),
    proc do |incr=1|
      counter+=incr
    end,
    concurrency)
  RMutex.stop_watcher(true)
  EM.stop
end

# #gem 'mlanett-redis-lock', require: 'redis-lock'
# $:.unshift "../redis-lock/lib"
# require 'hiredis'
# require 'redis'
# require 'redis-lock'

# REDIS_OPTIONS.replace(driver: :hiredis)

# class ThreadIterator
#   def initialize(iter, concurrency)
#     @iter = iter
#     @concurrency = concurrency
#     @threads = []
#     @mutex = ::Mutex.new
#   end

#   def each(&blk)
#     @threads = @concurrency.times.map do
#       Thread.new do
#         while value = @mutex.synchronize { @iter.shift }
#           blk.call value
#         end
#       end
#     end
#     @threads.each {|t| t.join}
#   end
# end

# concurrency = 10
# RMutex = Redis
# counter = 0
# test_all(
#   proc do |iter, concurrency, &blk|
#     ThreadIterator.new(iter, concurrency).each(&blk)
#   end,
#   proc do |keys|
#     mutex = RMutex.new REDIS_OPTIONS
#     opts = {sleep: 100, acquire: 21, life: 1}
#     proc do |&blk|
#       mutex.lock(keys[0], opts, &blk)
#     end
#   end,
#   Kernel.method(:sleep),
#   proc do |incr=1|
#     print "\r#{counter}"
#     counter+=incr
#   end,
#   concurrency,
#   [1])
