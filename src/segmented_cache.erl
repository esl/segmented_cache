-module(segmented_cache).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

?MODULEDOC("""
`segmented_cache` is a key/value pairs cache library implemented in rotating segments.

For more information, see the README, and the function documentation.
""").

%% API
-export([start/1, start/2]).
-export([start_link/1, start_link/2]).
-export([is_member/2, get_entry/2, put_entry/3, merge_entry/3, delete_entry/2, delete_pattern/2]).

?DOC("Telemetry metadata with cache hit information.").
-type hit() :: #{name => name(), hit => boolean()}.

?DOC("Telemetry metadata with deletion error information.").
-type delete_error(Key) :: #{
    name => atom(),
    value => Key,
    delete_type => entry | pattern,
    class => throw | error | exit,
    reason => dynamic()
}.

?DOC("`m:pg` scope for cache coordination across distribution.").
-type scope() :: atom().
?DOC("Cache unique name.").
-type name() :: atom().
?DOC("Strategy for cache eviction.").
-type strategy() :: fifo | lru.
?DOC("Dynamic type of _keys_ from cache clients.").
-type key() :: dynamic().
?DOC("Dynamic type of _values_ from cache clients.").
-type value() :: dynamic().
?DOC("Maximum number of entries per segment. When filled, rotation is ensued.").
-type entries_limit() :: infinity | non_neg_integer().
?DOC("Merging function to use for resolving conflicts").
-type merger_fun(Value) :: fun((Value, Value) -> Value).
?DOC("Configuration values for the cache.").
-type opts() :: #{
    scope => scope(),
    strategy => strategy(),
    entries_limit => entries_limit(),
    segment_num => non_neg_integer(),
    ttl => timeout() | {erlang:time_unit(), non_neg_integer()},
    merger_fun => merger_fun(dynamic())
}.

-export_type([
    scope/0,
    name/0,
    key/0,
    value/0,
    hit/0,
    delete_error/1,
    entries_limit/0,
    strategy/0,
    merger_fun/1,
    opts/0
]).

%%====================================================================
%% API
%%====================================================================

?DOC("See `start_link/2` for more details").
-spec start(name()) -> gen_server:start_ret().
start(Name) when is_atom(Name) ->
    start(Name, #{}).

?DOC("See `start_link/2` for more details").
-spec start(name(), opts()) -> gen_server:start_ret().
start(Name, Opts) when is_atom(Name), is_map(Opts) ->
    segmented_cache_server:start(Name, Opts).

?DOC("See `start_link/2` for more details").
-spec start_link(name()) -> gen_server:start_ret().
start_link(Name) when is_atom(Name) ->
    start_link(Name, #{}).

?DOC("""
Start and link a cache entity in the local node.

`Name` must be an atom. Then the cache will be identified by the pair `{segmented_cache, Name}`,
and an entry in persistent_term will be created and the worker will join a pg group of
the same name.
`Opts` is a map containing the configuration.
- `scope` is a `pg` scope. Defaults to `pg`.
- `strategy` can be fifo or lru. Default is `fifo`.
- `segment_num` is the number of segments for the cache. Default is `3`
- `ttl` is the live, in minutes, of _each_ segment. Default is `480`, i.e., 8 hours.
- `merger_fun` is a function that, given a conflict,
    takes in order the old and new values and applies a merging strategy.
    See the `t:merger_fun/1` type.
""").
-spec start_link(name(), opts()) -> gen_server:start_ret().
start_link(Name, Opts) when is_atom(Name), is_map(Opts) ->
    segmented_cache_server:start_link(Name, Opts).

?DOC("""
Check if Key is cached.

Raises a telemetry span:
- name: `[segmented_cache, Name, request, _]`
- start metadata: `#{name => atom()}`
- stop metadata: `t:hit/0`
""").
-spec is_member(name(), key()) -> boolean().
is_member(Name, Key) when is_atom(Name) ->
    Span = segmented_cache_helpers:is_member_span(Name, Key),
    telemetry:span([segmented_cache, Name, request], #{name => Name, type => is_member}, Span).

?DOC("""
Get the entry for Key in cache.

Raises telemetry span:
- name: `[segmented_cache, Name, request, _]`
- start metadata: `#{name => atom()}`
- stop metadata: `t:hit/0`
""").
-spec get_entry(name(), key()) -> value() | not_found.
get_entry(Name, Key) when is_atom(Name) ->
    Span = segmented_cache_helpers:get_entry_span(Name, Key),
    telemetry:span([segmented_cache, Name, request], #{name => Name, type => get_entry}, Span).

?DOC("""
Add an entry to the first table in the segments.

### Possible race conditions:
- Two writers: another process might attempt to put a record at the same time. It this case,
     both writers will attempt `ets:insert_new`, resulting in only one of them succeeding.
     The one that fails, will retry three times a `compare_and_swap`, attempting to merge the
     values and ensuring no data is lost.
- One worker and the cleaner: there's a chance that by the time we insert in the ets table,
     this table is not the first anymore because the cleaner has taken action and pushed it
     behind.
- Two writers and the cleaner: a mix of the previous, it can happen that two writers can
     attempt to put a record at the same time, but exactly in-between, the cleaner rotates the
     tables, resulting in the first writter inserting in the table that immediately becomes the
     second, and the latter writter inserting in the recently treated as first, shadowing the
     previous.

To treat the data race with the cleaner, after a successful insert,
we re-check the index, and if it has changed, we restart the whole operation again:
we can be sure that no more rotations will be triggered in a while,
so the second round will be final.

### Strategy considerations:
Under a fifo strategy, no other writes can happen, but under a lru strategy,
many other workers might attemp to move a record forward. In this case,
the forwarding movement doesn't modify the record, and therefore the `compare_and_swap`
operation should succeed at once; then, once the record is in the front,
all other workers shouldn't be attempting to move it.
""").
-spec put_entry(name(), key(), value()) -> boolean().
put_entry(Name, Key, Value) when is_atom(Name) ->
    segmented_cache_helpers:put_entry_front(Name, Key, Value).

?DOC("""
Merge a new entry into an existing one, or add it at the front if none is found.

Race conditions considerations:
- Two writers: `compare_and_swap` will ensure they both succeed sequentially
- Any writers and the cleaner: under fifo, the writer modifies the record in place
     and doesn't need to be concerned with rotation. Under lru, the same considerations
     than for a `put_entry_front` apply.
""").
-spec merge_entry(name(), key(), value()) -> boolean().
merge_entry(Name, Key, Value) when is_atom(Name) ->
    segmented_cache_helpers:merge_entry(Name, Key, Value).

?DOC("""
Delete an entry in all ets segments.

Might raise a telemetry error if the request fails:
- name: `[segmented_cache, Name, delete_error]`
- measurements: `#{}`
- metadata: `t:delete_error/1`
""").
-spec delete_entry(name(), key()) -> true.
delete_entry(Name, Key) when is_atom(Name) ->
    segmented_cache_server:request_delete_entry(Name, Key),
    segmented_cache_helpers:delete_entry(Name, Key).

?DOC("""
Delete a pattern in all ets segments.

Might raise a telemetry error if the request fails:
- name: `[segmented_cache, Name, delete_error]`
- measurements: `#{}`
- metadata: `t:delete_error/1`
""").
-spec delete_pattern(name(), ets:match_pattern()) -> true.
delete_pattern(Name, Pattern) when is_atom(Name) ->
    segmented_cache_server:request_delete_pattern(Name, Pattern),
    segmented_cache_helpers:delete_pattern(Name, Pattern).
