# -*- coding: UTF-8 -*-
require 'ostruct'
require 'securerandom'
require 'redis/connection/synchrony' unless defined? Redis::Connection::Synchrony
require 'redis'
require 'redis/em-mutex/version'

class Redis
  module EM
    # Cross machine-process-fiber EventMachine + Redis based semaphore.
    #
    # WARNING:
    #
    # Methods of this class are NOT thread-safe.
    # They are machine/process/fiber-safe.
    # All method calls must be invoked only from EventMachine's reactor thread.
    # Wrap mutex calls in EventMachine.shedule from non-reactor threads.
    #
    # - The terms "lock" and "semaphore" used in documentation are synonims.
    # - The term "owner" denotes a Ruby Fiber executing code in the scope of Machine/Process/Fiber
    #   possessing exclusively a named semaphore(s).
    #
    class Mutex

      autoload :NS, 'redis/em-mutex/ns'
      autoload :Macro, 'redis/em-mutex/macro'

      module Errors
        class MutexError < RuntimeError; end
        class MutexTimeout < MutexError; end
      end

      include Errors
      extend Errors

      @@connection_pool_class = nil
      @@connection_retry_max = 10
      @@default_expire = 3600*24
      AUTO_NAME_SEED = '__@'
      SIGNAL_QUEUE_CHANNEL = "::#{self.name}::"
      @@name_index = AUTO_NAME_SEED
      @@redis_pool = nil
      @@redis_watcher = nil
      @@watching = false
      @@watcher_subscribed = false
      @@signal_queue = Hash.new {|h,k| h[k] = []}
      @@ns = nil
      @@uuid = nil

      attr_reader :names, :ns, :block_timeout
      alias_method :namespace, :ns

      def expire_timeout; @expire_timeout || @@default_expire; end

      def expire_timeout=(value)
        raise ArgumentError, "#{self.class.name}\#expire_timeout value must be greater than 0" unless (value = value.to_f) > 0
        @expire_timeout = value
      end

      def block_timeout=(value)
        @block_timeout = value.nil? ? nil : value.to_f
      end

      # Creates a new cross machine/process/fiber semaphore
      #
      #   Redis::EM::Mutex.new(*names, options = {})
      #
      # - *names = lock identifiers - if none they are auto generated
      # - options = hash:
      # - :name - same as *names (in case *names arguments were omitted)
      # - :block - default block timeout
      # - :expire - default expire timeout (see: Mutex#lock and Mutex#try_lock)
      # - :ns - local namespace (otherwise global namespace is used)
      # - :owner - owner definition instead of Fiber#__id__
      #
      # Raises MutexError if used before Mutex.setup.
      # Raises ArgumentError on invalid options.
      def initialize(*args)
        raise MutexError, "call #{self.class}::setup first" unless @@redis_pool

        opts = args.last.kind_of?(Hash) ? args.pop : {}

        @names = args
        @names = Array(opts[:name] || "#{@@name_index.succ!}.lock") if @names.empty?
        @slept = {}
        raise ArgumentError, "semaphore names must not be empty" if @names.empty?
        @multi = !@names.one?
        @ns = opts[:ns] || @@ns
        @ns_names = @ns ? @names.map {|n| "#@ns:#{n}".freeze }.freeze : @names.map {|n| n.to_s.dup.freeze }.freeze
        self.expire_timeout = opts[:expire] if opts.key?(:expire)
        self.block_timeout = opts[:block] if opts.key?(:block)
        @locked_owner_id = @locked_id = nil
        if (owner = opts[:owner])
          self.define_singleton_method(:owner_ident) do |lock_id = nil|
            if lock_id
              "#@@uuid$#$$@#{owner} #{lock_id}"
            else
              "#@@uuid$#$$@#{owner}"
            end
          end
        end
      end

      # Returns `true` if this semaphore (at least one of locked `names`) is currently being held by some owner.
      def locked?
        if @multi
          @@redis_pool.multi do |multi|
            @ns_names.each {|n| multi.exists n}
          end.any?
        else
          @@redis_pool.exists @ns_names.first
        end
      end

      # Returns `true` if this semaphore (all the locked `names`) is currently being held by calling owner.
      # This is the method you should use to check if lock is still held and valid.
      def owned?
        !!if @locked_id && owner_ident(@locked_id) == (lock_full_ident = @locked_owner_id)
          @@redis_pool.mget(*@ns_names).all? {|v| v == lock_full_ident}
        end
      end

      # Returns `true` when the semaphore is being held and have already expired.
      # Returns `false` when the semaphore is still locked and valid
      # or `nil` if the semaphore wasn't locked.
      #
      # The check is performed only on the Mutex object instance and should only be used as a hint.
      # For reliable lock status information use #refresh or #owned? instead.
      def expired?
        return Time.now.to_f > @locked_id.to_f if @locked_id && owner_ident(@locked_id) == @locked_owner_id
      end

      # Returns the number of seconds left until the semaphore expires.
      # The number of seconds less than 0 means that the semaphore expired and could be grabbed
      # by some other owner.
      # Returns `nil` if the semaphore wasn't locked.
      #
      # The check is performed only on the Mutex object instance and should only be used as a hint.
      # For reliable lock status information use #refresh or #owned? instead.
      def expires_in
        return @locked_id.to_f - Time.now.to_f if @locked_id && owner_ident(@locked_id) == @locked_owner_id
      end

      # Returns local time at which the semaphore will expire or have expired.
      # Returns `nil` if the semaphore wasn't locked.
      #
      # The check is performed only on the Mutex object instance and should only be used as a hint.
      # For reliable lock status information use #refresh or #owned? instead.
      def expires_at
        Time.at(@locked_id.to_f) if @locked_id && owner_ident(@locked_id) == @locked_owner_id
      end

      # Returns timestamp at which the semaphore will expire or have expired.
      # Returns `nil` if the semaphore wasn't locked.
      #
      # The check is performed only on the Mutex object instance and should only be used as a hint.
      # For reliable lock status information use #refresh or #owned? instead.
      def expiration_timestamp
        @locked_id.to_f if @locked_id && owner_ident(@locked_id) == @locked_owner_id
      end

      # Attempts to obtain the lock and returns immediately.
      # Returns `true` if the lock was granted.
      # Use Mutex#expire_timeout= to set lock expiration time in secods.
      # Otherwise global Mutex.default_expire is used.
      #
      # This method doesn't capture expired semaphores
      # and therefore it should not be used under normal circumstances.
      # Use Mutex#lock with block_timeout = 0 to obtain expired lock without blocking.
      def try_lock
        lock_id = (Time.now + expire_timeout).to_f.to_s
        lock_full_ident = owner_ident(lock_id)
        !!if @multi
          if @@redis_pool.msetnx(*@ns_names.map {|k| [k, lock_full_ident]}.flatten)
            @locked_id = lock_id
            @locked_owner_id = lock_full_ident
          end
        elsif @@redis_pool.setnx(@ns_names.first, lock_full_ident)
          @locked_id = lock_id
          @locked_owner_id = lock_full_ident
        end
      end

      # Refreshes lock expiration timeout.
      # Returns `true` if refresh was successfull or `nil` if semaphore wasn't locked.
      # When the semaphore was locked but has expired and has already changed owner returns `false`.
      def refresh(expire_timeout=nil)
        ret = nil
        if @locked_id && owner_ident(@locked_id) == (lock_full_ident = @locked_owner_id)
          new_lock_id = (Time.now + (expire_timeout.to_f.nonzero? || self.expire_timeout)).to_f.to_s
          new_lock_full_ident = owner_ident(new_lock_id)
          @@redis_pool.execute(false) do |r|
            r.watch(*@ns_names) do
              ret = !!if r.mget(*@ns_names).all? {|v| v == lock_full_ident}
                if r.multi {|m| m.mset(*@ns_names.map {|k| [k, new_lock_full_ident]}.flatten)}
                  @locked_id = new_lock_id
                  @locked_owner_id = new_lock_full_ident
                end
              else
                r.unwatch
                false
              end
            end
          end
        end
        ret
      end

      # Releases the lock. Returns self on success.
      # If the semaphore wasn’t locked returns `nil`.
      # When the semaphore was locked but has expired and has already changed owner returns `false`.
      def unlock!
        ret = nil
        if @locked_id && owner_ident(@locked_id) == (lock_full_ident = @locked_owner_id)
          @@redis_pool.execute(false) do |r|
            r.watch(*@ns_names) do
              ret = if r.mget(*@ns_names).all? {|v| v == lock_full_ident}
                !!r.multi do |multi|
                  multi.del(*@ns_names)
                  multi.publish SIGNAL_QUEUE_CHANNEL, Marshal.dump(@ns_names)
                end
              else
                r.unwatch
                false
              end
            end
          end
          @locked_owner_id = @locked_id = nil
        end
        ret && self
      end

      # Releases the lock unconditionally.
      # If the semaphore wasn’t locked by the current owner it is silently ignored.
      # Returns self.
      def unlock
        unlock!
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
        block_timeout||= self.block_timeout
        names = @ns_names
        timer = fiber = nil
        try_again = false
        handler = proc do
          try_again = true
          ::EM.next_tick { fiber.resume if fiber } if fiber
        end
        begin
          queues = names.map {|n| @@signal_queue[n] << handler }
          ident_match = owner_ident
          until try_lock
            Mutex.start_watcher unless watching?
            start_time = Time.now.to_f
            expire_time = nil
            @@redis_pool.execute(false) do |r|
              r.watch(*names) do
                expired_names = names.zip(r.mget(*names)).map do |name, lock_value|
                  if lock_value
                    owner, exp_id = lock_value.split ' '
                    exp_time = exp_id.to_f
                    expire_time = exp_time if expire_time.nil? || exp_time < expire_time
                    raise MutexError, "deadlock; recursive locking #{owner}" if owner == ident_match
                    if exp_time < start_time
                      name
                    end
                  end
                end
                if expire_time && expire_time < start_time
                  r.multi do |multi|
                    expired_names = expired_names.compact
                    multi.del(*expired_names)
                    multi.publish SIGNAL_QUEUE_CHANNEL, Marshal.dump(expired_names)
                  end
                else
                  r.unwatch
                end
              end
            end
            timeout = (expire_time = expire_time.to_f) - start_time
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
          queues.each {|q| q.delete handler }
          names.each {|n| @@signal_queue.delete(n) if @@signal_queue[n].empty? }
        end
      end

      # Wakes up currently sleeping fiber on a mutex.
      def wakeup(fiber)
        fiber.resume if @slept.delete(fiber)
      end

      # for compatibility with EventMachine::Synchrony::Thread::ConditionVariable
      alias_method :_wakeup, :wakeup

      # Releases the lock and sleeps `timeout` seconds if it is given and non-nil or forever.
      # Raises MutexError if mutex wasn’t locked by the current owner.
      # Raises MutexTimeout if #block_timeout= was set and timeout
      # occured while locking after sleep.
      # If code block is provided it is executed after waking up, just before grabbing a lock.
      def sleep(timeout = nil)
        raise MutexError, "can't sleep #{self.class} wasn't locked" unless unlock!
        start = Time.now
        current = Fiber.current
        @slept[current] = true
        if timeout
          timer = ::EM.add_timer(timeout) do
            wakeup(current)
          end
          Fiber.yield
          ::EM.cancel_timer timer
        else
          Fiber.yield
        end
        @slept.delete current
        yield if block_given?
        raise MutexTimeout unless lock
        Time.now - start
      end

      # Execute block of code protected with semaphore.
      # Code block receives mutex object.
      # Returns result of code block.
      #
      # If `block_timeout` or Mutex#block_timeout is set and
      # lock isn't obtained within `block_timeout` seconds this method raises
      # MutexTimeout.
      def synchronize(block_timeout=nil)
        if lock(block_timeout)
          begin
            yield self
          ensure
            unlock
          end
        else
          raise MutexTimeout
        end
      end

      # Returns true if watcher is connected
      def watching?; @@watching == $$; end

      # Returns true if watcher is connected
      def self.watching?; @@watching == $$; end

      class << self
        def ns; @@ns; end
        def ns=(namespace); @@ns = namespace; end
        alias_method :namespace, :ns
        alias_method :'namespace=', :'ns='

        # Default value of expiration timeout in seconds.
        def default_expire; @@default_expire; end

        # Assigns default value of expiration timeout in seconds.
        # Must be > 0.
        def default_expire=(value)
          raise ArgumentError, "#{name}.default_expire value must be greater than 0" unless (value = value.to_f) > 0
          @@default_expire = value
        end

        # Setup redis database and other defaults
        # MUST BE called once before any semaphore is created.
        #
        # opts = options Hash:
        #
        # global options:
        #
        # - :connection_pool_class - default is ::EM::Synchrony::ConnectionPool
        # - :expire   - sets global Mutex.default_expire 
        # - :ns       - sets global Mutex.namespace
        # - :reconnect_max - maximum num. of attempts to re-establish
        #   connection to redis server;
        #   default is 10; set to 0 to disable re-connecting;
        #   set to -1 to attempt forever
        #
        # redis connection options:
        #
        # - :size     - redis connection pool size
        #
        # passed directly to Redis.new:
        #
        # - :url      - redis server url
        #
        # or
        #
        # - :scheme   - "redis" or "unix"
        # - :host     - redis host
        # - :port     - redis port
        # - :password - redis password
        # - :db       - redis database number
        # - :path     - redis unix-socket path
        #
        # or
        #
        # - :redis    - initialized ConnectionPool of Redis clients.
        def setup(opts = {})
          stop_watcher
          opts = OpenStruct.new(opts)
          yield opts if block_given?
          @@connection_pool_class = opts.connection_pool_class if opts.connection_pool_class.kind_of?(Class)
          @redis_options = redis_options = {:driver => :synchrony}
          redis_updater = proc do |redis|
            redis_options.update({
              :scheme => redis.scheme,
              :host   => redis.host,
              :port   => redis.port,
              :password => redis.password,
              :db       => redis.db,
              :path     => redis.path
            }.reject {|_k, v| v.nil?})
          end
          if (redis = opts.redis) && !opts.url
            redis_updater.call redis.client
          elsif opts.url
            redis_options[:url] = opts.url
          end
          redis_updater.call opts
          namespace = opts.ns
          pool_size = (opts.size.to_i.nonzero? || 1).abs
          self.default_expire = opts.expire if opts.expire
          @@connection_retry_max = opts.reconnect_max.to_i if opts.reconnect_max
          @@ns = namespace if namespace
          @@uuid = if SecureRandom.respond_to?(:uuid)
            SecureRandom.uuid
          else
            SecureRandom.base64(24)
          end
          unless (@@redis_pool = redis)
            unless @@connection_pool_class
              begin
                require 'em-synchrony/connection_pool' unless defined?(::EM::Synchrony::ConnectionPool)
              rescue LoadError
                raise ":connection_pool_class required; could not fall back to EM::Synchrony::ConnectionPool - gem install em-synchrony"
              end
              @@connection_pool_class = ::EM::Synchrony::ConnectionPool
            end
            @@redis_pool = @@connection_pool_class.new(size: pool_size) do
              Redis.new redis_options
            end
          end
          @@redis_watcher = Redis.new redis_options
          start_watcher if ::EM.reactor_running?
        end

        # resets Mutex's automatic name generator
        def reset_autoname
          @@name_index = AUTO_NAME_SEED
        end

        def wakeup_queue_all
          @@signal_queue.each_value do |queue|
            queue.each {|h| h.call }
          end
        end

        # Initializes the "unlock" channel watcher. It's called by Mutex.setup
        # internally. Should not be used under normal circumstances.
        # If EventMachine is to be re-started (or after EM.fork_reactor) this method may be used instead of
        # Mutex.setup for "lightweight" startup procedure.
        def start_watcher
          raise MutexError, "call #{self.class}::setup first" unless @@redis_watcher
          return if watching?
          if @@watching # Process id changed, we've been forked alive!
            @@redis_watcher = Redis.new @redis_options
            @@signal_queue.clear
          end
          @@watching = $$
          retries = 0
          Fiber.new do
            begin
              @@redis_watcher.subscribe(SIGNAL_QUEUE_CHANNEL) do |on|
                on.subscribe do |channel,|
                  if channel == SIGNAL_QUEUE_CHANNEL
                    @@watcher_subscribed = true
                    retries = 0
                    wakeup_queue_all
                  end
                end
                on.message do |channel, message|
                  if channel == SIGNAL_QUEUE_CHANNEL
                    handlers = {}
                    Marshal.load(message).each do |name|
                      handlers[@@signal_queue[name].first] = true if @@signal_queue.key?(name)
                    end
                    handlers.keys.each do |handler|
                      handler.call if handler
                    end
                  end
                end
                on.unsubscribe do |channel,|
                  @@watcher_subscribed = false if channel == SIGNAL_QUEUE_CHANNEL
                end
              end
              break
            rescue Redis::BaseConnectionError, EventMachine::ConnectionError => e
              @@watcher_subscribed = false
              warn e.message
              retries+= 1
              if retries > @@connection_retry_max && @@connection_retry_max >= 0
                @@watching = false
              else
                sleep retries > 1 ? 1 : 0.1
              end
            end while watching?
          end.resume
          until @@watcher_subscribed
            raise MutexError, "Can not establish watcher channel connection!" unless watching?
            fiber = Fiber.current
            ::EM.next_tick { fiber.resume }
            Fiber.yield
          end
        end

        # EM sleep helper
        def sleep(seconds)
          fiber = Fiber.current
          ::EM::Timer.new(secs) { fiber.resume }
          Fiber.yield
        end

        # Stops the watcher of the "unlock" channel.
        # It should be called before stoping EvenMachine otherwise
        # EM might wait forever for channel connection to be closed.
        #
        # Raises MutexError if there are still some fibers waiting for a lock.
        # Pass `true` to forcefully stop it. This might instead cause
        # MutexError to be raised in waiting fibers.
        def stop_watcher(force = false)
          return unless watching?
          raise MutexError, "call #{self.class}::setup first" unless @@redis_watcher
          unless @@signal_queue.empty? || force
            raise MutexError, "can't stop: active signal queue handlers"
          end
          @@watching = false
          if @@watcher_subscribed
            @@redis_watcher.unsubscribe SIGNAL_QUEUE_CHANNEL
            while @@watcher_subscribed
              fiber = Fiber.current
              ::EM.next_tick { fiber.resume }
              Fiber.yield
            end
          end
        end

        # Remove all current Machine/Process locks.
        # Since there is no lock tracking mechanism, it might not be implemented easily.
        # If the need arises then it probably should be implemented.
        def sweep
          raise NotImplementedError
        end

        # Attempts to grab the lock and waits if it isn’t available.
        # Raises MutexError if mutex was locked by the current owner.
        # Returns instance of Redis::EM::Mutex if lock was successfully obtained.
        # Returns `nil` if lock wasn't available within `:block` seconds.
        #
        #   Redis::EM::Mutex.lock(*names, opts = {})
        #
        # - *names = lock identifiers - if none they are auto generated
        # - opts = options hash:
        # - :name - same as name (in case *names arguments were omitted)
        # - :block - block timeout
        # - :expire - expire timeout (see: Mutex#lock and Mutex#try_lock)
        # - :ns - namespace (otherwise global namespace is used)
        def lock(*args)
          mutex = new(*args)
          mutex if mutex.lock
        end
        # Execute block of code protected with named semaphore.
        # Returns result of code block.
        #
        #   Redis::EM::Mutex.synchronize(*names, opts = {}, &block)
        # 
        # - *names = lock identifiers - if none they are auto generated
        # - opts = options hash:
        # - :name - same as name (in case *names arguments were omitted)
        # - :block - block timeout
        # - :expire - expire timeout (see: Mutex#lock and Mutex#try_lock)
        # - :ns - namespace (otherwise global namespace is used)
        # 
        # If `:block` is set and lock isn't obtained within `:block` seconds this method raises
        # MutexTimeout.
        def synchronize(*args, &block)
          new(*args).synchronize(&block)
        end
      end

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
