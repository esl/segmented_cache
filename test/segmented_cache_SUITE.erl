-module(segmented_cache_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

%% API
-export([all/0,
         groups/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_group/2,
         end_per_group/2,
         init_per_testcase/2,
         end_per_testcase/2]).

-include_lib("common_test/include/ct.hrl").
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
     {group, basic_api},
     {group, short_fifo}
    ].

groups() ->
    [
     {basic_api, [sequence],
      [
       put_entry_concurrently,
       put_entry_and_then_get_it,
       put_entry_and_then_check_membership
      ]},
     {short_fifo, [sequence],
      [
       put_entry_wait_and_check_false
      ]}
    ].

%%%===================================================================
%%% Overall setup/teardown
%%%===================================================================
init_per_suite(Config) ->
    application:ensure_all_started(telemetry),
    pg:start(pg),
    Config.

end_per_suite(_Config) ->
    ok.

%%%===================================================================
%%% Group specific setup/teardown
%%%===================================================================
init_per_group(short_fifo, Config) ->
    {ok, Cleaner} = segmented_cache:start(test, #{strategy => fifo,
                                                  segment_num => 2,
                                                  ttl => {milliseconds, 5}}),
    [{cleaner, Cleaner} | Config];
init_per_group(_Groupname, Config) ->
    {ok, Cleaner} = segmented_cache:start(test),
    [{cleaner, Cleaner} | Config].

end_per_group(_Groupname, Config) ->
    exit(?config(cleaner, Config), ok),
    ok.

%%%===================================================================
%%% Testcase specific setup/teardown
%%%===================================================================
init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%%===================================================================
%%% Individual Test Cases (from groups() definition)
%%%===================================================================

put_entry_concurrently(_) ->
    Prop = ?FORALL({Key, Value}, {non_empty(binary(10)), union([char(), binary(), integer()])},
                   true =:= segmented_cache:put_entry(test, Key, #{value => Value})),
    run_prop(?FUNCTION_NAME, Prop).

put_entry_and_then_get_it(_) ->
    Prop = ?FORALL({Key, Value}, {non_empty(binary(32)), union([char(), binary(), integer()])},
                   begin
                       segmented_cache:put_entry(test, Key, Value),
                       Value =:= segmented_cache:get_entry(test, Key)
                   end),
    run_prop(?FUNCTION_NAME, Prop).

put_entry_and_then_check_membership(_) ->
    Prop = ?FORALL({Key, Value}, {non_empty(binary(10)), union([char(), binary(), integer()])},
                   begin
                       segmented_cache:put_entry(test, Key, Value),
                       true =:= segmented_cache:is_member(test, Key)
                   end),
    run_prop(?FUNCTION_NAME, Prop).

put_entry_wait_and_check_false(_) ->
    Prop = ?FORALL({Key, Value}, {non_empty(binary(10)), binary()},
                   begin
                       segmented_cache:put_entry(test, Key, Value),
                       case wait_until(fun() -> segmented_cache:is_member(test, Key) end,
                                       false, #{time_left => timer:seconds(1), sleep_time => 4}) of
                           {ok, false} -> true;
                           _ -> false
                       end
                   end),
    run_prop(?FUNCTION_NAME, Prop).

run_prop(PropName, Property) ->
    run_prop(PropName, Property, 100_000).

run_prop(PropName, Property, NumTests) ->
    Opts = [verbose, noshrink, long_result, {start_size, 2}, {numtests, NumTests},
            {numworkers, 256 * erlang:system_info(schedulers_online)}],
    case proper:quickcheck(proper:conjunction([{PropName, Property}]), Opts) of
        true -> ok;
        Res -> ct:fail(Res)
    end.


%% @doc Waits `TimeLeft` for `Fun` to return `ExpectedValue`
%% If the result of `Fun` matches `ExpectedValue`, returns {ok, ExpectedValue}
%% If no value is returned or the result doesn't match `ExpectedValue`, returns {error, _}
wait_until(Fun, ExpectedValue, Opts) ->
    Defaults = #{time_left => timer:seconds(5),
                 sleep_time => 50,
                 history => []},
    do_wait_until(Fun, ExpectedValue, maps:merge(Defaults, Opts)).

do_wait_until(_Fun, ExpectedValue, #{time_left := TimeLeft,
                                     history := History}) when TimeLeft =< 0 ->
    {error, {timeout, ExpectedValue, lists:reverse(History)}};
do_wait_until(Fun, ExpectedValue, Opts) ->
    try Fun() of
        ExpectedValue ->
            {ok, ExpectedValue};
        OtherValue ->
            wait_and_continue(Fun, ExpectedValue, OtherValue, Opts)
    catch Error:Reason ->
            wait_and_continue(Fun, ExpectedValue, {Error, Reason}, Opts)
    end.

wait_and_continue(Fun, ExpectedValue, FunResult, #{time_left := TimeLeft,
                                                   sleep_time := SleepTime,
                                                   history := History} = Opts) ->
    timer:sleep(SleepTime),
    do_wait_until(Fun, ExpectedValue, Opts#{time_left => TimeLeft - SleepTime,
                                            history => [FunResult | History]}).