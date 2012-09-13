if defined?(Redis::EM::Mutex)
  require 'redis/em-mutex'
else
  class Redis
    module EM
      autoload :Mutex, 'redis/em-mutex'
    end
  end
end
