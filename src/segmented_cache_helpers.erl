-module(segmented_cache_helpers).
-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-endif.
?MODULEDOC(false).

-define(APP_KEY, segmented_cache).
-compile({inline, [next/2]}).

-export([init_cache_config/2, get_cache_scope/1, erase_cache_config/1]).
-export([is_member/2, get_entry/2]).
-export([put_entry_front/3, merge_entry/3]).
-export([delete_entry/2, delete_pattern/2]).
-export([purge_last_segment_and_rotate/1]).

-record(segmented_cache, {
    scope :: segmented_cache:scope(),
    name :: segmented_cache:name(),
    telemetry_name :: [segmented_cache:name()],
    strategy = fifo :: segmented_cache:strategy(),
    entries_limit = infinity :: segmented_cache:entries_limit(),
    index :: atomics:atomics_ref(),
    segments :: tuple(),
    merger_fun :: merger_fun(dynamic())
}).

-type merger_fun(Value) :: fun((Value, Value) -> Value).
-type iterative_fun(Key, Value) :: fun((ets:tid(), Key) -> {continue | stop, Value}).
-type config() :: #segmented_cache{}.

%%====================================================================
%% Cache config
%%====================================================================

-spec init_cache_config(segmented_cache:name(), segmented_cache:opts()) ->
    #{scope := segmented_cache:scope(), ttl := timeout()}.
init_cache_config(Name, Opts0) ->
    #{
        scope := Scope,
        strategy := Strategy,
        entries_limit := EntriesLimit,
        segment_num := N,
        ttl := TTL,
        merger_fun := MergerFun,
        prefix := TelemetryEventName
    } = Opts = assert_parameters(Name, Opts0),
    SegmentOpts = ets_settings(Opts),
    SegmentsList = lists:map(fun(_) -> ets:new(undefined, SegmentOpts) end, lists:seq(1, N)),
    Segments = list_to_tuple(SegmentsList),
    Index = atomics:new(1, [{signed, false}]),
    atomics:put(Index, 1, 1),
    Config = #segmented_cache{
        scope = Scope,
        telemetry_name = TelemetryEventName,
        name = Name,
        strategy = Strategy,
        index = Index,
        entries_limit = EntriesLimit,
        segments = Segments,
        merger_fun = MergerFun
    },
    persist_cache_config(Name, Config),
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

-spec persist_cache_config(segmented_cache:name(), config()) -> ok.
persist_cache_config(Name, Config) ->
    persistent_term:put({?APP_KEY, Name}, Config).

%%====================================================================
%% ETS checks
%%====================================================================

-spec is_member(segmented_cache:name(), segmented_cache:key()) -> boolean().
is_member(Name, Key) when is_atom(Name) ->
    #segmented_cache{telemetry_name = Prefix} = SegmentRecord = get_cache_config(Name),
    Span = fun() ->
        Value = iterate_fun_in_tables(
            SegmentRecord, Key, fun segmented_cache_callbacks:is_member_ets_fun/2
        ),
        {Value, #{name => Name, type => is_member, hit => Value =:= true}}
    end,
    telemetry:span(Prefix, #{name => Name, type => is_member}, Span).

-spec get_entry(segmented_cache:name(), segmented_cache:key()) ->
    segmented_cache:value() | not_found.
get_entry(Name, Key) when is_atom(Name) ->
    #segmented_cache{telemetry_name = Prefix} = SegmentRecord = get_cache_config(Name),
    Span = fun() ->
        Value = iterate_fun_in_tables(
            SegmentRecord, Key, fun segmented_cache_callbacks:get_entry_ets_fun/2
        ),
        {Value, #{name => Name, type => get_entry, hit => Value =/= not_found}}
    end,
    telemetry:span(Prefix, #{name => Name, type => get_entry}, Span).

%% Atomically compare_and_swap an entry, attempt three times, post-check front insert
-spec put_entry_front(segmented_cache:name(), segmented_cache:key(), segmented_cache:value()) ->
    boolean().
put_entry_front(Name, Key, Value) ->
    SegmentRecord = get_cache_config(Name),
    do_put_entry_front(SegmentRecord, Key, Value, 3).

-spec merge_entry(segmented_cache:name(), segmented_cache:key(), segmented_cache:value()) ->
    boolean().
merge_entry(Name, Key, Value) when is_atom(Name) ->
    SegmentRecord = get_cache_config(Name),
    F = fun(EtsSegment, KKey) ->
        MergerFun = SegmentRecord#segmented_cache.merger_fun,
        case compare_and_swap(3, EtsSegment, KKey, Value, MergerFun) of
            true -> {stop, true};
            false -> {continue, false}
        end
    end,
    case iterate_fun_in_tables(SegmentRecord, Key, F) of
        true -> true;
        false -> do_put_entry_front(SegmentRecord, Key, Value, 3)
    end.

-spec delete_entry(segmented_cache:name(), segmented_cache:key()) -> true.
delete_entry(Name, Key) when is_atom(Name) ->
    delete_request(Name, Key, entry, fun segmented_cache_callbacks:delete_entry_fun/2).

-spec delete_pattern(segmented_cache:name(), ets:match_pattern()) -> true.
delete_pattern(Name, Pattern) when is_atom(Name) ->
    delete_request(Name, Pattern, pattern, fun segmented_cache_callbacks:delete_pattern_fun/2).

-spec delete_request(segmented_cache:name(), Key, Type, IterativeFun) -> dynamic() when
    Key :: segmented_cache:key(),
    Type :: entry | pattern,
    IterativeFun :: iterative_fun(Key, dynamic()).
delete_request(Name, Value, Type, Fun) ->
    #segmented_cache{telemetry_name = Prefix} = SegmentRecord = get_cache_config(Name),
    try
        iterate_fun_in_tables(SegmentRecord, Value, Fun)
    catch
        Class:Reason ->
            Metadata = #{
                name => Name, delete_type => Type, value => Value, class => Class, reason => Reason
            },
            telemetry:execute(Prefix ++ [delete_error], #{}, Metadata)
    end.

%%====================================================================
%% Internals
%%====================================================================

-spec iterate_fun_in_tables(config(), Key, IterativeFun) -> Value when
    IterativeFun :: iterative_fun(Key, Value).
iterate_fun_in_tables(SegmentRecord, Key, IterativeFun) ->
    Segments = SegmentRecord#segmented_cache.segments,
    Size = tuple_size(Segments),
    CurrentIndex = atomics:get(SegmentRecord#segmented_cache.index, 1),
    LastTableToCheck = next(CurrentIndex, Size),
    case iterate_fun_in_tables(IterativeFun, Key, Segments, Size, LastTableToCheck, CurrentIndex) of
        {not_found, Value} ->
            Value;
        {FoundIndex, Value} ->
            Strategy = SegmentRecord#segmented_cache.strategy,
            apply_strategy(Strategy, CurrentIndex, FoundIndex, Key, SegmentRecord),
            Value
    end.

-spec iterate_fun_in_tables(IterativeFun, Key, tuple(), Int, Int, Int) -> Result when
    Result :: {not_found, Value} | {non_neg_integer(), Value},
    Int :: non_neg_integer(),
    IterativeFun :: iterative_fun(Key, Value).
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
        {stop, Value} ->
            {Size, Value};
        {continue, _} ->
            iterate_fun_in_tables(IterativeFun, Key, Segments, Size, LastTableToCheck, 1)
    end;
% else we check the current table and if it fails we move forwards
iterate_fun_in_tables(IterativeFun, Key, Segments, Size, LastTableToCheck, Index) ->
    EtsSegment = element(Index, Segments),
    case IterativeFun(EtsSegment, Key) of
        {stop, Value} ->
            {Index, Value};
        {continue, _} ->
            iterate_fun_in_tables(IterativeFun, Key, Segments, Size, LastTableToCheck, Index + 1)
    end.

%% Apply configured eviction strategy
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
    try
        [{_, Value}] = ets:lookup(FoundInSegment, Key),
        do_put_entry_front(SegmentRecord, Key, Value, 3)
    catch
        _:_ -> false
    end.

-spec do_put_entry_front(config(), segmented_cache:key(), segmented_cache:value(), 0..3) ->
    boolean().
do_put_entry_front(_, _, _, 0) ->
    false;
do_put_entry_front(
    #segmented_cache{
        name = Name,
        entries_limit = EntriesLimit,
        index = Atomic,
        segments = Segments,
        merger_fun = MergerFun
    } = SegmentRecord,
    Key,
    Value,
    Retry
) ->
    Index = atomics:get(Atomic, 1),
    FrontSegment = element(Index, Segments),
    case insert_new(FrontSegment, Key, Value, EntriesLimit, Name) of
        retry ->
            do_put_entry_front(SegmentRecord, Key, Value, Retry - 1);
        true ->
            MaybeMovedIndex = atomics:get(Atomic, 1),
            case post_insert_check_should_retry(true, Index, MaybeMovedIndex) of
                false -> true;
                true -> do_put_entry_front(SegmentRecord, Key, Value, Retry - 1)
            end;
        false ->
            Inserted = compare_and_swap(3, FrontSegment, Key, Value, MergerFun),
            MaybeMovedIndex = atomics:get(Atomic, 1),
            case post_insert_check_should_retry(Inserted, Index, MaybeMovedIndex) of
                false -> Inserted;
                true -> do_put_entry_front(SegmentRecord, Key, Value, Retry - 1)
            end
    end.

insert_new(Table, Key, Value, infinity, _) ->
    ets:insert_new(Table, {Key, Value});
insert_new(Table, Key, Value, EntriesLimit, Name) ->
    case EntriesLimit =< ets:info(Table, size) of
        false ->
            ets:insert_new(Table, {Key, Value});
        true ->
            purge_last_segment_and_rotate(Name),
            retry
    end.

-spec post_insert_check_should_retry(boolean(), integer(), integer()) -> boolean().
% Table index didn't move, insert is still in the front
post_insert_check_should_retry(true, Index, Index) -> false;
% Insert succeded but the table is not the first anymore, retry,
% rotation will not happen again in a long while
post_insert_check_should_retry(true, _, _) -> true;
% Insert failed, so it doesn't matter, just abort
post_insert_check_should_retry(false, _, _) -> false.

-spec compare_and_swap(non_neg_integer(), ets:tid(), Key, Value, MergerFun) -> boolean() when
    Key :: segmented_cache:key(),
    MergerFun :: merger_fun(Value).
compare_and_swap(0, _EtsSegment, _Key, _Value, _MergerFun) ->
    false;
compare_and_swap(Attempts, EtsSegment, Key, Value, MergerFun) ->
    case ets:lookup(EtsSegment, Key) of
        [{_, OldValue}] ->
            NewValue = MergerFun(OldValue, Value),
            case
                ets:select_replace(EtsSegment, [{{Key, OldValue}, [], [{const, {Key, NewValue}}]}])
            of
                1 -> true;
                0 -> compare_and_swap(Attempts - 1, EtsSegment, Key, Value, MergerFun)
            end;
        [] ->
            false
    end.

%% Rotate the tables
%% Note that we must first empty the last table, and then rotate the index. If it was done
%% in the opposite order, there's a chance a worker can insert an entry at the front just
%% before the table is purged.
-spec purge_last_segment_and_rotate(segmented_cache:name()) -> non_neg_integer().
purge_last_segment_and_rotate(Name) ->
    SegmentRecord = get_cache_config(Name),
    Index = atomics:get(SegmentRecord#segmented_cache.index, 1),
    Segments = SegmentRecord#segmented_cache.segments,
    Size = tuple_size(Segments),
    %% If Size was 1, Index would not change
    NewIndex = next(Index, Size),
    TableToClear = element(NewIndex, Segments),
    ets:delete_all_objects(TableToClear),
    atomics:put(SegmentRecord#segmented_cache.index, 1, NewIndex),
    NewIndex.

-spec assert_parameters(segmented_cache:name(), segmented_cache:opts()) -> segmented_cache:opts().
assert_parameters(Name, Opts0) when is_map(Opts0) ->
    #{
        scope := Scope,
        strategy := Strategy,
        entries_limit := EntriesLimit,
        segment_num := N,
        ttl := TTL0,
        merger_fun := MergerFun
    } = Opts = maps:merge(defaults(), Opts0),
    TelemetryEventName = maps:get(prefix, Opts0, [segmented_cache, Name, request]),
    true = is_list(TelemetryEventName),
    TTL =
        case TTL0 of
            infinity -> infinity;
            {milliseconds, S} -> S;
            {seconds, S} -> timer:seconds(S);
            {minutes, M} -> timer:minutes(M);
            {hours, H} -> timer:hours(H);
            T when is_integer(T) -> timer:minutes(T)
        end,
    true = is_integer(N) andalso N > 0,
    true = is_pos_int_or_infinity(EntriesLimit),
    true = is_pos_int_or_infinity(TTL),
    true = (Strategy =:= fifo) orelse (Strategy =:= lru),
    true = is_function(MergerFun, 2),
    true = (undefined =/= whereis(Scope)),
    Opts#{ttl := TTL, prefix => TelemetryEventName}.

is_pos_int_or_infinity(Value) ->
    (Value =:= infinity) orelse (is_integer(Value) andalso 0 < Value).

next(Index, Size) ->
    case Index of
        1 -> Size;
        _ -> Index - 1
    end.

defaults() ->
    #{
        scope => pg,
        strategy => fifo,
        entries_limit => infinity,
        segment_num => 3,
        ttl => {hours, 8},
        merger_fun => fun segmented_cache_callbacks:default_merger_fun/2
    }.

ets_settings(#{entries_limit := infinity}) ->
    [
        set,
        public,
        {read_concurrency, true},
        {write_concurrency, auto},
        {decentralized_counters, true}
    ];
ets_settings(#{entries_limit := _}) ->
    [
        set,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ].
