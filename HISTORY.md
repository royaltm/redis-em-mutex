0.3.0
- fixed: optimized pure handler
- added redis/em-connection-pool no more em-synchrony/connection_pool dependency
- added redis gem dependency updated to 3.0.2
- added owner_ident specs
- added redis-lua script handler
- added #can_refresh_expired? handler feature detection
- added handlers

0.2.3
- fixed: rare unlock! race condition introduced in 0.2.1
  manifesting as deadlock exception when no deadlock should occur

0.2.2
- fixed: uuid must be set only once
- fixed: forking process or setup before reactor is running would hang
  current fiber forever on first failed lock
- added: new setup option :redis_factory
- fixed: doc format errors

0.2.1
- fixed: sleep
- fixed: possible deadlock after #unlock! with multiple names

0.2.0
- added compatibility with EM::Synchrony::Thread::ConditionVariable
- added #sleep and #wakeup
- moved Redis::EM::Mutex::NS to autoloaded file
- added #unlock! and now mutex object stores ownership information
- added #expired? and other expiration status methods
- added watching? helper
- added customizable ownership

0.1.2
- features macro-style definitions
- fixed: setup with :redis
- added macros spec
- added more setup features spec

0.1.1
- fixed: namespaces didn't work
- added namespaces spec
- fixed: rare race condition could raise ArgumentError inside Mutex#lock()
- fixed: Mutex.stop_watching raised MutexError after changing internal state
- fixed: semaphores spec updated
- fixed: ruby-1.9.1 has no SecureRandom.uuid method

0.1.0
- first release
