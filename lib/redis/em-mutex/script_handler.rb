require 'digest'
class Redis
  module EM
    class Mutex
      module ScriptHandlerMixin
        include Mutex::Errors

        def self.can_refresh_expired?; false end

        private

        def post_init(opts)
          @locked_owner_id = @lock_expire = nil
          @scripts = if @multi
            Scripts::MULTI
          else
            Scripts::SINGLE
          end
          @eval_try_lock,
          @eval_lock,
          @eval_unlock,
          @eval_refresh,
          @eval_is_locked = @scripts.keys
          if (owner = opts[:owner])
            self.define_singleton_method(:owner_ident) do
              "#{uuid}$#$$@#{owner}"
            end
            opts = nil
          end
        end

        NOSCRIPT = 'NOSCRIPT'.freeze

        def eval_safe(sha1, keys, args = nil)
          redis_pool.evalsha(sha1, keys, args)
        rescue CommandError => e
          if e.message.start_with? NOSCRIPT
            redis_pool.script :load, @scripts[sha1]
            retry
          else
            raise
          end
        end

        public

        def owner_ident
          "#{uuid}$#$$@#{Fiber.current.__id__}"
        end

        # Returns `true` if this semaphore (at least one of locked `names`) is currently being held by some owner.
        def locked?
          if sha1 = @eval_is_locked
            1 == eval_safe(sha1, @ns_names)
          else
            redis_pool.exists @ns_names.first
          end
        end

        # Returns `true` if this semaphore (all the locked `names`) is currently being held by calling owner.
        # This is the method you should use to check if lock is still held and valid.
        def owned?
          !!if owner_ident == (lock_full_ident = @locked_owner_id)
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
          Time.now.to_f > @lock_expire if @lock_expire && owner_ident == @locked_owner_id
        end

        # Returns the number of seconds left until the semaphore expires.
        # The number of seconds less than 0 means that the semaphore expired and could be grabbed
        # by some other owner.
        # Returns `nil` if the semaphore wasn't locked by current owner.
        #
        # The check is performed only on the Mutex object instance and should only be used as a hint.
        # For reliable lock status information use #refresh or #owned? instead.
        def expires_in
          @lock_expire.to_f - Time.now.to_f if @lock_expire && owner_ident == @locked_owner_id
        end

        # Returns local time at which the semaphore will expire or have expired.
        # Returns `nil` if the semaphore wasn't locked by current owner.
        #
        # The check is performed only on the Mutex object instance and should only be used as a hint.
        # For reliable lock status information use #refresh or #owned? instead.
        def expires_at
          Time.at(@lock_expire) if @lock_expire && owner_ident == @locked_owner_id
        end

        # Returns timestamp at which the semaphore will expire or have expired.
        # Returns `nil` if the semaphore wasn't locked by current owner.
        #
        # The check is performed only on the Mutex object instance and should only be used as a hint.
        # For reliable lock status information use #refresh or #owned? instead.
        def expiration_timestamp
          @lock_expire if @lock_expire && owner_ident == @locked_owner_id
        end

        # Attempts to obtain the lock and returns immediately.
        # Returns `true` if the lock was granted.
        # Use Mutex#expire_timeout= to set lock expiration time in secods.
        # Otherwise global Mutex.default_expire is used.
        #
        # This method captures expired semaphores only in "script" implementation
        # and therefore it should NEVER be used under normal circumstances.
        # Use Mutex#lock with block_timeout = 0 to obtain expired lock without blocking.
        def try_lock
          lock_expire = (Time.now + expire_timeout).to_f
          lock_full_ident = owner_ident
          !!if 1 == eval_safe(@eval_try_lock, @ns_names, [lock_full_ident, (lock_expire*1000.0).to_i])
            @lock_expire = lock_expire
            @locked_owner_id = lock_full_ident
          end
        end

        # Refreshes lock expiration timeout.
        # Returns `true` if refresh was successfull.
        # Returns `false` if the semaphore wasn't locked or when it was locked but it has expired
        # and now it's got a new owner.
        def refresh(expire_timeout=nil)
          if @lock_expire && owner_ident == (lock_full_ident = @locked_owner_id)
            lock_expire = (Time.now + (expire_timeout.to_f.nonzero? || self.expire_timeout)).to_f
            case keys = eval_safe(@eval_refresh, @ns_names, [lock_full_ident, (lock_expire*1000.0).to_i])
            when 1
              @lock_expire = lock_expire
              return true
            end
          end
          return false
        end

        # Releases the lock. Returns self on success.
        # Returns `false` if the semaphore wasn't locked or when it was locked but it has expired
        # and now it's got a new owner.
        # In case of unlocking multiple name semaphore this method returns self only when all
        # of the names have been unlocked successfully.
        def unlock!
          if (lock_expire = @lock_expire) && owner_ident == (lock_full_ident = @locked_owner_id)
            @locked_owner_id = @lock_expire = nil
            removed = eval_safe(@eval_unlock, @ns_names, [lock_full_ident])
            redis_pool.publish SIGNAL_QUEUE_CHANNEL, @marsh_names if Time.now.to_f < lock_expire
          end
          return removed == @ns_names.length && self
        end

        # Attempts to grab the lock and waits if it isn't available.
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
            loop do
              start_time = Time.now.to_f
              case timeout = eval_safe(@eval_lock, @ns_names, [ident_match,
                ((lock_expire = (Time.now + expire_timeout).to_f)*1000.0).to_i])
              when 'OK'
                @locked_owner_id = ident_match
                @lock_expire = lock_expire
                break
              when 'DD'
                raise MutexError, "deadlock; recursive locking #{ident_match}"
              else
                expire_time = start_time + (timeout/=1000.0)
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
            end
            true
          ensure
            timer.cancel if timer
            timer = nil
            queues.each {|q| q.delete sig_proc }
            names.each {|n| signal_queue.delete(n) if signal_queue[n].empty? }
          end
        end

        module Scripts
          # * lock multi *keys, lock_id, msexpire_at
          # * > 1
          # * > 0
          TRY_LOCK_MULTI = <<-EOL
            local size=#KEYS
            local lock=ARGV[1]
            local exp=tonumber(ARGV[2])
            local args={}
            for i=1,size do
              args[#args+1]=KEYS[i]
              args[#args+1]=lock
            end
            if 1==redis.call('msetnx',unpack(args)) then
              for i=1,size do
                redis.call('pexpireat',KEYS[i],exp)
              end
              return 1
            end
            return 0
          EOL

          # * lock multi *keys, lock_id, msexpire_at
          # * > OK
          # * > DD (deadlock)
          # * > milliseconds ttl wait
          LOCK_MULTI = <<-EOL
            local size=#KEYS
            local lock=ARGV[1]
            local exp=tonumber(ARGV[2])
            local args={}
            for i=1,size do
              args[#args+1]=KEYS[i]
              args[#args+1]=lock
            end
            if 1==redis.call('msetnx',unpack(args)) then
              for i=1,size do
                redis.call('pexpireat',KEYS[i],exp)
              end
              return 'OK'
            end
            local res=redis.call('mget',unpack(KEYS))
            for i=1,size do
              if res[i]==lock then
                return 'DD'
              end
            end
            exp=nil
            for i=1,size do
              res=redis.call('pttl',KEYS[i])
              if not exp or res<exp then
                exp=res
              end
            end
            return exp
          EOL

          # * unlock multiple *keys, lock_id
          # * > #keys unlocked
          UNLOCK_MULTI = <<-EOL
            local size=#KEYS
            local lock=ARGV[1]
            local args={}
            local res=redis.call('mget',unpack(KEYS))
            for i=1,size do
              if res[i]==lock then
                args[#args+1]=KEYS[i]
              end
            end
            if #args>0 then
              redis.call('del',unpack(args))
            end
            return #args
          EOL

          # * refresh multi *keys, lock_id, msexpire_at
          # * > 1
          # * > 0
          REFRESH_MULTI = <<-EOL
            local size=#KEYS
            local lock=ARGV[1]
            local exp=tonumber(ARGV[2])
            local args={}
            local res=redis.call('mget',unpack(KEYS))
            for i=1,size do
              if res[i]==lock then
                args[#args+1]=KEYS[i]
              end
            end
            if #args==size then
              for i=1,size do
                if 0==redis.call('pexpireat',args[i],exp) then
                  redis.call('del',unpack(args))
                  return 0
                end
              end
              return 1
            elseif #args>0 then
              redis.call('del',unpack(args))
            end
            return 0
          EOL

          # * locked? multi *keys
          # * > 1
          # * > 0
          IS_LOCKED_MULTI = <<-EOL
            for i=1,#KEYS do
              if 1==redis.call('exists',KEYS[i]) then
                return 1
              end
            end
            return 0
          EOL

          # * try_lock single key, lock_id, msexpire_at
          # * > 1
          # * > 0
          TRY_LOCK_SINGLE = <<-EOL
            local key=KEYS[1]
            local lock=ARGV[1]
            if 1==redis.call('setnx',key,lock) then
              return redis.call('pexpireat',key,tonumber(ARGV[2]))
            end
            return 0
          EOL

          # * lock single key, lock_id, msexpire_at
          # * > OK
          # * > DD (deadlock)
          # * > milliseconds ttl wait
          LOCK_SINGLE = <<-EOL
            local key=KEYS[1]
            local lock=ARGV[1]
            if 1==redis.call('setnx',key,lock) then
              redis.call('pexpireat',key,tonumber(ARGV[2]))
              return 'OK'
            end
            if lock==redis.call('get',key) then
              return 'DD'
            end
            return redis.call('pttl',key)
          EOL

          # * unlock single key, lock_id
          # * > 1
          # * > 0
          UNLOCK_SINGLE = <<-EOL
            local key=KEYS[1]
            local res=redis.call('get',key)
            if res==ARGV[1] then
              return redis.call('del',key)
            else
              return 0
            end
          EOL

          # * refresh single key, lock_id, msexpire_at
          # * > 1
          # * > 0
          REFRESH_SINGLE = <<-EOL
            local key=KEYS[1]
            local res=redis.call('get',key)
            if res==ARGV[1] then
              return redis.call('pexpireat',key,tonumber(ARGV[2]))
            end
            return 0
          EOL
        end
        Scripts.constants.each do |name|
          Scripts.const_get(name).tap do |script|
            script.replace script.split("\n").map(&:strip).join(" ").freeze
            Scripts.const_set "#{name}_SHA1", Digest::SHA1.hexdigest(script)
          end
        end
        module Scripts
          MULTI = {
            TRY_LOCK_MULTI_SHA1 => TRY_LOCK_MULTI,
            LOCK_MULTI_SHA1 => LOCK_MULTI,
            UNLOCK_MULTI_SHA1 => UNLOCK_MULTI,
            REFRESH_MULTI_SHA1 => REFRESH_MULTI,
            IS_LOCKED_MULTI_SHA1 => IS_LOCKED_MULTI
          }
          SINGLE = {
            TRY_LOCK_SINGLE_SHA1 => TRY_LOCK_SINGLE,
            LOCK_SINGLE_SHA1 => LOCK_SINGLE,
            UNLOCK_SINGLE_SHA1 => UNLOCK_SINGLE,
            REFRESH_SINGLE_SHA1 => REFRESH_SINGLE,
          }
        end

      end
    end
  end
end
