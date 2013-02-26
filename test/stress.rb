#!/usr/bin/env ruby
# Author: Mark Lanett - https://github.com/mlanett
# Origin: https://github.com/mlanett/redis-lock/blob/master/test/stress.rb
# Adapted for redis-em-mutex by: royaltm

require "bundler/setup"       # set up gem paths
require "redis"
require "redis-em-mutex"      # load this gem
require "optparse"
require "ostruct"

options = OpenStruct.new({
  forks: 30,
  tries: 10,
  sleep: 2,
  keys:  5
})

TEST_REDIS = { url: "redis://127.0.0.1:6379/1", driver: :synchrony }
RMutex = ::Redis::EM::Mutex

OptionParser.new do |opts|
  opts.banner = "Usage: #{__FILE__} --forks F --tries T --sleep S"
  opts.on( "-f", "--forks FORKS", "How many processes to fork" )                { |i| options.forks = i.to_i }
  opts.on( "-t", "--tries TRIES", "How many attempts each process should try" ) { |i| options.tries = i.to_i }
  opts.on( "-s", "--sleep SLEEP", "How long processes should sleep/work" )      { |i| options.sleep = i.to_i }
  opts.on( "-k", "--keys KEYS", "How many keys a process should run through" )  { |i| options.keys = i.to_i }
  opts.on( "-h", "--help", "Display this usage summary" ) { puts opts; exit }
end.parse!

class Runner

  attr :options

  def initialize( options )
    @options = options
  end

  def redis
    @redis ||= ::Redis.connect(TEST_REDIS)
  end

  def test( key, time )
    RMutex.synchronize( key, block: time, expire: time*2 ) do
      val1 = rand(65536)
      redis.set( "#{key}:widget", val1 )
      ::EM::Synchrony.sleep( time )
      val2 = redis.get("#{key}:widget").to_i
      expect( val1, val2 )
    end
    true
  rescue => x
    # STDERR.puts "Failed due to #{x.inspect}"
    false
  end

  def run
    keys    = Hash[ (0...options.keys).map { |i| [ i, "key:#{i}" ] } ] # i => key:i
    fails   = Hash[ (0...options.keys).map { |i| [ i, 0 ] } ] # i => 0
    stats   = OpenStruct.new( ok: 0, fails: 0 )
    while keys.size > 0 do
      i = keys.keys.sample
      if test( keys[i], (options.sleep) ) then
        keys.delete(i)
        stats.ok += 1
      else
        fails[i] += 1
        stats.fails += 1
        if fails[i] >= options.tries then
          keys.delete(i)
        end
      end
    end
    puts "[#{Process.pid}] Complete; Ok: #{stats.ok}, Failures: #{stats.fails}"
  end

  def launch
    EM.fork_reactor do
      Fiber.new do
        GC.copy_on_write_friendly = true if ( GC.copy_on_write_friendly? rescue false )
        run
        EM.stop
      end.resume
    end
  end

  def expect( val1, val2 )
    if val1 != val2 then
      STDERR.puts "[#{Process.pid}] Value mismatch"
      Kernel.abort
    end
  end

end

# main

puts "[#{Process.pid}] Starting with #{options.inspect}"

RMutex.setup(TEST_REDIS)

EM.synchrony do
  redis = ::Redis.connect(TEST_REDIS)
  redis.flushdb           # clean before run
  redis.client.disconnect # don't keep when forking

  options.forks.times do
    Runner.new( options ).launch
  end
  Process.waitall
  EM.stop
end
