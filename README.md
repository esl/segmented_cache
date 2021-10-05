# `segmented_cache`

`segmented_cache` is a key/value pairs cache library implemented in rotating segments.

It uses a coarse-grained strategy, that is, it keeps a set of ETS tables that are periodically rotated, and on rotation, the last table is cleared. It supports diverse eviction strategies, it takes advantage of modern OTP functionallity like persistent_term or atomics, and it is instrumented with telemetry.

The cache spawns a process cleaner responsible for periodically cleaning and rotating the tables. It also automatically creates a pg group to sync caches in a cluster.

# Configuration

* `strategy` can be fifo or lru. Default is `fifo`.
* `segment_num` is the number of segments for the cache. Default is `3`
* `ttl` is the live, in minutes, of _each_ segment. Default is `480`, i.e., 8 hours.
