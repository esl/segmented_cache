%% @private
-module(segmented_cache_helpers).

-define(APP_KEY, segmented_cache).

-export([init_cache_config/2, get_cache_scope/1, erase_cache_config/1]).
-export([is_member_span/2, get_entry_span/2, put_entry_front/3, merge_entry/3]).
-export([delete_entry/2, delete_pattern/2]).
-export([purge_last_segment_and_rotate/1]).

-record(segmented_cache, {scope :: segmented_cache:scope(),
                          strategy = fifo :: segmented_cache:strategy(),
                          index :: atomics:atomics_ref(),
                          segments :: tuple(),
                          merger_fun :: merger_fun(term())}).

-type span() :: fun(() -> {term(), span_metadata()}).
-type span_metadata() :: #{hit := boolean()}.
-type merger_fun(Value) :: fun((Value, Value) -> Value).
-type iterative_fun(Key, Value) :: fun((ets:tid(), Key) -> {continue | stop, Value}).
-type config() :: #segmented_cache{}.

%%====================================================================
%% Cache config
%%====================================================================

-spec init_cache_config(segmented_cache:name(), segmented_cache:opts()) ->
    #{scope := segmented_cache:scope(), ttl := timeout()}.
init_cache_config(Name, Opts) ->
    {Scope, N, TTL, Strategy, MergerFun} = assert_parameters(Opts),
    SegmentOpts = ets_settings(),
    SegmentsList = lists:map(fun(_) -> ets:new(undefined, SegmentOpts) end, lists:seq(1, N)),
    Segments = list_to_tuple(SegmentsList),
    Index = atomics:new(1, [{signed, false}]),
    atomics:put(Index, 1, 1),
    Config = #segmented_cache{scope = Scope, strategy = Strategy, index = Index,
                             segments = Segments, merger_fun = MergerFun},
    set_cache_config(Name, Config),
    #{scope => Scope, ttl => TTL}.

-spec get_cache_scope(segmented_cache:name()) -> segmented_cache:scope().
get_cache_scope(Name) ->
    #segmented_cache{scope = Scope} = persistent_term:get({?APP_KEY, Name}),
    Scope.

-spec erase_cache_config(segmented_cache:name()) -> boolean().
erase_cache_config(Name) ->
    persistent_term:erase({?APP_KEY, Name}).

-spec get_cache_config(segmented_cache:name()) -> config().
get_cache_config(Name) ->
    persistent_term:get({?APP_KEY, Name}).

-spec set_cache_config(segmented_cache:name(), config()) -> ok.
set_cache_config(Name, Config) ->
    persistent_term:put({?APP_KEY, Name}, Config).

%%====================================================================
%% ETS checks
%%====================================================================

-spec is_member_span(segmented_cache:name(), segmented_cache:key()) -> span().
is_member_span(Name, Key) when is_atom(Name) ->
    fun() ->
            Value = iterate_fun_in_tables(Name, Key, fun segmented_cache_callbacks:is_member_ets_fun/2),
            {Value, #{hit => Value =:= true}}
    end.

-spec get_entry_span(segmented_cache:name(), segmented_cache:key()) -> span().
get_entry_span(Name, Key) when is_atom(Name) ->
    fun() ->
            Value = iterate_fun_in_tables(Name, Key, fun segmented_cache_callbacks:get_entry_ets_fun/2),
            {Value, #{hit => Value =/= not_found}}
    end.

%% @doc Atomically compare_and_swap an entry, attempt three times, post-check front insert
-spec put_entry_front(segmented_cache:name(), segmented_cache:key(), segmented_cache:value()) -> boolean().
put_entry_front(Name, Key, Value) ->
    SegmentRecord = get_cache_config(Name),
    do_put_entry_front(SegmentRecord, Key, Value).

-spec merge_entry(segmented_cache:name(), segmented_cache:key(), segmented_cache:value()) -> boolean().
merge_entry(Name, Key, Value) when is_atom(Name) ->
    SegmentRecord = get_cache_config(Name),
    F = fun(EtsSegment, KKey) ->
                MergerFun = SegmentRecord#segmented_cache.merger_fun,
                case compare_and_swap(3, EtsSegment, KKey, Value, MergerFun) of
                    true -> {stop, true};
                    false -> {continue, false}
                end
        end,
    case iterate_fun_in_tables(Name, Key, F) of
        true -> true;
        false -> do_put_entry_front(SegmentRecord, Key, Value)
    end.

-spec delete_entry(segmented_cache:name(), segmented_cache:key()) -> true.
delete_entry(Name, Key) when is_atom(Name) ->
    delete_request(Name, Key, entry, fun segmented_cache_callbacks:delete_entry_fun/2).

-spec delete_pattern(segmented_cache:name(), ets:match_pattern()) -> true.
delete_pattern(Name, Pattern) when is_atom(Name) ->
    delete_request(Name, Pattern, pattern, fun segmented_cache_callbacks:delete_pattern_fun/2).

-spec delete_request(segmented_cache:name(), Key, entry | pattern, iterative_fun(Key, term())) ->
    term() when Key :: segmented_cache:key().
delete_request(Name, Value, Type, Fun) ->
    try
        iterate_fun_in_tables(Name, Value, Fun)
    catch Class:Reason ->
              Metadata = #{name => Name, delete_type => Type, value => Value, class => Class, reason => Reason},
              telemetry:execute([segmented_cache, Name, delete_error], #{}, Metadata)
    end.

%%====================================================================
%% Internals
%%====================================================================

-spec iterate_fun_in_tables(segmented_cache:name(), Key, IterativeFun) -> Value when
      IterativeFun :: iterative_fun(Key, Value).
iterate_fun_in_tables(Name, Key, IterativeFun) ->
    SegmentRecord = get_cache_config(Name),
    Segments = SegmentRecord#segmented_cache.segments,
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
            Strategy = SegmentRecord#segmented_cache.strategy,
            apply_strategy(Strategy, CurrentIndex, FoundIndex, Key, SegmentRecord),
            Value
    end.

-spec iterate_fun_in_tables(IterativeFun, Key, tuple(), Int, Int, Int) ->
    {not_found, Value} | {non_neg_integer(), Value}
      when Int :: non_neg_integer(), IterativeFun :: iterative_fun(Key, Value).
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

%% @doc Apply configured eviction strategy
%% Basically only lru when the record wasn't at the front needs action.
%% For that, we first extract the whole record, then we attempt to put it at the front
%% table atomically, and only then, delete the record found at the back: otherwise if
%% we first remove the record at the back, other readers, upon not finding it, can
%% attempt to reinsert it.
%% Concurrency considerations:
%%  * Two workers moving the record front: they would both be moving the same record, so the
%%      insert operation should have an idempotent merge and the insert would succeed easily.
%%  * One worker moving the record front, another worker putting the same record front: same
%%      consideration, the merge strategy will make one succeed after the other.
%%  * Two workers moving front and the cleaner: the cleaner can rotate the tables just so that
%%      the workers would move the record to two different tables. In that case, they would be
%%      moving the same original record, hence we would be just duplicating memory, but no
%%      inconsistencies would be introduced nor data would be lost.
%%  * One worker pushes, one inserts new, and the cleaner: with the cleaner rotating the tables
%%      in between, the two workers would be operating on different tables and therefore the record
%%      that gets inserted on the second table would be shadowed and lost.
apply_strategy(fifo, _CurrentIndex, _FoundIndex, _Key, _SegmentRecord) ->
    false;
apply_strategy(lru, CurrentIndex, CurrentIndex, _Key, _SegmentRecord) ->
    false;
apply_strategy(lru, _CurrentIndex, FoundIndex, Key, SegmentRecord) ->
    Segments = SegmentRecord#segmented_cache.segments,
    FoundInSegment = element(FoundIndex, Segments),
    try [{_, Value}] = ets:lookup(FoundInSegment, Key),
        do_put_entry_front(SegmentRecord, Key, Value)
    catch _:_ -> false
    end.

-spec do_put_entry_front(#segmented_cache{}, segmented_cache:key(), segmented_cache:value()) ->
    boolean().
do_put_entry_front(SegmentRecord, Key, Value) ->
    Atomic = SegmentRecord#segmented_cache.index,
    Index = atomics:get(Atomic, 1),
    Segments = SegmentRecord#segmented_cache.segments,
    FrontSegment = element(Index, Segments),
    Inserted = case ets:insert_new(FrontSegment, {Key, Value}) of
                   true -> true;
                   false ->
                       MergerFun = SegmentRecord#segmented_cache.merger_fun,
                       compare_and_swap(3, FrontSegment, Key, Value, MergerFun)
               end,
    MaybeMovedIndex = atomics:get(Atomic, 1),
    case post_insert_check_should_retry(Inserted, Index, MaybeMovedIndex) of
        false -> Inserted;
        true -> do_put_entry_front(SegmentRecord, Key, Value)
    end.

-spec post_insert_check_should_retry(boolean(), integer(), integer()) -> boolean().
% Table index didn't move, insert is still in the front
post_insert_check_should_retry(true, Index, Index) -> false;
% Insert succeded but the table is not the first anymore, retry,
% rotation will not happen again in a long while
post_insert_check_should_retry(true, _, _) -> true;
% Insert failed, so it doesn't matter, just abort
post_insert_check_should_retry(false, _, _) -> false.

-spec compare_and_swap(non_neg_integer(), ets:tid(), segmented_cache:key(), Value, merger_fun(Value)) ->
    boolean().
compare_and_swap(0, _EtsSegment, _Key, _Value, _MergerFun) ->
    false;
compare_and_swap(Attempts, EtsSegment, Key, Value, MergerFun) ->
    case ets:lookup(EtsSegment, Key) of
        [{_, OldValue}] ->
            NewValue = MergerFun(OldValue, Value),
            case ets:select_replace(EtsSegment, [{{Key, OldValue}, [], [{const, {Key, NewValue}}]}]) of
                1 -> true;
                0 -> compare_and_swap(Attempts - 1, EtsSegment, Key, Value, MergerFun)
            end;
        [] -> false
    end.

%% @doc Rotate the tables
%% Note that we must first empty the last table, and then rotate the index. If it was done
%% in the opposite order, there's a chance a worker can insert an entry at the front just
%% before the table is purged.
purge_last_segment_and_rotate(Name) ->
    SegmentRecord = get_cache_config(Name),
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
    atomics:put(SegmentRecord#segmented_cache.index, 1, NewIndex),
    NewIndex.

-spec assert_parameters(segmented_cache:opts()) ->
    {segmented_cache:name(), pos_integer(), timeout(), segmented_cache:strategy(), merger_fun(term())}.
assert_parameters(Opts) when is_map(Opts) ->
    N = maps:get(segment_num, Opts, 3),
    true = is_integer(N) andalso N > 0,
    TTL0 = maps:get(ttl, Opts, {hours, 8}),
    TTL = case TTL0 of
               infinity -> infinity;
               {milliseconds, S} -> S;
               {seconds, S} -> timer:seconds(S);
               {minutes, M} -> timer:minutes(M);
               {hours, H} -> timer:hours(H);
               T when is_integer(T) -> timer:minutes(T)
           end,
    true = (TTL =:= infinity) orelse (is_integer(TTL) andalso N > 0),
    Strategy = maps:get(strategy, Opts, fifo),
    true = (Strategy =:= fifo) orelse (Strategy =:= lru),
    MergerFun = maps:get(merger_fun, Opts, fun segmented_cache_callbacks:default_merger_fun/2),
    true = is_function(MergerFun, 2),
    Scope = maps:get(scope, Opts, pg),
    true = (undefined =/= whereis(Scope)),
    {Scope, N, TTL, Strategy, MergerFun}.

-ifdef(OTP_RELEASE).
  -if(?OTP_RELEASE >= 25).
    ets_settings() ->
        [set, public,
         {read_concurrency, true},
         {write_concurrency, auto},
         {decentralized_counters, true}].
  -elif(?OTP_RELEASE >= 21).
    ets_settings() ->
        [set, public,
         {read_concurrency, true},
         {write_concurrency, true},
         {decentralized_counters, true}].
  -endif.
-else.
ets_settings() ->
    [set, public,
     {read_concurrency, true},
     {write_concurrency, true},
     {decentralized_counters, true}].
-endif.
