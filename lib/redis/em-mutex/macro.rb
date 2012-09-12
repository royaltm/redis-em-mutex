class Redis
  module EM
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
        def auto_mutex(*args)
          options = args.last.kind_of?(Hash) ? args.pop : {}
          if args.each {|target|
              self.auto_mutex_methods[target] = self.auto_mutex_options.merge(options)
              auto_mutex_method_added(target)
            }.empty?
            if options.empty?
              self.auto_mutex_enabled = true
            else
              self.auto_mutex_options.update(options)
            end
          end
        end

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
          timeout_method    = "#{target}_on_timeout_auto_mutex"
          return if method_defined?(without_method)

          options = self.auto_mutex_methods[target] || self.auto_mutex_options
          mutex = Redis::EM::Mutex.new target, options

          on_timout = options[:on_timout] || options[:after_failure]

          if on_timout.respond_to?(:call)
            define_method(timeout_method, &on_timout)
          end

          define_method(with_method) do |*args, &blk|
            response = nil

            begin
              if mutex.refresh
                response = __send__(without_method, *args, &blk)
              else
                mutex.synchronize do
                  response = __send__(without_method, *args, &blk)
                end
              end
            rescue Redis::EM::MutexTimeout => e
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