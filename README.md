# `segmented_cache`

[![Actions Status](https://github.com/esl/segmented_cache/actions/workflows/ci.yml/badge.svg)](https://github.com/esl/segmented_cache/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/esl/segmented_cache/branch/main/graph/badge.svg)](https://codecov.io/gh/esl/segmented_cache)
[![Hex](http://img.shields.io/hexpm/v/segmented_cache.svg)](https://hex.pm/packages/segmented_cache)

`segmented_cache` is a key-value cache library implemented in rotating segments.

## How does it work
It uses a coarse-grained strategy, that is, it keeps a set of ETS tables that are periodically rotated, and on rotation, the last table is cleared. It supports diverse eviction strategies, it takes advantage of modern OTP functionality like [`persistent_term`](https://erlang.org/doc/man/persistent_term.html) or [`atomics`](https://erlang.org/doc/man/atomics.html), and it is instrumented with [`telemetry`](https://hexdocs.pm/telemetry/readme.html).

The cache spawns a process cleaner responsible for periodically cleaning and rotating the tables. It also automatically creates a pg group to sync caches in a cluster. Note that this process will be the owner of the ets tables, so proper care of its supervision must be ensued.

## Why another caching library
Like many things in computing, it depends on the use-case:

### Time-to-live
Very often, the `ttl` of an entry isn't required to be strictly enforced, and it can instead be allocated in "buckets", where the actual `ttl` is allowed to be anything between pre-configured buckets. This simplifies book-keeping, as only the life of the buckets needs to be tracked, instead of a fine-grained per-entry book-keeping.

### Extensible values
Entries can have any type of values, but upon inserts of the same key, a strategy is often needed to decide the final value: whether we want to always keep the latest, always keep the first, or merge them in some way, a custom-tailored callback can be given to decide. A common pattern can be, for example, to keep maps with metadata, and to use `fun maps:merge/2` as the callback for conflict resolution.

### *Concurrency*
This implementation is specially tailored for massively concurrent cache lookups and inserts: many caches in Erlang read from an ets table with `read_concurrency` but serialise inserts through a `gen_server`, which, in high insert bursts, becomes a bottleneck, not considering duplicates inserts that infinitely many workers might request. Other caches serialise read and writes through a `gen_server` that keeps the data in a `map` in its state: this is not only a bottleneck but a source of garbage, as the map is copied on every mutation.

Here instead, the cache uses a –bunch of– ets table with `read_concurrency`, `write_concurrency`, and `decentralized_counters`, to maximise concurrent throughput of all read and writes. It also stores references to the buckets, the index, and the merge strategy, using `persistent_term`, to maximise performance.

### Garbage collection and shared memory
All operations hove been carefully written following the latest OTP [efficiency guide](https://erlang.org/doc/efficiency_guide/users_guide.html), including maps operations that improve sharing, avoiding unnecessary copying from ETS tables, inline list functions, use `atomics` and `persistent_term` as in [this guide](https://blog.erlang.org/persistent_term/).

### Instrumentation
These days, all modern services must be instrumented. This cache library helps follow the RED method –Rate, Errors, Duration–: that is, lookup operations raise telemetry events with name `[segmented_cache, Name, request]` with information whether there was a hit or not (`hit := boolean()`), and the time the lookup took, in microseconds (`time := integer()`). With this, we can aggregate the total Rate, and extract the proportion of cache misses, or Errors, while knowing the Duration of the lookups. See the documentation for details.

## Configuration

* `strategy` can be fifo or lru. Default is `fifo`.
* `segment_num` is the number of segments for the cache. Default is `3`
* `ttl` is the live, in minutes, of _each_ segment. Default is `480`, i.e., 8 hours. Can also be a tuple of `{erlang:time_unit(), non_neg_integer()}`
* `merger_fun` is a callback to resolve conflicts, that takes two conflicting values and returns the final value to be stored. This function takes, in order, the value already present in the table, and the one that is being now inserted. For example, if maps are being used as values, `merger_fun` can be [`fun maps:merge/2`](https://erlang.org/doc/man/maps.html#merge-2).
