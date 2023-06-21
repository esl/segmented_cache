Here are the key points of the design:

## Cache state
- The cache records are stored in multiple ETS tables called _segments_, stored in a tuple to improve access times.
- There's one _current_ table pointed at by an index, stored in an [`atomic`](https://erlang.org/doc/man/atomics.html).
- The `persistent_term` module is used to store the cache state, which contains the tuple of segments and the atomic reference. It's initialised just once, and it never changes after that.
- The atomic value is changing, but most importantly: changing in a lock-free manner.
- Writes are always done at the _current_ table.
- Reads iterate through all of them in order, starting from the _current_ one.

## TTL implementation
- Tables are rotated periodically and data from the last table is dropped.
- `ttl` is not 100% accurate, as a record can be inserted during rotation and therefore live one segment less that expected: we can treat the `ttl` as a warranty that a record will live less than `ttl` but at least `ttl - ttl/N` where `N` is the number of segments (ETS tables).
- There's a `gen_server` process responsible for the table rotation (see [Cache state notes](#cache-state-notes) for more details).

## LRU implementation
- On `segmented_cache:is_member/2` and `segmented_cache:get_entry/2` calls, the record is reinserted in the _current_ ETS table.

## Distribution
- In a distributed environment, cache is populated independently on every node.
- However, we must ensure that on deletion the cache record is removed on all the nodes (and from all the ETS tables, see [LRU implementation notes](#lru-implementation-notes))
- There's a `gen_server` process responsible for ETS tables rotation (see [TTL implementation notes](#ttl-implementation-notes))
- The same process is reused to implement asynchronous cache record deletion on other nodes in the cluster.
- In order to simplify discovery of these `gen_server` processes on other nodes, they all are added into a dedicated `pg` group.
