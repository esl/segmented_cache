-module(segmented_cache_SUITE).

-compile([export_all, nowarn_export_all]).

%% API
-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("proper/include/proper.hrl").

-define(CACHE_NAME, test).
-define(CMD_MODULE, segmented_cache_proper_commands).

all() ->
    [
        {group, basic_api},
        {group, cache_limits},
        {group, short_fifo},
        {group, lru}
    ].

groups() ->
    [
        {basic_api, [sequence], [
            put_entry_concurrently,
            put_entry_and_then_get_it,
            put_entry_and_then_check_membership,
            put_entry_then_delete_it_then_not_member,
            stateful_property
        ]},
        {cache_limits, [sequence], [
            ensure_configured_size_is_respected
        ]},
        {short_fifo, [sequence], [
            put_entry_wait_and_check_false
        ]},
        {lru, [sequence], [
            put_entry_and_verify_it_stays,
            put_entry_and_verify_it_stays_under_load,
            stateful_property
        ]}
    ].

%%%===================================================================
%%% Overall setup/teardown
%%%===================================================================
init_per_suite(Config) ->
    ct:pal("Online schedulers ~p~n", [erlang:system_info(schedulers_online)]),
    application:ensure_all_started(telemetry),
    cnt_pt_new(?CACHE_NAME),
    ok = telemetry:attach(
        <<"cache-request-handler">>,
        [segmented_cache, ?CACHE_NAME, request, stop],
        fun ?MODULE:handle_event/4,
        []
    ),
    pg:start(pg),
    Config.

end_per_suite(_Config) ->
    print_and_restart_counters(),
    ok.

%%%===================================================================
%%% Group specific setup/teardown
%%%===================================================================
init_per_group(lru, Config) ->
    print_and_restart_counters(),
    Opts = #{
        strategy => lru,
        segment_num => 2,
        ttl => {milliseconds, 100}
    },
    {ok, Cleaner} = segmented_cache:start(?CACHE_NAME, Opts),
    [{cleaner, Cleaner} | Config];
init_per_group(short_fifo, Config) ->
    print_and_restart_counters(),
    Opts = #{
        strategy => fifo,
        segment_num => 2,
        ttl => {milliseconds, 5}
    },
    {ok, Cleaner} = segmented_cache:start(?CACHE_NAME, Opts),
    [{cleaner, Cleaner} | Config];
init_per_group(cache_limits, Config) ->
    print_and_restart_counters(),
    Opts = #{
        entries_limit => 1,
        strategy => fifo,
        segment_num => 2,
        ttl => {seconds, 60}
    },
    {ok, Cleaner} = segmented_cache:start(?CACHE_NAME, Opts),
    [{cleaner, Cleaner} | Config];
init_per_group(_Groupname, Config) ->
    print_and_restart_counters(),
    {ok, Cleaner} = segmented_cache:start(?CACHE_NAME),
    [{cleaner, Cleaner} | Config].

end_per_group(_Groupname, Config) ->
    exit(?config(cleaner, Config), ok),
    ok.

%%%===================================================================
%%% Testcase specific setup/teardown
%%%===================================================================
init_per_testcase(TestCase, Config) when
    TestCase =:= put_entry_and_verify_it_stays;
    TestCase =:= put_entry_and_verify_it_stays_under_load
->
    print_and_restart_counters(),
    Config;
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%%===================================================================
%%% Stateful property Test Case
%%%===================================================================

ensure_configured_size_is_respected(_Config) ->
    %% We have 2 tables with 1 element each
    ?assert(segmented_cache:put_entry(?CACHE_NAME, one, make_ref())),
    ?assert(segmented_cache:put_entry(?CACHE_NAME, two, make_ref())),
    ?assert(segmented_cache:put_entry(?CACHE_NAME, three, make_ref())),
    ?assert(segmented_cache:is_member(?CACHE_NAME, three)),
    ?assert(segmented_cache:is_member(?CACHE_NAME, two)),
    ?assertNot(segmented_cache:is_member(?CACHE_NAME, one)).

stateful_property(_Config) ->
    Prop =
        ?FORALL(
            Cmds,
            commands(?CMD_MODULE),
            begin
                %% Setup and teardown can be found in the init and end for this test case
                {History, State, Res} = run_commands(?CMD_MODULE, Cmds),
                ?WHENFAIL(
                    io:format("H: ~p~nS: ~p~n Res: ~p~n", [History, State, Res]),
                    Res == ok
                )
            end
        ),
    run_prop(?FUNCTION_NAME, Prop).

%%%===================================================================
%%% Individual Test Cases (from groups() definition)
%%%===================================================================

put_entry_concurrently(_) ->
    Prop = ?FORALL(
        {Key, Value},
        {non_empty(binary()), union([char(), binary(), integer()])},
        true =:= segmented_cache:put_entry(?CACHE_NAME, {Key, make_ref()}, Value)
    ),
    run_prop(?FUNCTION_NAME, Prop).

put_entry_and_then_get_it(_) ->
    Prop = ?FORALL(
        {Key0, Value},
        {non_empty(binary()), union([char(), binary(), integer()])},
        begin
            Key = {Key0, make_ref()},
            segmented_cache:put_entry(?CACHE_NAME, Key, Value),
            Value =:= segmented_cache:get_entry(?CACHE_NAME, Key)
        end
    ),
    run_prop(?FUNCTION_NAME, Prop).

put_entry_and_then_check_membership(_) ->
    Prop = ?FORALL(
        {Key0, Value},
        {non_empty(binary()), union([char(), binary(), integer()])},
        begin
            Key = {Key0, make_ref()},
            segmented_cache:put_entry(?CACHE_NAME, Key, Value),
            true =:= segmented_cache:is_member(?CACHE_NAME, Key)
        end
    ),
    run_prop(?FUNCTION_NAME, Prop).

put_entry_then_delete_it_then_not_member(_) ->
    Prop = ?FORALL(
        {Key0, Value},
        {non_empty(binary()), union([char(), binary(), integer()])},
        begin
            Key = {Key0, make_ref()},
            segmented_cache:put_entry(?CACHE_NAME, Key, Value),
            segmented_cache:is_member(?CACHE_NAME, Key),
            segmented_cache:delete_entry(?CACHE_NAME, Key),
            false =:= segmented_cache:is_member(?CACHE_NAME, Key)
        end
    ),
    run_prop(?FUNCTION_NAME, Prop).

put_entry_wait_and_check_false(_) ->
    Prop = ?FORALL(
        {Key0, Value},
        {non_empty(binary()), binary()},
        begin
            Key = {Key0, make_ref()},
            segmented_cache:put_entry(?CACHE_NAME, Key, Value),
            case
                wait_until(
                    fun() -> segmented_cache:is_member(?CACHE_NAME, Key) end,
                    false,
                    #{time_left => timer:seconds(1), sleep_time => 4}
                )
            of
                {ok, false} -> true;
                _ -> false
            end
        end
    ),
    run_prop(?FUNCTION_NAME, Prop).

put_entry_and_verify_it_stays(_) ->
    Prop = ?FORALL(
        {Key0, Value},
        {non_empty(binary()), binary()},
        begin
            Key = {Key0, make_ref()},
            true = segmented_cache:put_entry(?CACHE_NAME, Key, Value),
            case
                wait_until(
                    fun() -> segmented_cache:is_member(?CACHE_NAME, Key) end,
                    false,
                    #{time_left => 250, sleep_time => 20}
                )
            of
                {ok, false} -> false;
                {error, _E} -> true
            end
        end
    ),
    run_prop(?FUNCTION_NAME, Prop, 100, 1).

put_entry_and_verify_it_stays_under_load(_) ->
    Prop = ?FORALL(
        {Key0, Value},
        {non_empty(binary()), binary()},
        begin
            Key = {Key0, make_ref()},
            true = segmented_cache:put_entry(?CACHE_NAME, Key, Value),
            case
                wait_until(
                    fun() -> segmented_cache:is_member(?CACHE_NAME, Key) end,
                    false,
                    #{time_left => 250, sleep_time => 20}
                )
            of
                _ -> true
            end
        end
    ),
    run_prop(?FUNCTION_NAME, Prop, 10_000, 128),
    {Hits, Misses} = print_and_restart_counters(),
    ct:pal("Hits ~p; Misses ~p~n", [Hits, Misses]),
    Total = Hits + Misses,
    case Misses / Total < 0.001 of
        true -> ok;
        _N -> error("Too many misses")
    end.

run_prop(PropName, Property) ->
    run_prop(PropName, Property, 100_000).

run_prop(PropName, Property, NumTests) ->
    run_prop(PropName, Property, NumTests, 256).

run_prop(PropName, Property, NumTests, WorkersPerScheduler) ->
    Opts = [
        quiet,
        noshrink,
        long_result,
        {start_size, 2},
        {numtests, NumTests},
        {numworkers, WorkersPerScheduler * erlang:system_info(schedulers_online)}
    ],
    case proper:quickcheck(proper:conjunction([{PropName, Property}]), Opts) of
        true -> ok;
        Res -> ct:fail(Res)
    end.

%% @doc Waits `TimeLeft` for `Fun` to return `ExpectedValue`
%% If the result of `Fun` matches `ExpectedValue`, returns {ok, ExpectedValue}
%% If no value is returned or the result doesn't match `ExpectedValue`, returns {error, _}
wait_until(Fun, ExpectedValue, Opts) ->
    Defaults = #{
        time_left => timer:seconds(5),
        sleep_time => 50,
        history => []
    },
    do_wait_until(Fun, ExpectedValue, maps:merge(Defaults, Opts)).

do_wait_until(_Fun, ExpectedValue, #{
    time_left := TimeLeft,
    history := History
}) when TimeLeft =< 0 ->
    {error, {timeout, ExpectedValue, lists:reverse(History)}};
do_wait_until(Fun, ExpectedValue, Opts) ->
    try Fun() of
        ExpectedValue ->
            {ok, ExpectedValue};
        OtherValue ->
            wait_and_continue(Fun, ExpectedValue, OtherValue, Opts)
    catch
        Error:Reason ->
            wait_and_continue(Fun, ExpectedValue, {Error, Reason}, Opts)
    end.

wait_and_continue(
    Fun,
    ExpectedValue,
    FunResult,
    #{
        time_left := TimeLeft,
        sleep_time := SleepTime,
        history := History
    } = Opts
) ->
    timer:sleep(SleepTime),
    do_wait_until(Fun, ExpectedValue, Opts#{
        time_left => TimeLeft - SleepTime,
        history => [FunResult | History]
    }).

handle_event([segmented_cache, CacheName, request, stop], _, #{hit := Hit}, _) ->
    case Hit of
        true -> cnt_pt_incr_hits(CacheName);
        false -> cnt_pt_incr_misses(CacheName)
    end.

cnt_pt_new(Counter) ->
    persistent_term:put({?MODULE, Counter}, counters:new(2, [write_concurrency])).

cnt_pt_incr_hits(Counter) ->
    counters:add(persistent_term:get({?MODULE, Counter}), 1, 1).

cnt_pt_incr_misses(Counter) ->
    counters:add(persistent_term:get({?MODULE, Counter}), 2, 1).

cnt_pt_read_hits(Counter) ->
    counters:get(persistent_term:get({?MODULE, Counter}), 1).

cnt_pt_read_misses(Counter) ->
    counters:get(persistent_term:get({?MODULE, Counter}), 2).

print_and_restart_counters() ->
    Hits = cnt_pt_read_hits(?CACHE_NAME),
    Misses = cnt_pt_read_misses(?CACHE_NAME),
    counters:put(persistent_term:get({?MODULE, ?CACHE_NAME}), 1, 0),
    counters:put(persistent_term:get({?MODULE, ?CACHE_NAME}), 2, 0),
    {Hits, Misses}.
