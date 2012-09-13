class Redis
  module EM
    class Mutex
      # Macro-style definition
      #
      # idea and some code borrowed from http://github.com/kenn/redis-mutex and enhanced
      #
      # class ClassWithCriticalMethods
      #   include Redis::EM::Mutex::Macro
      #
      #   auto_mutex
      #   def critical
      #     ... do some critical stuff
      #     ....only one fiber in one process on one machine is executing this instance method of any instance of defined class
      #   end
      # end
      #
      module Macro
        def self.included(klass)
          klass.extend ClassMethods
          klass.class_eval do
            class << self
              attr_reader :auto_mutex_methods, :auto_mutex_options
              attr_accessor :auto_mutex_enabled
            end
            @auto_mutex_methods = {}
            @auto_mutex_options = {:ns => Redis::EM::Mutex.ns ? "#{Redis::EM::Mutex.ns}:#{klass.name}" : klass.name}
            @auto_mutex_enabled = false
          end
        end

        module ClassMethods
          # auto_mutex [*method_names], [options]
          #
          # options are:
          # - :expire - see Mutex.new
          # - :block  - see Mutex.new
          # - :ns     - custom namespace, if not present name of the class that includes Macro is used
          # - :on_timeout - if defined, this proc/method will be called instead of raising MutexTimeout error
          #
          # If method_names are provided (names of already defined methods or defined in the future)
          # they become protected with mutex.
          #
          # If options are provided wihout method_names, they will become default options
          # for subsequent auto_mutex calls.
          #
          # If auto_mutex is called without arguments then any method further defined will also be protected.
          # To disable implicit auto_mutex use no_auto_mutex.
          def auto_mutex(*args)
            options = args.last.kind_of?(Hash) ? args.pop : {}
            if args.each {|target|
                self.auto_mutex_methods[target] = self.auto_mutex_options.merge(options)
                auto_mutex_method_added(target) if method_defined? target
              }.empty?
              if options.empty?
                self.auto_mutex_enabled = true
              else
                self.auto_mutex_options.update(options)
              end
            end
          end

          # Switch off implicit auto_mutex.
          # After calling no_auto_mutex if any new method is defined it won't be protected
          # unless explicitely specified with auto_mutex.
          def no_auto_mutex
            self.auto_mutex_enabled = false
          end

          def method_added(target)
            return if target.to_s =~ /_(?:with|without|on_timeout)_auto_mutex$/
            return unless self.auto_mutex_methods[target] || self.auto_mutex_enabled
            auto_mutex_method_added(target)
          end

          def auto_mutex_method_added(target)
            without_method  = "#{target}_without_auto_mutex"
            with_method     = "#{target}_with_auto_mutex"
            timeout_method  = "#{target}_on_timeout_auto_mutex"
            return if method_defined?(without_method)

            options = self.auto_mutex_methods[target] || self.auto_mutex_options
            mutex = nil

            on_timeout = options[:on_timeout] || options[:after_failure]

            if on_timeout.respond_to?(:call)
              define_method(timeout_method, &on_timeout)
            elsif on_timeout.is_a?(Symbol)
              timeout_method = on_timeout
            end

            define_method(with_method) do |*args, &blk|
              mutex||= Redis::EM::Mutex.new target, options
              response = nil

              begin
                if mutex.refresh
                  response = __send__(without_method, *args, &blk)
                else
                  mutex.synchronize do
                    response = __send__(without_method, *args, &blk)
                  end
                end
              rescue Redis::EM::Mutex::MutexTimeout => e
                if respond_to?(timeout_method)
                  response = __send__(timeout_method, *args, &blk)
                else
                  raise e
                end
              end

              response
            end

            alias_method without_method, target
            alias_method target, with_method
          end
        end
      end
    end
  end
end