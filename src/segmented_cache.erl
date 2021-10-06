%%%-------------------------------------------------------------------
%% @doc `segmented_cache' is a key/value pairs cache library implemented in rotating segments.
%%
%% It uses a coarse-grained strategy, that is, it keeps a set of ETS tables that
%% are periodically rotated, and on rotation, the last table is cleared. It supports
%% diverse eviction strategies, it takes advantage of modern OTP functionallity like
%% persistent_term or atomics, and it is instrumented with telemetry.
%%
%% The cache spawns a process cleaner responsible for periodically cleaning and rotating
%% the tables. It also automatically creates a pg group to sync caches in a cluster.
%% @end
%%%-------------------------------------------------------------------
-module(segmented_cache).

-include_lib("stdlib/include/ms_transform.hrl").

%% API
-export([is_member/2]).
-export([get_entry/2]).
-export([put_entry/3]).
-export([delete_entry/2]).
-export([delete_pattern/2]).

%% gen_server callbacks
-export([start_link/2]).
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

%% Callbacks only!
-export([is_member_fun/2]).
-export([get_entry_fun/2]).
-export([delete_entry_fun/2]).
-export([delete_pattern_fun/2]).
-export([default_merger_fun/2]).

-type name() :: atom().
-type strategy() :: fifo | lru.
-type merger_fun(Term) :: fun((Term, Term) -> Term).
-type iterative_fun(Term) :: fun((ets:tid(), Term) -> {continue | stop, not_found | term()}).
-type opts() :: #{strategy => strategy(),
                  segment_num => non_neg_integer(),
                  ttl => timeout(),
                  merger_fun => merger_fun(term())}.

-record(segmented_cache, {strategy = fifo :: strategy(),
                          index :: atomics:atomics_ref(),
                          segments :: tuple(),
                          merger_fun :: merger_fun(term())}).

-record(cache_state, {name :: name(),
                      ttl :: timeout(),
                      timer_ref :: undefined | reference()}).

%%====================================================================
%% API
%%====================================================================
%% @doc Check if Key is cached
%% Raises telemetry event
%%      name: [?MODULE, request]
%%      measurements: #{hit => boolean()}
-spec is_member(name(), term()) -> boolean().
is_member(Name, Key) when is_atom(Name) ->
    Value = iterate_fun_in_tables(Name, Key, fun ?MODULE:is_member_fun/2),
    telemetry:execute([?MODULE, request], #{hit => Value =:= true}),
    Value.

%% @doc Get the entry for Key in cached
%% Raises telemetry event
%%      name: [?MODULE, request]
%%      measurements: #{hit => boolean()}
-spec get_entry(name(), term()) -> term() | not_found.
get_entry(Name, Key) when is_atom(Name) ->
    Value = iterate_fun_in_tables(Name, Key, fun ?MODULE:get_entry_fun/2),
    telemetry:execute([?MODULE, request], #{hit => Value =/= not_found}),
    Value.

%% @doc Add an entry to the first table in the segments.
%% Possible race conditions:
%%  * With the cleaner process: there's a chance that by the time we insert in the ets table,
%%      this table is not the first anymore because the cleaner has taken action and pushed it
%%      behind. That's acceptable, worst case this record will live a segment less than expected.
%%  * With other writters: another process might attempt to put a record at the same time. It this
%%      case, both writers will attempt `ets:insert_new', resulting in only one of them succeeding.
%%      The one that fails, will retry three times a `compare_and_swap', attempting to merge the
%%      values and ensuring no data is lost.
%%  * Two writters and the cleaner: a mix of the previous, it can happen that two writers can
%%      attempt to put a record at the same time, but exactly in-between, the cleaner rotates the
%%      tables, resulting in the first writter inserting in the table that immediately becomes the
%%      second, and the latter writter inserting in the recently treated as first. This might result
%%      in data loss, when the record of the first writter will be not merged and loss behind. This
%%      edge-case is (hopefully) statistically speaking unlikely enough to be considered acceptable,
%%      as soon enough a third writter will just retry with the metadata that wanted to be added.
%% Strategy considerations: under a fifo strategy, no other writes can happen, but under a lru
%%      strategy, many other workers might attemp to move a record forward. In this case, the
%%      forwarding movement does't modify the record, and therefore the `compare_and_swap'
%%      operation should succeed at once; then, once the record is in the front, all other workers
%%      shouldn't be attempting to move it.
-spec put_entry(name(), term(), term()) -> boolean().
put_entry(Name, Key, Value) when is_atom(Name) ->
    SegmentRecord = persistent_term:get({?MODULE, Name}),
    MergerFun = SegmentRecord#segmented_cache.merger_fun,
    Segments = SegmentRecord#segmented_cache.segments,
    Index = atomics:get(SegmentRecord#segmented_cache.index, 1),
    FrontSegment = element(Index, Segments),
    put_entry_front(FrontSegment, {Key, Value}, MergerFun).

-spec delete_entry(name(), term()) -> true.
delete_entry(Name, Key) when is_atom(Name) ->
    send_to_group(Name, {delete_entry, Key}),
    iterate_fun_in_tables(Name, Key, fun ?MODULE:delete_entry_fun/2).

-spec delete_pattern(name(), term()) -> true.
delete_pattern(Name, Pattern) when is_atom(Name) ->
    send_to_group(Name, {delete_pattern, Pattern}),
    iterate_fun_in_tables(Name, Pattern, fun ?MODULE:delete_pattern_fun/2).

%%====================================================================
%% Server
%%====================================================================

%% @doc Start a cache entity in the local node
%% `Name' must be an atom. Then the cache will be identified by the pair `{?MODULE, Name}',
%% and an entry in persistent_term will be created and the worker will join a pg group of
%% the same name.
%% `Opts' is a map containing the configuration.
%%      `strategy' can be fifo or lru. Default is `fifo'.
%%      `segment_num' is the number of segments for the cache. Default is `3'
%%      `ttl' is the live, in minutes, of _each_ segment. Default is `480', i.e., 8 hours.
%%      `merger_fun' is a function that, given a conflict, takes in order the old and new values and
%%          applies a merging strategy. See the `merger_fun/1' type
-spec start_link(name(), opts()) -> {ok, pid()}.
start_link(Name, Opts) when is_atom(Name), is_map(Opts) ->
    gen_server:start_link(?MODULE, [Name, Opts], []).

%% @private
-spec init([any()]) -> {ok, #cache_state{}}.
init([Name, Opts]) ->
    {N, TTL, Strategy, MergerFun} = assert_parameters(Opts),
    SegmentOpts = ets_settings(),
    SegmentsList = lists:map(fun(_) -> ets:new(undefined, SegmentOpts) end, lists:seq(1, N)),
    Segments = list_to_tuple(SegmentsList),
    Index = atomics:new(1, [{signed, false}]),
    atomics:put(Index, 1, 1),
    Entry = #segmented_cache{strategy = Strategy, index = Index,
                             segments = Segments, merger_fun = MergerFun},
    persistent_term:put({?MODULE, Name}, Entry),
    pg:join(Name, self()),
    case TTL of
        infinity ->
            {ok, #cache_state{name = Name, ttl = infinity, timer_ref = undefined}};
        _ ->
            TimerRef = erlang:send_after(TTL, self(), purge),
            {ok, #cache_state{name = Name, ttl = TTL, timer_ref = TimerRef}}
    end.

assert_parameters(Opts) when is_map(Opts) ->
    N = maps:get(segment_num, Opts, 3),
    true = is_integer(N) andalso N > 0,
    TTL0 = maps:get(ttl, Opts, {hours, 8}),
    TTL = case TTL0 of
               {seconds, S} -> timer:seconds(S);
               {minutes, M} -> timer:minutes(M);
               {hours, H} -> timer:hours(H);
               T -> T
           end,
    true = (TTL =:= infinity) orelse (is_integer(TTL) andalso N > 0),
    Strategy = maps:get(strategy, Opts, fifo),
    true = (Strategy =:= fifo) orelse (Strategy =:= lru),
    MergerFun = maps:get(merger_fun, Opts, fun ?MODULE:default_merger_fun/2),
    true = is_function(MergerFun, 2),
    {N, TTL, Strategy, MergerFun}.

ets_settings() ->
    [set, public,
     {read_concurrency, true},
     {write_concurrency, true},
     {decentralized_counters, true}].

%% @private
-spec handle_call(any(), pid(), #cache_state{}) -> {reply, ok, #cache_state{}}.
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

%% @private
-spec handle_cast(term(), #cache_state{}) -> {noreply, #cache_state{}}.
handle_cast({delete_entry, Key}, #cache_state{name = Name} = State) ->
    try iterate_fun_in_tables(Name, Key, fun ?MODULE:delete_entry_fun/2)
    catch Class:Reason -> telemetry:execute([?MODULE, error], #{class => Class, reason => Reason})
    end,
    {noreply, State};
handle_cast({delete_pattern, Pattern}, #cache_state{name = Name} = State) ->
    try iterate_fun_in_tables(Name, Pattern, fun ?MODULE:delete_pattern_fun/2)
    catch Class:Reason -> telemetry:execute([?MODULE, error], #{class => Class, reason => Reason})
    end,
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
-spec handle_info(any(), #cache_state{}) -> {noreply, #cache_state{}}.
handle_info(purge, #cache_state{ttl = TTL} = State) ->
    purge_last_segment_and_rotate(State),
    TimerRef = erlang:send_after(TTL, self(), purge),
    {noreply, State#cache_state{timer_ref = TimerRef}};
handle_info(_Msg, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, #cache_state{name = Name, timer_ref = TimerRef}) ->
    erlang:cancel_timer(TimerRef),
    persistent_term:erase({?MODULE, Name}),
    ok.

%%====================================================================
%% Internals
%%====================================================================

%% @private
%% @doc Rotate the tables
%% Note that we must first empty the last table, and then rotate the index. If it was done
%% in the opposite order, there's a chance a worker can insert an entry at the front just
%% before the table is purged.
purge_last_segment_and_rotate(#cache_state{name = Name}) ->
    SegmentRecord = persistent_term:get({?MODULE, Name}),
    Index = atomics:get(SegmentRecord#segmented_cache.index, 1),
    Segments = SegmentRecord#segmented_cache.segments,
    Size = tuple_size(Segments),
    %% If Size was 1, Index would not change
    NewIndex = case Index of
                   1 -> Size;
                   _ -> Index - 1
               end,
    TableToClear = element(NewIndex, Segments),
    ets:delete_all_objects(TableToClear),
    atomics:put(SegmentRecord#segmented_cache.index, 1, NewIndex).

send_to_group(Name, Msg) ->
    Pids = pg:get_members(Name) -- pg:get_local_members(Name),
    [gen_server:cast(Pid, Msg) || Pid <- Pids].

%% @private
%% @doc Apply configured eviction strategy
%% Basically only lru when the record wasn't at the front needs action.
%% For that, we first extract the whole record, then we attempt to put it at the front
%% table atomically, and only then, delete the record found at the back: otherwise if
%% we first remove the record at the back, other readers, upon not finding it, can
%% attempt to reinsert it.
%% Concurrency considerations:
%%  * Two workers moving the record front: they would both be moving the same record, so the
%%      insert operation shuold have an idempotent merge and the insert would succeed easily.
%%  * One worker moving the record front, another worker putting the same record front: same
%%      consideration, the merge strategy will make one succeed after the other.
%%  * Two workers moving front and the cleaner: the cleaner can rotate the tables just so that
%%      the workers would move the record to two different tables. In that case, they would be
%%      moving the same original record, hence we would be just duplicating memory, but no
%%      inconsistencies would be introduced nor data would be lost.
%%  * One worker pushes, one inserts new, and the cleaner: with the cleaner rotating the tables
%%      in between, the two workers would be operating on different tables and therefore the record
%%      that gets inserted on the second table would be shadowed and lost.
apply_strategy(fifo, _CurrentIndex, _FoundIndex, _Segments, _Key, _MergerFun) ->
    ok;
apply_strategy(lru, CurrentIndex, CurrentIndex, _Segments, _Key, _MergerFun) ->
    ok;
apply_strategy(lru, CurrentIndex, FoundIndex, Segments, Key, MergerFun) ->
    FoundInSegment = element(FoundIndex, Segments),
    FrontSegment = element(CurrentIndex, Segments),
    try [Entry] = ets:lookup(FoundInSegment, Key),
        put_entry_front(FrontSegment, Entry, MergerFun),
        ets:delete(FoundInSegment, Key)
    catch _:_ -> false
    end.

-spec iterate_fun_in_tables(name(), T, IterativeFun) -> term() when
      T :: term(), IterativeFun :: iterative_fun(T).
iterate_fun_in_tables(Name, Key, IterativeFun) ->
    SegmentRecord = persistent_term:get({?MODULE, Name}),
    Strategy = SegmentRecord#segmented_cache.strategy,
    Segments = SegmentRecord#segmented_cache.segments,
    MergerFun = SegmentRecord#segmented_cache.merger_fun,
    Size = tuple_size(Segments),
    CurrentIndex = atomics:get(SegmentRecord#segmented_cache.index, 1),
    LastTableToCheck = case CurrentIndex of
                           1 -> Size;
                           _ -> CurrentIndex - 1
                       end,
    case iterate_fun_in_tables(IterativeFun, Key, Segments, Size, LastTableToCheck, CurrentIndex) of
        {not_found, Value} ->
            Value;
        {FoundIndex, Value} ->
            apply_strategy(Strategy, CurrentIndex, FoundIndex, Segments, Key, MergerFun),
            Value
    end.

-spec iterate_fun_in_tables(iterative_fun(Key), Key, tuple(), Int, Int, Int) ->
    {not_found | non_neg_integer(), Value} when
      Key :: term(), Value :: term(), Int :: non_neg_integer().
% if we arrived to the last table we finish here
iterate_fun_in_tables(IterativeFun, Key, Segments, _, LastTableToCheck, LastTableToCheck) ->
    EtsSegment = element(LastTableToCheck, Segments),
    case IterativeFun(EtsSegment, Key) of
        {stop, Value} -> {LastTableToCheck, Value};
        {continue, Value} -> {not_found, Value}
    end;
% if we arrived to the last slot, we check and wrap around
iterate_fun_in_tables(IterativeFun, Key, Segments, Size, LastTableToCheck, Size) ->
    EtsSegment = element(Size, Segments),
    case IterativeFun(EtsSegment, Key) of
        {stop, Value} -> {Size, Value};
        {continue, _} -> iterate_fun_in_tables(IterativeFun, Key, Segments, Size, LastTableToCheck, 1)
    end;
% else we check the current table and if it fails we move forwards
iterate_fun_in_tables(IterativeFun, Key, Segments, Size, LastTableToCheck, Index) ->
    EtsSegment = element(Index, Segments),
    case IterativeFun(EtsSegment, Key) of
        {stop, Value} -> {Index, Value};
        {continue, _} -> iterate_fun_in_tables(IterativeFun, Key, Segments, Size, LastTableToCheck, Index + 1)
    end.

%% @private
-spec is_member_fun(ets:tid(), term()) -> {continue | stop, not_found | boolean()}.
is_member_fun(EtsSegment, Key) ->
    case ets:member(EtsSegment, Key) of
        true -> {stop, true};
        false -> {continue, false}
    end.

%% @private
-spec get_entry_fun(ets:tid(), term()) -> {continue | stop, not_found | term()}.
get_entry_fun(EtsSegment, Key) ->
    case ets:lookup(EtsSegment, Key) of
        [{_, Value}] -> {stop, [Value]};
        [] -> {continue, not_found}
    end.

%% @private
-spec delete_entry_fun(ets:tid(), term()) -> {continue, true}.
delete_entry_fun(EtsSegment, Key) ->
    ets:delete(EtsSegment, Key),
    {continue, true}.

%% @private
-spec delete_pattern_fun(ets:tid(), term()) -> {continue, true}.
delete_pattern_fun(EtsSegment, Pattern) ->
    ets:match_delete(EtsSegment, Pattern),
    {continue, true}.

%% @private
%% @doc This merger simply discards the older value
-spec default_merger_fun(T, T) -> merger_fun(T) when T :: term().
default_merger_fun(_OldValue, NewValue) ->
    NewValue.

%% @private
%% @doc Atomically compare_and_swap an entry, attempt three times
-spec put_entry_front(ets:tid(), {Key, Value}, merger_fun(Value)) -> boolean() when
      Key :: term(), Value :: term().
put_entry_front(FrontSegment, Entry, MergerFun) ->
    case ets:insert_new(FrontSegment, Entry) of
        true -> true;
        false -> compare_and_swap(3, FrontSegment, Entry, MergerFun)
    end.

%% @private
-spec compare_and_swap(pos_integer(), ets:tid(), {Key, Value}, merger_fun(Value)) -> boolean() when
      Key :: term(), Value :: term().
compare_and_swap(0, _EtsSegment, _Entry, _MergerFun) ->
    false;
compare_and_swap(Attempts, EtsSegment, {Key, Value}, MergerFun) ->
    case ets:lookup(EtsSegment, Key) of
        [{_, OldValue}] ->
            NewValue = MergerFun(OldValue, Value),
            case ets:select_replace(EtsSegment, [{{Key, OldValue}, [], [{const, {Key, NewValue}}]}]) of
                1 -> true;
                0 -> compare_and_swap(Attempts - 1, EtsSegment, {Key, Value}, MergerFun)
            end;
        [] -> false
    end.
