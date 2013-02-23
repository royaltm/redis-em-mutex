redis-em-mutex
==============

Author: Rafał Michalski  (mailto:rafal@yeondir.com)

* http://github.com/royaltm/redis-em-mutex

DESCRIPTION
-----------

__redis-em-mutex__ is the cross server-process-fiber EventMachine + Redis based semaphore.

FEATURES
--------

* only for EventMachine
* no CPU-intensive sleep/polling while waiting for lock to become available
* fibers waiting for the lock are signalled via Redis channel as soon as the lock
  has been released (~< 1 ms)
* alternative fast handler (server-side LUA script based - redis-server 2.6.x)
* multi-locks (all-or-nothing) locking (to prevent possible deadlocks when
  multiple semaphores are required to be locked at once)
* fiber-safe
* deadlock detection (only trivial cases: locking twice the same resource from the same owner)
* mandatory lock expiration (with refreshing)
* macro-style definitions (Mutex::Macro mixin)
* compatible with Synchrony::Thread::ConditionVariable
* extendable (beyond fibers) mutex ownership

BUGS/LIMITATIONS
----------------

* only for EventMachine
* NOT thread-safe
* locking order between concurrent processes is undetermined (no FIFO)
* it's not nifty, rather somewhat complicated

REQUIREMENTS
------------

* ruby >= 1.9 (tested: ruby 1.9.3p374, 1.9.3-p194, 1.9.2-p320, 1.9.1-p378)
* http://github.com/redis/redis-rb ~> 3.0.2
* http://rubyeventmachine.com ~> 1.0.0
* (optional) http://github.com/igrigorik/em-synchrony

INSTALL
-------

```
$ [sudo] gem install redis-em-mutex
```

#### Gemfile

```ruby
gem "redis-em-mutex", "~> 0.3.0"
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

The "pure" and "script" handlers are not compatible. Two different handlers must not utilize the same semaphore-key space.

Because only the "pure" handler is compatible with redis-em-mutex 0.2.x, when upgrading live production make sure to add
`handler: :pure` option to `Redis::EM::Mutex.setup` or set the environment variable on production app servers:

```sh
  REDIS_EM_MUTEX_HANDLER=pure
  export REDIS_EM_MUTEX_HANDLER
```
Upgrading from "pure" to "script" handler requires that all "pure" handler locks MUST BE DELETED from redis-server beforehand.
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

There are 2 different mutex implementations since version 0.3.0.

* The "pure" classic handler utilizes redis optimistic transaction commands (watch/multi).
  This handler works with redis-server 2.4.x and later.
* The new "script" handler takes advantage of fast atomic server side operations written in LUA.
  Therefore the "script" handler is compatible only with redis-server 2.6.x and later.

__IMPORTANT__: The pure and script implementations are not compatible. The value they store in semaphore keys are different.
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
Passing `handler` option to setup method overrides environment variable.

The default handler option is `auto` which selects best handler available for your redis-server.
It's good for quick sandbox setup, however you should set explicitly which handler you require on production.

The differences:

* The "script" handler is at least twice as fast as "pure" handler. It gains even more
  with multi-locks and during high load. See BENCHMARK.md.

* The "script" implementation handler uses PEXPIREAT to mark semaphore life-time.
  The "pure" handler stores semaphore expiry timestamp in key value.
  Therefore the "script" handler can't refresh semaphores once they are expired.
  The pure handler on the other hand could refresh expired semaphore but only
  if nothing else has locked on that expired key.

To detect feature of the current handler:

```ruby
  Redis::EM::Mutex.can_refresh_expired?           # true / false
  Redis::EM::Mutex.new(:foo).can_refresh_expired? # true / false
```

### Namespaces

```ruby
  Redis::EM::Mutex.setup(ns: 'my_namespace')

  # or multiple namespaces:

  ns = Redis::EM::Mutex::NS.new('my_namespace')

  EM.synchrony do
    ns.synchronize('foo') do
      # .... do something with foo
    end

    # ...
    EM.stop
  end
```

### Multi-locks

They enable you to lock more then one key at the same time. The muliti key semaphores are deadlock-safe.
The classic deadlock example scenario with multiple resources:

* A acquires lock on resource :foo
* B acquires lock on resource :bar
* A tries to lock on resource :bar still keeping the :foo
* but at the same time B tries to acquire :foo while keeping the :bar.
* The deadlock occurs.

```ruby
  EM.synchrony do
    Redis::EM::Mutex.synchronize('foo', 'bar', 'baz') do
      # .... do something with foo, bar and baz
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

Borrowed from http://github.com/kenn/redis-mutex.
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
  mutex = Redis::EM::Mutex.new('resource1', 'resource2', expire: 60)

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

Want to use some non-standard redis options or customized client for semaphore watcher and/or redis pool?
Use `:redis_factory` option then.

```ruby
  require 'redis-sentinel'

  Redis::EM::Mutex.setup do |opts|
    opts.size = 10
    opts.password = 'password'
    opts.db = 11
    opts.redis_factory = proc do |options|
      Redis.new options.merge(
        master_name: "my_master",
        sentinels: [{host: "redis1", port: 6379}, {host: "redis2", port: 6380}])
    end
  end
```

LICENCE
-------

The MIT License - Copyright (c) 2012 Rafał Michalski
