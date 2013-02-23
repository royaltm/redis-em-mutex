class Redis
  module EM
    class Mutex
      module PureHandlerMixin
        include Mutex::Errors

        def self.can_refresh_expired?; true end

        private

        def post_init(opts)
          @locked_owner_id = @locked_id = nil
          if (owner = opts[:owner])
            self.define_singleton_method(:owner_ident) do |lock_id = nil|
              if lock_id
                "#{uuid}$#$$@#{owner} #{lock_id}"
              else
                "#{uuid}$#$$@#{owner}"
              end
            end
            opts = nil
          end
        end

        public

        # Returns `true` if this semaphore (at least one of locked `names`) is currently being held by some owner.
        def locked?
          if @multi
            redis_pool.multi do |multi|
              @ns_names.each {|n| multi.exists n}
            end.any?
          else
            redis_pool.exists @ns_names.first
          end
        end

        # Returns `true` if this semaphore (all the locked `names`) is currently being held by calling owner.
        # This is the method you should use to check if lock is still held and valid.
        def owned?
          !!if @locked_id && owner_ident(@locked_id) == (lock_full_ident = @locked_owner_id)
            redis_pool.mget(*@ns_names).all? {|v| v == lock_full_ident}
          end
        end

        # Returns `true` when the semaphore is being held and have already expired.
        # Returns `false` when the semaphore is still locked and valid
        # or `nil` if the semaphore wasn't locked by current owner.
        #
        # The check is performed only on the Mutex object instance and should only be used as a hint.
        # For reliable lock status information use #refresh or #owned? instead.
        def expired?
          Time.now.to_f > @locked_id.to_f if @locked_id && owner_ident(@locked_id) == @locked_owner_id
        end

        # Returns the number of seconds left until the semaphore expires.
        # The number of seconds less than 0 means that the semaphore expired and could be grabbed
        # by some other owner.
        # Returns `nil` if the semaphore wasn't locked by current owner.
        #
        # The check is performed only on the Mutex object instance and should only be used as a hint.
        # For reliable lock status information use #refresh or #owned? instead.
        def expires_in
          @locked_id.to_f - Time.now.to_f if @locked_id && owner_ident(@locked_id) == @locked_owner_id
        end

        # Returns local time at which the semaphore will expire or have expired.
        # Returns `nil` if the semaphore wasn't locked by current owner.
        #
        # The check is performed only on the Mutex object instance and should only be used as a hint.
        # For reliable lock status information use #refresh or #owned? instead.
        def expires_at
          Time.at(@locked_id.to_f) if @locked_id && owner_ident(@locked_id) == @locked_owner_id
        end

        # Returns timestamp at which the semaphore will expire or have expired.
        # Returns `nil` if the semaphore wasn't locked by current owner.
        #
        # The check is performed only on the Mutex object instance and should only be used as a hint.
        # For reliable lock status information use #refresh or #owned? instead.
        def expiration_timestamp
          @locked_id.to_f if @locked_id && owner_ident(@locked_id) == @locked_owner_id
        end

        # This method is only for internal use.
        #
        # Attempts to obtain the lock and returns immediately.
        # Returns `true` if the lock was granted.
        # Use Mutex#expire_timeout= to set lock expiration time in secods.
        # Otherwise global Mutex.default_expire is used.
        #
        # This method doesn't capture expired semaphores
        # and therefore it should NEVER be used under normal circumstances.
        # Use Mutex#lock with block_timeout = 0 to obtain expired lock without blocking.
        def try_lock
          lock_id = (Time.now + expire_timeout).to_f.to_s
          lock_full_ident = owner_ident(lock_id)
          !!if @multi
            if redis_pool.msetnx(*@ns_names.map {|k| [k, lock_full_ident]}.flatten)
              @locked_id = lock_id
              @locked_owner_id = lock_full_ident
            end
          elsif redis_pool.setnx(@ns_names.first, lock_full_ident)
            @locked_id = lock_id
            @locked_owner_id = lock_full_ident
          end
        end

        # Refreshes lock expiration timeout.
        # Returns `true` if refresh was successfull.
        # Returns `false` if the semaphore wasn't locked or when it was locked but it has expired
        # and now it's got a new owner.
        def refresh(expire_timeout=nil)
          ret = false
          if @locked_id && owner_ident(@locked_id) == (lock_full_ident = @locked_owner_id)
            new_lock_id = (Time.now + (expire_timeout.to_f.nonzero? || self.expire_timeout)).to_f.to_s
            new_lock_full_ident = owner_ident(new_lock_id)
            redis_pool.watch(*@ns_names) do |r|
              if r.mget(*@ns_names).all? {|v| v == lock_full_ident}
                if r.multi {|m| m.mset(*@ns_names.map {|k| [k, new_lock_full_ident]}.flatten)}
                  @locked_id = new_lock_id
                  @locked_owner_id = new_lock_full_ident
                  ret = true
                end
              else
                r.unwatch
              end
            end
          end
          ret
        end

        # Releases the lock. Returns self on success.
        # Returns `false` if the semaphore wasn't locked or when it was locked but it has expired
        # and now it's got a new owner.
        # In case of unlocking multiple name semaphore this method returns self only when all
        # of the names have been unlocked successfully.
        def unlock!
          sem_left = @ns_names.length
          if (locked_id = @locked_id) && owner_ident(locked_id) == (lock_full_ident = @locked_owner_id)
            @locked_owner_id = @locked_id = nil
            @ns_names.each do |name|
              redis_pool.watch(name) do |r|
                if r.get(name) == lock_full_ident
                  if (r.multi {|multi|
                    multi.del(name)
                    multi.publish SIGNAL_QUEUE_CHANNEL, @marsh_names if !@multi && Time.now.to_f < locked_id.to_f
                  })
                    sem_left -= 1
                  end
                else
                  r.unwatch
                end
              end
            end
            redis_pool.publish SIGNAL_QUEUE_CHANNEL, @marsh_names if @multi && Time.now.to_f < locked_id.to_f
          end
          sem_left.zero? && self
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
          sig_proc = proc do
            try_again = true
            ::EM.next_tick { fiber.resume if fiber } if fiber
          end
          begin
            Mutex.start_watcher unless watching?
            queues = names.map {|n| signal_queue[n] << sig_proc }
            ident_match = owner_ident
            until try_lock
              start_time = Time.now.to_f
              expire_time = nil
              redis_pool.watch(*names) do |r|
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
                  end
                else
                  r.unwatch
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
            queues.each {|q| q.delete sig_proc }
            names.each {|n| signal_queue.delete(n) if signal_queue[n].empty? }
          end
        end

        def owner_ident(lock_id = nil)
          if lock_id
            "#{uuid}$#$$@#{Fiber.current.__id__} #{lock_id}"
          else
            "#{uuid}$#$$@#{Fiber.current.__id__}"
          end
        end

      end
    end
  end
end
