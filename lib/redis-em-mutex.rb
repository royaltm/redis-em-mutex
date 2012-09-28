if defined?(::Redis) && ::Redis.const_defined?(:EM, false) && ::Redis::EM.const_defined?(:Mutex, false)
  require 'redis/em-mutex'
else
  class Redis
    module EM
      autoload :Mutex, 'redis/em-mutex'
    end
  end
end
