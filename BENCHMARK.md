BENCHMARK
=========

To measure the performance of {Redis::EM::Mutex} I've wrote a simple script called `benchmark_mutex.rb`.
The script is included in respository.

Below are the results of running tests against the following versions:

- redis-em-mutex v0.1.2
- redis-em-mutex v0.2.3
- redis-em-mutex v0.3.0 - "pure" handler
- redis-em-mutex v0.3.0 - "script" handler

To run theese tests type:

```sh
cp benchmark_mutex.rb /tmp/

git reset --hard v0.1.2
ruby /tmp/benchmark_mutex.rb

git reset --hard v0.2.3
ruby /tmp/benchmark_mutex.rb

git reset --hard v0.3.0
REDIS_EM_MUTEX_HANDLER=pure ruby benchmark_mutex.rb
REDIS_EM_MUTEX_HANDLER=script ruby benchmark_mutex.rb
```

Here are the results of running those tests on 4 CPU Xeon machine
with redis-server 2.6.9 and ruby 1.9.3p374 (2013-01-15 revision 38858) [x86_64-linux].

The results may vary.

Test 1
======

Lock/unlock 1000 times using 10 concurrent fibers.

```
Version: 0.1.2, handler: N/A
lock/unlock 1000 times with concurrency: 10
                    user     system      total        real
keys: 1         0.590000   0.220000   0.810000 (  1.124918)
keys: 2         0.640000   0.220000   0.860000 (  1.214577)
keys: 3         0.660000   0.200000   0.860000 (  1.245093)
keys: 5         0.770000   0.140000   0.910000 (  1.322475)
keys:10         0.890000   0.210000   1.100000 (  1.456293)

Version: 0.2.3, handler: N/A
lock/unlock 1000 times with concurrency: 10
                    user     system      total        real
keys: 1         0.640000   0.200000   0.840000 (  1.105686)
keys: 2         1.090000   0.420000   1.510000 (  2.014079)
keys: 3         1.450000   0.500000   1.950000 (  2.738510)
keys: 5         1.940000   0.820000   2.760000 (  4.136856)
keys:10         3.360000   1.900000   5.260000 (  8.232977)

Version: 0.3.0, handler: Redis::EM::Mutex::PureHandlerMixin
lock/unlock 1000 times with concurrency: 10
                    user     system      total        real
keys: 1         0.610000   0.230000   0.840000 (  0.864242)
keys: 2         0.640000   0.220000   0.860000 (  0.914122)
keys: 3         0.660000   0.260000   0.920000 (  0.947300)
keys: 5         0.730000   0.250000   0.980000 (  1.007862)
keys:10         0.840000   0.230000   1.070000 (  1.315885)

Version: 0.3.0, handler: Redis::EM::Mutex::ScriptHandlerMixin
lock/unlock 1000 times with concurrency: 10
                    user     system      total        real
keys: 1         0.290000   0.110000   0.400000 (  0.633668)
keys: 2         0.280000   0.150000   0.430000 (  0.714378)
keys: 3         0.290000   0.100000   0.390000 (  0.657861)
keys: 5         0.430000   0.100000   0.530000 (  0.775208)
keys:10         0.330000   0.150000   0.480000 (  0.904942)
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
        result      user     system      total        real
keys: 1   3256  2.290000   1.230000   3.520000 (  5.135926)
keys: 2   3179  2.260000   1.000000   3.260000 (  5.124043)
keys: 3   3072  2.160000   1.170000   3.330000 (  5.128032)
keys: 5   2859  2.280000   1.070000   3.350000 (  5.132027)
keys:10   2564  2.460000   0.860000   3.320000 (  5.151968)

Version: 0.2.3, handler: N/A
lock/write/incr/read/del/unlock in 5 seconds + cooldown period:
        result      user     system      total        real
keys: 1   3274  2.480000   1.010000   3.490000 (  5.111753)
keys: 2   2429  2.740000   1.270000   4.010000 (  5.204065)
keys: 3   1855  2.380000   1.210000   3.590000 (  5.256041)
keys: 5   1309  2.890000   1.250000   4.140000 (  5.376043)
keys:10    710  3.120000   1.190000   4.310000 (  5.763981)

Version: 0.3.0, handler: Redis::EM::Mutex::PureHandlerMixin
lock/write/incr/read/del/unlock in 5 seconds + cooldown period:
        result  user     system      total        real
keys: 1   3795  2.490000   1.400000   3.890000 (  5.108474)
keys: 2   3788  2.600000   1.400000   4.000000 (  5.108037)
keys: 3   3921  2.800000   1.170000   3.970000 (  5.120059)
keys: 5   3641  2.820000   1.140000   3.960000 (  5.112036)
keys:10   2661  2.860000   1.130000   3.990000 (  5.152105)

Version: 0.3.0, handler: Redis::EM::Mutex::ScriptHandlerMixin
lock/write/incr/read/del/unlock in 5 seconds + cooldown period:
        result   user     system      total        real
keys: 1   5177  1.980000   1.020000   3.000000 (  5.079791)
keys: 2   5460  1.600000   1.030000   2.630000 (  5.080049)
keys: 3   5322  1.560000   1.000000   2.560000 (  5.088010)
keys: 5   4685  1.620000   0.810000   2.430000 (  5.084035)
keys:10   4347  1.600000   0.770000   2.370000 (  5.111976)
```
