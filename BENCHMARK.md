BENCHMARK
=========

To measure the performance of {Redis::EM::Mutex} I've wrote a simple script called `test/bench.rb`.
The script is included in respository.

Below are the results of running tests against the following versions:

- redis-em-mutex v0.1.2
- redis-em-mutex v0.2.3
- redis-em-mutex v0.3.1 - "pure" handler
- redis-em-mutex v0.3.1 - "script" handler

To run theese tests type:

```sh
cp test/bench.rb /tmp/benchmark_mutex.rb

git reset --hard v0.1.2
ruby /tmp/benchmark_mutex.rb

git reset --hard v0.2.3
ruby /tmp/benchmark_mutex.rb

git reset --hard v0.3.1
REDIS_EM_MUTEX_HANDLER=pure ruby test/bench.rb
REDIS_EM_MUTEX_HANDLER=script ruby test/bench.rb
```

Here are the results of running those tests on Quad Core Xeon machine
with redis-server 2.6.9 and ruby 1.9.3p374 (2013-01-15 revision 38858) [x86_64-linux].

The results may vary.

Test 1
======

Lock/unlock 1000 times using 10 concurrent fibers.

```
Version: 0.1.2, handler: N/A
lock/unlock 1000 times with concurrency: 10
                    user     system      total        real
keys: 1/ 1      0.500000   0.240000   0.740000 (  0.987120)
keys: 2/ 3      0.700000   0.260000   0.960000 (  1.179436)
keys: 3/ 5      0.890000   0.340000   1.230000 (  1.336847)
keys: 5/ 9      1.010000   0.540000   1.550000 (  1.610321)
keys:10/19      1.480000   0.520000   2.000000 (  2.120616)

Version: 0.2.3, handler: N/A
lock/unlock 1000 times with concurrency: 10
                    user     system      total        real
keys: 1/ 1      0.550000   0.270000   0.820000 (  0.861067)
keys: 2/ 3      0.960000   0.460000   1.420000 (  1.724032)
keys: 3/ 5      1.590000   0.510000   2.100000 (  2.223966)
keys: 5/ 9      2.660000   0.940000   3.600000 (  3.784084)
keys:10/19      5.430000   1.850000   7.280000 (  8.406377)

Version: 0.3.1, handler: Redis::EM::Mutex::PureHandlerMixin
lock/unlock 1000 times with concurrency: 10
                    user     system      total        real
keys: 1/ 1      0.620000   0.210000   0.830000 (  0.869947)
keys: 2/ 3      0.680000   0.310000   0.990000 (  1.044803)
keys: 3/ 5      0.890000   0.340000   1.230000 (  1.267044)
keys: 5/ 9      1.190000   0.370000   1.560000 (  1.576557)
keys:10/19      1.580000   0.490000   2.070000 (  2.123451)

Version: 0.3.1, handler: Redis::EM::Mutex::ScriptHandlerMixin
lock/unlock 1000 times with concurrency: 10
                    user     system      total        real
keys: 1/ 1      0.270000   0.060000   0.330000 (  0.530289)
keys: 2/ 3      0.360000   0.070000   0.430000 (  0.664696)
keys: 3/ 5      0.430000   0.070000   0.500000 (  0.803888)
keys: 5/ 9      0.450000   0.160000   0.610000 (  1.040182)
keys:10/19      0.710000   0.130000   0.840000 (  1.767735)
```

Test 2
======

run 100 fibers which will repeat the following actions:

- sleep some predefined time
- lock
- write some value to redis key
- increase value in redis key
- read value from that key
- delete that key
- unlock

Wait 5 seconds and then tell all the fibers to quit.
The wall time also includes the "cooling time" which lasted
after 5 seconds has elapsed to the moment where all the fibers
have ceased processing.
The resulting value is how many times the above actions were repeated
during that period.

```
Version: 0.1.2, handler: N/A
lock/write/incr/read/del/unlock in 5 seconds + cooldown period:
                      user     system      total        real
keys: 1/ 1  3134  2.120000   1.260000   3.380000 (  5.123046)
keys: 2/ 3  2678  2.350000   1.050000   3.400000 (  5.134010)
keys: 3/ 5  2566  2.410000   1.300000   3.710000 (  5.157308)
keys: 5/ 9  2256  3.260000   1.200000   4.460000 (  5.209614)
keys:10/19  1693  3.250000   1.050000   4.300000 (  5.230359)

Version: 0.2.3, handler: N/A
lock/write/incr/read/del/unlock in 5 seconds + cooldown period:
                      user     system      total        real
keys: 1/ 1  3199  1.870000   1.120000   2.990000 (  5.114284)
keys: 2/ 3  2271  2.680000   1.130000   3.810000 (  5.221153)
keys: 3/ 5  1627  2.980000   1.120000   4.100000 (  5.289593)
keys: 5/ 9  1094  2.980000   1.260000   4.240000 (  5.401877)
keys:10/19   630  3.420000   1.140000   4.560000 (  5.862919)

Version: 0.3.1, handler: Redis::EM::Mutex::PureHandlerMixin
lock/write/incr/read/del/unlock in 5 seconds + cooldown period:
                      user     system      total        real
keys: 1/ 1  3086  2.450000   1.190000   3.640000 (  5.128574)
keys: 2/ 3  2556  2.540000   1.100000   3.640000 (  5.148499)
keys: 3/ 5  2423  2.490000   1.150000   3.640000 (  5.175866)
keys: 5/ 9  1997  2.980000   1.110000   4.090000 (  5.218399)
keys:10/19  1715  3.180000   1.130000   4.310000 (  5.232533)

Version: 0.3.1, handler: Redis::EM::Mutex::ScriptHandlerMixin
lock/write/incr/read/del/unlock in 5 seconds + cooldown period:
                      user     system      total        real
keys: 1/ 1  4679  2.380000   0.850000   3.230000 (  5.073898)
keys: 2/ 3  4410  2.250000   0.930000   3.180000 (  5.101776)
keys: 3/ 5  3428  1.950000   0.730000   2.680000 (  5.111283)
keys: 5/ 9  3279  2.050000   0.660000   2.710000 (  5.203372)
keys:10/19  2285  1.690000   0.400000   2.090000 (  5.163491)
```

Stress test
===========

You may also want to try this tool: `test/stress.rb`.

Written originally by [mlanett](https://github.com/mlanett/redis-lock/blob/master/test/stress.rb).

```
Usage: test/stress.rb --forks F --tries T --sleep S
    -f, --forks FORKS                How many processes to fork
    -t, --tries TRIES                How many attempts each process should try
    -s, --sleep SLEEP                How long processes should sleep/work
    -k, --keys KEYS                  How many keys a process should run through
    -h, --help                       Display this usage summary
```
