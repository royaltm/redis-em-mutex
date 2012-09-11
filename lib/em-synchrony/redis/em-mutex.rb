# -*- coding: UTF-8 -*-
require 'digest'
require 'base64'
require 'em-synchrony'
require 'em-synchrony/connection_pool'
require 'redis/connection/synchrony' unless defined? Redis::Connection::Synchrony
require 'redis'

class Redis
  module EM
    class Mutex
      # Cross Machine-Process-Fiber EventMachine/Redis based semaphore.
      #
      # WARNING:
      #   Methods of this class are NOT thread-safe.
      #   They are machine/process/fiber-safe.
      #   All method calls must be invoked only from EventMachine's reactor thread.
      #
      # * The terms "lock" and "semaphore" used in documentation are synonims.
      # * The term "owner" denotes a Ruby Fiber in some Process on some Machine.
      #
      # This implementation:
      #
      # * is designed especially for EventMachine
      # * is best served with EM-Synchrony (uses EM::Synchrony::ConnectionPool)
      # * doesn't do CPU-intensive sleep/polling while waiting for lock to be available
      # * instead Fibers waiting for the lock are signalled as soon as the lock has been released
      # * is fiber-safe
      # * is NOT thread-safe
      #
      #
      module Errors
        class MutexError < RuntimeError; end
        class MutexTimeout < MutexError; end
      end

      include Errors

      @@watcher_connection_retry_max = 10
      @@default_expire = 3600*24
      AUTO_NAME_SEED = '__@'
      SIGNAL_QUEUE_CHANNEL = "::#{self.name}::"
      @@name_index = AUTO_NAME_SEED
      @@redis_pool = nil
      @@redis_watcher = nil
      @@watching = false
      @@watcher_subscribed = false
      @@signal_queue = {}
      @@ns = nil
      @@uuid = nil

      attr_accessor :expire_timeout, :block_timeout
      attr_reader :name, :ns
      alias_method :namespace, :ns

      # Creates a new namespace (Mutex factory).
      #
      # ns = namespace
      # opts = options hash
      #   :block - default block timeout
      #   :expire - default expire timeout
      class NS
        attr_reader :ns
        alias_method :namespace, :ns
        def initialize(ns, opts = {})
          @ns = ns
          @opts = (opts || {}).merge(:ns => ns)
        end

        # Creates namespaced cross machine/process/fiber semaphore.
        #
        # for arguments see: Redis::EM::Mutex.new
        def new(name = nil, opts = {})
          Redis::EM::Mutex.new name, @opts.merge(opts || {})
        end

        # Executes block of code protected with namespaced semaphore.
        #
        # See: Redis::EM::Mutex.synchronize
        def synchronize(name, options={}, &block)
          new(name, options).synchronize(&block)
        end
      end

      # Creates a new cross machine/process/fiber semaphore
      #
      # name = lock identifier or nil - auto generated
      # opts = options hash
      #   - :name - same as name (in case name argument was omitted)
      #   - :block - default block timeout
      #   - :expire - default expire timeout
      #   - :ns - namespace (otherwise global namespace is used)
      def initialize(name = nil, opts = {})
        raise MutexError, "call #{self.class}::setup first" unless @@redis_pool

        opts, name = name, nil if name.kind_of? Hash

        @name = "#{name || opts[:name] || @@name_index.succ!}.lock"
        @ns = opts[:ns] || @@ns
        @ns_name = @ns ? "#@ns:#@name" : @name
        @expire_timeout = opts[:expire]
        @block_timeout = opts[:block]
        @locked_id = nil
      end

      # Returns `true` if this semaphore is currently held by some owner.
      def locked?
        @@redis_pool.exists(@ns_name)
      end

      # Attempts to obtain the lock and returns immediately.
      # Returns `true` if the lock was granted.
      # Use Mutex#expire_timeout= to set custom lock expiration time in secods.
      # Otherwise global Mutex.default_expire is used.
      #
      # This method does not obtains expired semaphores.
      # Use Mutex#lock with block_timeout = 0 to obtain expired lock.
      def try_lock
        lock_id = (Time.now + (@expire_timeout.to_i.nonzero? || @@default_expire)).to_f.to_s
        if @@redis_pool.setnx(@ns_name, owner_ident(lock_id))
          @locked_id = lock_id
          true
        else
          false
        end
      end

      # Releases the lock unconditionally.
      # If semaphore wasn’t locked by the current owner it is silently ignored.
      # Returns self.
      def unlock
        if @locked_id
          @@redis_pool.execute(false) do |r|
            r.watch(@ns_name) do
              if r.get(@ns_name) == owner_ident(@locked_id)
                r.multi do |multi|
                  multi.del(@ns_name)
                  multi.publish(SIGNAL_QUEUE_CHANNEL, @ns_name)
                end
              else
                r.unwatch
              end
            end
          end
        end
        self
      end

      # Attempts to grab the lock and waits if it isn’t available.
      # Raises MutexError if mutex was locked by the current owner.
      # Returns `true` if lock was successfully obtained.
      # Returns `false` if lock wasn't available within `block_timeout` seconds.
      #
      # If `block_timeout` is `nil` or omited this method uses Mutex#block_timeout.
      # If also Mutex#block_timeout is nil this method returns only after lock
      # has been granted.
      #
      # Use Mutex#expire_timeout= to set lock expiration timeout.
      # Otherwise global Mutex.default_expire is used.
      def lock(block_timeout = nil)
        block_timeout||= @block_timeout
        name = @ns_name
        timer = fiber = nil
        try_again = false
        handler = proc do
          try_again = true
          ::EM.next_tick { fiber.resume if fiber } if fiber
        end
        queue = (@@signal_queue[name]||= [])
        queue << handler
        until try_lock
          raise MutexError, "can't lock: watcher is down" unless @@watching
          start_time = Time.now.to_f
          expire_time = 0
          @@redis_pool.execute(false) do |r|
            r.watch(name) do
              if (lock_value = r.get(name))
                owner, exp_id = lock_value.split ' '
                expire_time = exp_id.to_f
                raise MutexError, "deadlock; recursive locking #{owner}" if owner == owner_ident
                if expire_time < start_time
                  r.multi do |multi|
                    multi.del(name)
                    multi.publish(SIGNAL_QUEUE_CHANNEL, name)
                  end
                else
                  r.unwatch
                end
              else
                r.unwatch
              end
            end
          end
          timeout = expire_time - start_time
          timeout = block_timeout if block_timeout && block_timeout < timeout

          if !try_again && timeout > 0
            timer = ::EM::Timer.new(timeout) do
              timer = nil
              ::EM.next_tick { fiber.resume if fiber } if fiber
            end
            fiber = Fiber.current
            Fiber.yield 
            fiber = nil
          end
          finish_time = Time.now.to_f
          if try_again || finish_time > expire_time
            block_timeout-= finish_time - start_time if block_timeout
            try_again = false
          else
            return false
          end
        end
        true
      ensure
        timer.cancel if timer
        timer = nil
        queue.delete handler
        @@signal_queue.delete name if queue.empty?
      end

      # Execute block of code protected with semaphore.
      # Returns result of code block.
      #
      # If `block_timeout` or Mutex#block_timeout is set and
      # lock isn't obtained within `block_timeout` seconds this method raises
      # MutexTimeout.
      def synchronize(block_timeout = nil)
        if lock(block_timeout)
          begin
            yield
          ensure
            unlock
          end
        else
          raise MutexTimeout
        end
      end

      class << self

        def ns; @@ns; end
        def ns=(namespace); @@ns = namespace; end
        alias_method :namespace, :ns
        alias_method :'namespace=', :'ns='
        
        # Default value of semaphore expiration timeout in seconds.
        def default_expire; @@default_expire; end
        
        # Assigns default value of semaphore expiration timeout in seconds.
        # Must be > 0.
        def default_expire=(value); @@default_expire=value.to_f.abs; end

        # Setup redis database and other defaults
        # MUST BE called once before any semaphore is created.
        # opts = options Hash:
        #  - global options:
        #  - :expire   - sets global Mutex.default_expire 
        #  - :ns       - sets global Mutex.namespace
        #  - :limit_reconnect - max num. of reattempts to establish
        #    connection to watcher channel on redis connection failure;
        #    default is 10; set to 0 to disable reconnecting;
        #    set to -1 to reattempt forever
        #
        #  - redis connection options:
        #  - :size     - redis connection pool size
        #
        #  - passed directly to Redis.new:
        #  - :url      - redis server url
        #  - :scheme   - "redis" or "unix"
        #  - :host     - redis host
        #  - :port     - redis port
        #  - :password - redis password
        #  - :db       - redis database number
        #  - :path     - redis unix-socket path
        #
        #  - alternatively:
        #  - :redis    - initialized ConnectionPool of Redis clients.
        def setup(opts = {})
          stop_watcher
          opts = opts ? opts.dup : {}
          opts.update :driver => :synchrony
          redis = opts.delete :redis
          if redis && !opts[:url]
            opts = {
              :scheme => redis.scheme,
              :host   => redis.host,
              :port   => redis.port,
              :password => redis.password,
              :db       => redis.db,
              :path     => redis.path
            }.reject {|_k, v| v.nil?}.
              merge(opts)
          end
          namespace = opts.delete :ns
          pool_size = (opts.delete(:size).to_i.nonzero? || 1).abs
          default_expire = opts.delete :expire
          @@default_expire = default_expire.to_f.abs if default_expire
          limit_reconnect = opts.delete :limit_reconnect
          @@watcher_connection_retry_max = limit_reconnect.to_i if limit_reconnect
          @@ns = namespace if namespace
          # generate machine uuid
          # todo: should probably use NIC ethernet address or uuid gem
          dhash = ::Digest::SHA1.new
          rnd = Random.new
          256.times { dhash.update [rnd.rand(0x100000000)].pack "N" }
          digest = dhash.digest
          dsize, doffs = digest.bytesize.divmod 6
          @@uuid = Base64.encode64(digest[rnd.rand(doffs + 1), dsize * 6]).chomp

          @@redis_pool = redis ||
            ::EM::Synchrony::ConnectionPool.new(size: pool_size) do
              Redis.new opts
            end
          @@redis_watcher = Redis.new opts
          start_watcher
        end

        # resets Mutex's automatic name generator
        def reset_autoname
          @@name_index = AUTO_NAME_SEED
        end

        def wakeup_queue_all
          @@signal_queue.each do |name, queue|
            queue.each {|h| h.call }
          end
        end

        # Initializes the "unlock" channel watcher. It's called by Mutex.setup
        # internally. Should not be used under normal circumstances.
        # If EventMachine is to be re-started several times may be used instead of
        # Mutex.setup for "lightweight" setup.
        def start_watcher
          raise MutexError, "call #{self.class}::setup first" unless @@redis_watcher
          return if @@watching
          @@watching = true
          retries = 0
          Fiber.new do
            begin
              @@redis_watcher.subscribe(SIGNAL_QUEUE_CHANNEL) do |on|
                on.subscribe do |channel, subs|
                  if channel == SIGNAL_QUEUE_CHANNEL
                    @@watcher_subscribed = true
                    retries = 0
                    wakeup_queue_all
                  end
                end
                on.message do |channel, message|
                  if channel == SIGNAL_QUEUE_CHANNEL
                    if (queue = @@signal_queue[message])
                      handler = queue.first
                      handler.call if handler
                    end
                  end
                end
                on.unsubscribe do |channel, subs|
                  @@watcher_subscribed = false if channel == SIGNAL_QUEUE_CHANNEL
                end
              end
              break
            rescue Redis::BaseConnectionError => e
              @@watcher_subscribed = false
              warn e.message
              retries+= 1
              if retries > @@watcher_connection_retry_max && @@watcher_connection_retry_max >= 0
                @@watching = false
                raise MutexError, "Can not establish watcher channel connection!"
              end
              ::EM::Synchrony.sleep retries > 1 ? 1 : 0.1
            end while @@watching
          end.resume
        end

        # Stops the watcher of the "unlock" channel.
        # It should be called before stoping EvenMachine otherwise
        # EM might wait forever for channel connection to be closed.
        #
        # Raises MutexError if there are still some fibers waiting for a lock.
        # Pass `true` to forcefully stop it. This might instead cause
        # MutexError to be raised in waiting fibers.
        def stop_watcher(force = false)
          return unless @@watching
          @@watching = false
          raise MutexError, "call #{self.class}::setup first" unless @@redis_watcher
          unless @@signal_queue.empty? || force
            raise MutexError, "can't stop: active signal queue handlers"
          end
          @@redis_watcher.unsubscribe SIGNAL_QUEUE_CHANNEL if @@watcher_subscribed
        end

        # Remove all current Machine/Process locks.
        # Since there is no lock tracking mechanism, it might not be implemented easily.
        # If the need arises then it probably should be implemented.
        def sweep
          raise NotImplementedError
        end

        # Execute block of code protected with named semaphore.
        # Returns result of code block.
        #
        # name = lock identifier or nil - auto generated
        # opts = options hash
        #   - :name - same as name (in case name argument was omitted)
        #   - :block - block timeout
        #   - :expire - expire timeout (see: #lock and #try_lock)
        #   - :ns - namespace (otherwise global namespace is used)
        # 
        # If `:block` is set and lock isn't obtained within `:block` seconds this method raises
        # MutexTimeout.
        def synchronize(name, options={}, &block)
          new(name, options).synchronize(&block)
        end
      end

      private

      def owner_ident(lock_id = nil)
        if lock_id
          "#@@uuid$#$$@#{Fiber.current.__id__} #{lock_id}"
        else
          "#@@uuid$#$$@#{Fiber.current.__id__}"
        end
      end
    end
  end
end
