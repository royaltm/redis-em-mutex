require 'redis'
class Redis
  module EM
    class ConnectionPool
      def initialize(opts)
        @pool = []
        @queue = []
        @acquired  = {}

        opts[:size].times { @pool << yield }
      end

      %w[
        exists
        setnx
        publish
        script
        msetnx
        eval
        evalsha
      ].each do |name|
        class_eval <<-EOD, __FILE__, __LINE__
          def #{name}(*args)
            execute do |redis|
              redis.#{name}(*args)
            end
          end
        EOD
      end

      %w[
        watch
        mget
      ].each do |name|
        class_eval <<-EOD, __FILE__, __LINE__
          def #{name}(*args, &blk)
            execute do |redis|
              redis.#{name}(*args, &blk)
            end
          end
        EOD
      end

      def multi(&blk)
        execute do |redis|
          redis.multi(&blk)
        end
      end

      def execute
        f = Fiber.current
        begin
          until (conn = acquire f)
            @queue << f
            Fiber.yield
          end
          yield conn
        ensure
          release(f)
        end
      end

      private

      def acquire(fiber)
        if conn = @pool.pop
          @acquired[fiber.__id__] = conn
          conn
        end
      end

      def release(fiber)
        @pool.push(@acquired.delete(fiber.__id__))

        if queue = @queue.shift
          queue.resume
        end
      end

      def method_missing(method, *args, &blk)
        execute do |conn|
          conn.__send__(method, *args, &blk)
        end
      end
    end

  end
end