class Redis
  module EM
    class Mutex
      class NS
        attr_reader :ns
        alias_method :namespace, :ns
        # Creates a new namespace (Mutex factory).
        #
        # - ns = namespace
        # - opts = options hash:
        # - :block - default block timeout
        # - :expire - default expire timeout
        def initialize(ns, opts = {})
          @ns = ns
          @opts = (opts || {}).merge(:ns => ns)
        end

        # Creates a namespaced cross machine/process/fiber semaphore.
        #
        # for arguments see: Redis::EM::Mutex.new
        def new(*args)
          if args.last.kind_of?(Hash)
            args[-1] = @opts.merge(args.last)
          else
            args.push @opts
          end
          Redis::EM::Mutex.new(*args)
        end

        # Attempts to grab the lock and waits if it isn't available.
        # 
        # See: Redis::EM::Mutex.lock
        def lock(*args)
          mutex = new(*args)
          mutex if mutex.lock
        end

        # Executes block of code protected with namespaced semaphore.
        #
        # See: Redis::EM::Mutex.synchronize
        def synchronize(*args, &block)
          new(*args).synchronize(&block)
        end
      end
    end
  end
end
