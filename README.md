redis-em-mutex
==============

Author: Rafał Michalski  (mailto:rafal@yeondir.com)

* http://github.com/royaltm/redis-em-mutex

DESCRIPTION
-----------

__redis-em-mutex__ is the cross server/process/fiber|owner EventMachine + Redis based semaphore.

FEATURES
--------

* EventMachine reactor based
* carefully designed, well thought out locking pattern
  (NOT the flawed SETNX/GET/GETSET one from redis documentation page)
* no CPU-intensive sleep/polling while waiting for lock to become available;
  fibers waiting for the lock are signalled via Redis channel as soon as the lock
  is released (~< 1 ms)
* alternative fast "script" handler (server-side LUA script based - redis-server 2.6.x)
* multi-locks (all-or-nothing) locking (to prevent possible deadlocks when
  multiple semaphores are required to be locked at once)
* fiber-safe
* deadlock detection (only trivial cases: locking twice the same resource from the same owner)
* mandatory lock lifetime expiration (with refreshing)
* macro-style definitions (Mutex::Macro mixin)
* compatible with Synchrony::Thread::ConditionVariable
* extendable (beyond fibers) mutex ownership
* redis HA achievable with [redis-sentinel](http://redis.io/topics/sentinel) and [redis-sentinel](https://github.com/flyerhzm/redis-sentinel) gem.

BUGS/LIMITATIONS
----------------

* only for EventMachine
* NOT thread-safe (not meant to be)
* locking order between concurrent processes is undetermined (no FIFO between processes)
  however during {file:BENCHMARK.md BENCHMARKING} no starvation effect was observed.
* it's not nifty, rather somewhat complicated

REQUIREMENTS
------------

* ruby >= 1.9 (tested: ruby 1.9.3p374, 1.9.3-p194, 1.9.2-p320, 1.9.1-p378)
* http://github.com/redis/redis-rb ~> 3.0.2
* http://rubyeventmachine.com ~> 1.0.0
* (optional) http://github.com/igrigorik/em-synchrony
  But due to the redis/synchrony dependency em-synchrony will always be bundled
  and required.

INSTALL
-------

```
$ [sudo] gem install redis-em-mutex
```

#### Gemfile

```ruby
gem "redis-em-mutex", "~> 0.3.1"
```

#### Github

```
git clone git://github.com/royaltm/redis-em-mutex.git
```

UPGRADING
---------

0.2.x -> 0.3.x

To upgrade redis-em-mutex on production from 0.2.x to 0.3.x you must make sure the correct handler has been
selected. See more on HANDLERS below.

The "pure" and "script" handlers are incompatible. Two different handlers must not utilize the same semaphore-key space.

Because only the "pure" handler is compatible with redis-em-mutex <= 0.2.x, when upgrading live production make sure to add
`handler: :pure` option to `Redis::EM::Mutex.setup` or set the environment variable on production app servers:

```sh
  REDIS_EM_MUTEX_HANDLER=pure
  export REDIS_EM_MUTEX_HANDLER
```

Upgrading from "pure" to "script" handler requires that all "pure" handler locks __MUST BE DELETED__ from redis-server beforehand.
Neglecting that will result in possible deadlocks. The "script" handler assumes that the lock expiration process is handled
by redis-server's PEXPIREAT feature. The "pure" handler does not set timeouts on keys. It handles expiration differently.

USAGE
-----

```ruby
    require 'em-synchrony'
    require 'redis-em-mutex'

    Redis::EM::Mutex.setup(size: 10, url: 'redis:///1', expire: 600)

    # or

    Redis::EM::Mutex.setup do |opts|
      opts.size = 10
      opts.url = 'redis:///1'
    end


    EM.synchrony do
      Redis::EM::Mutex.synchronize('resource.lock') do
        # ... do something with resource
      end

      # or 

      mutex = Redis::EM::Mutex.new('resource.lock')
      mutex.synchronize do
        # ... do something with resource
      end

      # or

      begin
        mutex.lock
        # ... do something with resource
      ensure
        mutex.unlock
      end

      # ...

      Redis::EM::Mutex.stop_watcher
      EM.stop
    end
```

### Handlers

There are 2 different mutex implementations since version 0.3.

* The "pure" classic handler utilizes redis optimistic transaction commands (watch/multi).
  This handler works with redis-server 2.4.x and later.
* The new "script" handler takes advantage of fast atomic server side operations written in LUA.
  Therefore the "script" handler is compatible only with redis-server 2.6.x and later.

__IMPORTANT__: The "pure" and "script" implementations are incompatible. The values that each handler stores in semaphore keys have different meaning to them.
You can not operate on the same set of keys using both handlers from e.g. different applications or application versions.
See UPGRADING for more info on this.

You choose your preferred implementation with `handler` option:

```ruby
    Redis::EM::Mutex.setup(handler: :script)
    Redis::EM::Mutex.handler # "Redis::EM::Mutex::ScriptHandlerMixin"

    # or

    Redis::EM::Mutex.setup do |opts|
      opts.handler = :pure
    end
    Redis::EM::Mutex.handler # "Redis::EM::Mutex::PureHandlerMixin"
```

You may also setup `REDIS_EM_MUTEX_HANDLER` environment variable to preferred implementation name.
Passing `handler` option to {Redis::EM::Mutex.setup} overrides environment variable.

The default handler option is `auto` which selects best handler available for your redis-server.
It's good for quick sandbox setup, however you should set explicitly which handler you require on production.

The differences:

* Performance. The "script" handler is faster then the "pure" handler.
  The "pure" handler generates twice as much CPU load as "script" handler.
  See {file:BENCHMARK.md BENCHMARK}.

* Expiration. The "script" implementation handler uses PEXPIREAT to mark semaphore life-time.
  The "pure" handler stores semaphore expiry timestamp in key value.
  Therefore the "script" handler can't refresh semaphores once they expire.
  The "pure" handler on the other hand could refresh expired semaphore but only
  if nothing else has locked on that expired key.

To detect feature of the current handler:

```ruby
  Redis::EM::Mutex.can_refresh_expired?           # true / false
  Redis::EM::Mutex.new(:foo).can_refresh_expired? # true / false
```

### Namespaces

```ruby
  Redis::EM::Mutex.setup(ns: 'Tudor')

  # or multiple namespaces:

  ns = Redis::EM::Mutex::NS.new('Tudor')

  EM.synchrony do
    ns.synchronize('Boscogne') do
      # .... do something special with Tudor:Boscogne
    end

    EM.stop
  end
```

### Multi-locks

This feature enables you to lock more then one key at the same time.
The multi key semaphores are deadlock-safe.

The classic deadlock example scenario with multiple resources:

* A acquires lock on resource :foo
* B acquires lock on resource :bar
* A tries to lock on resource :bar still keeping the :foo
* but at the same time B tries to acquire :foo while keeping the :bar.
* The deadlock occurs.

```ruby
  EM.synchrony do
    Redis::EM::Mutex.synchronize('foo', 'bar', 'baz') do
      # .... do something special with foo, bar and baz
    end

    # ...
    EM.stop
  end
```

### Locking options

```ruby
  EM.synchrony do
    begin
      Redis::EM::Mutex.synchronize('foo', 'bar', block: 0.25) do
        # .... do something with foo and bar
      end
    rescue Redis::EM::Mutex::MutexTimeout
      # ... locking timed out
    end

    Redis::EM::Mutex.synchronize('foo', 'bar', expire: 60) do |mutex|
      # .... do something with foo and bar in less than 60 seconds
      if mutex.refresh(120)
        # now we have additional 120 seconds until lock expires
      else
        # too late
      end
    end

    # ...
    EM.stop
  end
```

### Macro-style definition

Idea of macro-style definition was borrowed from http://github.com/kenn/redis-mutex.
Redis::EM::Mutex::Macro is a mixin which protects selected instance methods of a class with a mutex.
The locking scope will be Mutex global namespace + class name + method name.

```ruby
  class TheClass
    include Redis::EM::Mutex::Macro
  
    auto_mutex
    def critical_run
      # ... do some critical stuff
      # ....only one fiber in one process on one machine is executing
      #     this instance method of any instance of defined class
    end

    auto_mutex expire: 100, ns: '**TheClass**'
    # all critical methods defined later will inherit above options unless overridden
  
    auto_mutex # start and stop will be protected
    def start
      # ...
    end

    def stop
      # ...
    end

    no_auto_mutex
    def some_unprotected_method
      # ...
    end

    auto_mutex :run_long, expire: 100000, block: 10, on_timeout: :cant_run
    def run_long
      # ...
    end

    def cant_run
      # ...
    end

    def foo
      # ...
    end
    auto_mutex :foo, block: 0, on_timeout: proc { puts 'bar!' }

  end
```

### ConditionVariable

`Redis::EM::Mutex` may be used with `EventMachine::Synchrony::Thread::ConditionVariable`
in place of `EventMachine::Synchrony::Thread::Mutex`.

```ruby
  mutex = Redis::EM::Mutex.new('resource')
  resource = EM::Synchrony::Thread::ConditionVariable.new
  EM::Synchrony.next_tick do
    mutex.synchronize {
      # current fiber now needs the resource
      resource.wait(mutex)
      # current fiber can now have the resource
    }
  end
  EM::Synchrony.next_tick do
    mutex.synchronize {
      # current fiber has finished using the resource
      resource.signal
    }
  end
```

### Advanced

#### Customized owner

In some cases you might want to extend the ownership of a locked semaphore beyond the current fiber.
That is to be able to "share" a locked semaphore between group of fibers associated with some external resource.

For example we want to allow only one connection from one ip address to be made to our group of servers
at the same time.
Of course you could configure some kind of load balancer that distributes your load to do that for you,
but let's just assume that the load balancer has no such features available.

The default "owner" of a locked semaphore consists of 3 parts: "Machine uuid" + "process pid" + "fiber id".
Redis::EM::Mutex allows you to replace the last part of the "owner" with your own value.
To customize mutex's "ownership" you should add :owner option to the created mutex,
passing some well defined owner id.
In our case the "scope" of a mutex will be the client's ip address and the "owner id"
will be an __id__ of an EventMachine::Connection object created upon connection from the client.
This way we make sure that any other connection from the same ip address made to any server and process
will have different ownership defined. At the same time all the fibers working with that Connection instance
can access mutex's #refresh and #unlock methods concurrently.

```ruby
  module MutexedConnection
    def post_init
      @buffer = ""
      @mutex = nil
      ip = Socket.unpack_sockaddr_in(get_peername).last
      Fiber.new do
        @mutex = Redis::EM::Mutex.lock(ip, block: 0, owner: self.__id__)
        if @mutex
          send_data "Hello #{ip}!"
          #... initialize stuff
        else
          send_data "Duplicate connection not allowed!"
          close_connection_after_writing
        end
      end.resume
    end

    def unbind
      if @mutex
        Fiber.new { @mutex.unlock! }.resume
      end
    end

    def receive_data(data)
      @buffer << data
      return unless @mutex
      Fiber.new do
        if @mutex.refresh # refresh expiration timeout
          # ... handle data
        else
          close_connection_after_writing
        end
      end.resume
    end
  end

  EM::Synchrony.run {
    Redis::EM::Mutex.setup(size: 10, url: 'redis:///1', expire: 600)
    EM.start_server "0.0.0.0", 6969, MutexedConnection
  }
```

#### Forking live

You may safely fork process while running event reactor and having locked semaphores.
The locked semaphores in newly forked process will become unlocked while
their locked status in parent process will be preserved.


```ruby
  mutex = Redis::EM::Mutex.new('pirkaff', 'roshinu', expire: 60)

  EM.synchrony do
    mutex.lock

    EM.fork_reactor do
      Fiber.new do
        mutex.locked? # true
        mutex.owned?  # false
        mutex.synchronize do
          mutex.locked? # true
          mutex.owned?  # true

          # ...
        end

        # ...
        Redis::EM::Mutex.stop_watcher
        EM.stop
      end.resume
    end

    mutex.locked? # true
    mutex.owned?  # true

    mutex.unlock
    mutex.owned?  # false

    # ...
    Redis::EM::Mutex.stop_watcher
    EM.stop
  end
```

#### Redis factory

Want to use some non-standard redis options or customized redis client?
`redis_factory` option to the rescue.

High Availability example setup with redis-sentinel:

```ruby
  gem 'redis-sentinel', '~> 1.1.4'
  require 'redis-em-mutex'
  require 'redis-sentinel'
  Redis::Client.class_eval do
    define_method(:sleep) {|n| EM::Synchrony.sleep(n) }
  end

  REDIS_OPTS = {password: 'fight or die', db: 1}
  SENTINEL_OPTS = {
    master_name: "femto",
    sentinels: [{host: "wyald", port: 26379}, {host: "zodd", port: 26379}],
    failover_reconnect_timeout: 30
  }

  Redis::EM::Mutex.setup(REDIS_OPTS) do |config|
    config.size = 5                 # redis pool size
    config.reconnect_max = :forever # reconnect watcher forever
    config.redis_factory = proc do |opts|
      Redis.new opts.merge SENTINEL_OPTS
    end
  end
```

ADVOCACY
--------

Interesting (not eventmachine oriented) ruby-redis-mutex implementations:

* [mlanett/redis-lock](https://github.com/mlanett/redis-lock)
  Robust, well thought out and nice to use as it simply adds lock/unlock
  commands to Redis.
  Similar concept of locking/unlocking pattern (compared to the "pure" handler)
  though it uses two redis keys for keeping owner and lifetime expiration separately.
  "pure" handler stores both in one key, so less redis operations are involved.
  Blocked lock failure is handled by sleep/polling which involves more cpu load
  on ruby and redis. You may actually see it by running `time test/stress.rb`
  tool on both implementations and compare user/sys load.

* [dv/redis-semaphore](https://github.com/dv/redis-semaphore)
  Very promising experiment. Utilizes BLPOP to provide real FIFO queue of
  lock acquiring processes. In this way it doesn't need polling nor other means
  of signaling that the lock is available to those in waiting queue.
  This one could be used with EM straight out without any patching.

  IMHO the solution has two drawbacks:

  - no lifetime expiration or other means of protection from failure of a lock owner process;
    still they are trying hard to implement it [now](https://github.com/dv/redis-semaphore/pull/5)
    and I hope they will succeed.

  - the redis keys are used in an inversed manner: the lack of a key means that the lock is gone.
    On the contrary, when the lock is being released, the key is created and kept.
    This is not a problem when you have some static set of keys. However it might be a problem
    when you need to use lock keys based on random resources and you would need to implement
    some garbage collector to prevent redis from eating to much memory.
