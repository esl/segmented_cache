-module(segmented_cache_proper_commands).

%% proper_statem exports
-export([command/1,
         initial_state/0,
         next_state/3,
         precondition/2,
         postcondition/3]).

%% command exports
-export([is_member/1,
         get_entry/1,
         put_entry/1,
         merge_entry/1,
         delete_entry/1]).

-include_lib("proper/include/proper.hrl").
-include_lib("stdlib/include/assert.hrl").

initial_state() ->
    #{}.

command(_State) ->
    oneof([
      {call, ?MODULE, is_member, [term()]},
      {call, ?MODULE, put_entry, [{{term(), make_ref()}, term()}]},
      {call, ?MODULE, get_entry, [term()]},
      {call, ?MODULE, merge_entry, [{{term(), make_ref()}, term()}]},
      {call, ?MODULE, delete_entry, [term()]}
    ]).

precondition(State, {call, Module, Action, Args}) ->
    Module:Action({precondition, State, Args}).

next_state(S, Result, {call, Module, Action, Args}) ->
    Module:Action({next_state, S, Args, Result}).

postcondition(State, {call, Module, Action, Args}, Res) ->
    ?assert(Module:Action({postcondition, State, Args, Res}),
            [{command, {Module, Action, Args}}, {result, Res}]),
    true.


%% Command definition
is_member({precondition, _State, _Args}) ->
    true;
is_member({next_state, State, _Args, _Res}) ->
    State;
is_member({postcondition, State, [Key], Res}) ->
    ExpectedRes =
        case maps:get(Key, State, not_found) of
            not_found -> false;
            _Value -> true
        end,
    ExpectedRes =:= Res;
is_member(Key) ->
    segmented_cache:is_member(test, Key).


get_entry({precondition, _State, _Args}) ->
    true;
get_entry({next_state, State, _Args, _Res}) ->
    State;
get_entry({postcondition, State, [Key], Res}) ->
    ExpectedRes = maps:get(Key, State, not_found),
    ExpectedRes =:= Res;
get_entry(Key) ->
    segmented_cache:get_entry(test, Key).


put_entry({precondition, State, [{Key, _Value}]}) ->
    %% Do not call `put_entry` for keys already inserted.
    %% We already got `merge_entry` for that.
    case maps:get(Key, State, not_found) of
        not_found -> true;
        _Value1 -> false
    end;
put_entry({next_state, State, [{Key, Value}], _Res}) ->
    State#{Key => Value};
put_entry({postcondition, _State, [{Key, Value}], Res}) ->
    Entry = segmented_cache:get_entry(test, Key),
    IsMember = segmented_cache:is_member(test, Key),
    Entry =:= Value andalso IsMember andalso Res;
put_entry({Key, Value}) ->
    segmented_cache:put_entry(test, Key, Value).


merge_entry({precondition, _State, _Args}) ->
    true;
merge_entry({next_state, State, [{Key, Value}], _Res}) ->
    State#{Key => Value};
merge_entry({postcondition, State, [{Key, Value}], Res}) ->
    Entry = segmented_cache:get_entry(test, Key),
    IsMember = segmented_cache:is_member(test, Key),
    case maps:get(Key, State, not_found) of
        %% If the entry wasn't added, check it's there now
        not_found ->
            Entry =:= Value andalso IsMember andalso Res;
        %% If the entry already existed, check the value was updated
        ExpectedValue ->
            Entry =:= Value andalso Entry =/= ExpectedValue andalso IsMember andalso Res
    end,
    true;
merge_entry({Key, Value}) ->
    segmented_cache:merge_entry(test, Key, Value).


delete_entry({precondition, _State, _Args}) ->
    true;
delete_entry({next_state, State, [Key], _Res}) ->
    maps:remove(Key, State);
delete_entry({postcondition, _State, [Key], true}) ->
    Entry = segmented_cache:get_entry(test, Key),
    IsMember = segmented_cache:is_member(test, Key),
    Entry =:= not_found andalso (not IsMember);
delete_entry(Key) ->
    segmented_cache:delete_entry(test, Key).
