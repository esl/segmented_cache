-module(segmented_cache_server).
-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-endif.
?MODULEDOC(false).

-behaviour(gen_server).

%% API
-export([start/2, start_link/2, request_delete_entry/2, request_delete_pattern/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-type request_content() :: dynamic().
-record(cache_state, {
    scope :: segmented_cache:scope(),
    name :: segmented_cache:name(),
    ttl :: timeout(),
    timer_ref :: undefined | reference()
}).
-type state() :: #cache_state{}.

%%====================================================================
%% API
%%====================================================================

-spec start(segmented_cache:name(), segmented_cache:opts()) -> gen_server:start_ret().
start(Name, Opts) when is_atom(Name), is_map(Opts) ->
    gen_server:start(?MODULE, {Name, Opts}, []).

-spec start_link(segmented_cache:name(), segmented_cache:opts()) -> gen_server:start_ret().
start_link(Name, Opts) when is_atom(Name), is_map(Opts) ->
    gen_server:start_link(?MODULE, {Name, Opts}, []).

-spec request_delete_entry(segmented_cache:name(), request_content()) -> ok.
request_delete_entry(Name, Entry) ->
    send_to_group(Name, {delete_entry, Entry}).

-spec request_delete_pattern(segmented_cache:name(), request_content()) -> ok.
request_delete_pattern(Name, Pattern) ->
    send_to_group(Name, {delete_pattern, Pattern}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

-spec init({segmented_cache:name(), segmented_cache:opts()}) -> {ok, state()}.
init({Name, Opts}) ->
    erlang:process_flag(trap_exit, true),
    #{scope := Scope, ttl := TTL} = segmented_cache_helpers:init_cache_config(Name, Opts),
    pg:join(Scope, Name, self()),
    case TTL of
        infinity ->
            {ok, #cache_state{scope = Scope, name = Name, ttl = infinity, timer_ref = undefined}};
        _ ->
            TimerRef = erlang:send_after(TTL, self(), purge),
            {ok, #cache_state{scope = Scope, name = Name, ttl = TTL, timer_ref = TimerRef}}
    end.

-spec handle_call(any(), gen_server:from(), state()) -> {reply, ok, state()}.
handle_call(_Msg, _From, State) ->
    {reply, ok, State}.

-spec handle_cast(Cast, state()) -> {noreply, state()} when
    Cast ::
        {delete_entry, segmented_cache:key()}
        | {delete_pattern, ets:match_pattern()}.
handle_cast({delete_entry, Key}, #cache_state{name = Name} = State) ->
    segmented_cache_helpers:delete_entry(Name, Key),
    {noreply, State};
handle_cast({delete_pattern, Pattern}, #cache_state{name = Name} = State) ->
    segmented_cache_helpers:delete_pattern(Name, Pattern),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(dynamic(), state()) -> {noreply, state()} | {stop, term(), state()}.
handle_info(purge, #cache_state{name = Name, ttl = TTL} = State) ->
    segmented_cache_helpers:purge_last_segment_and_rotate(Name),
    case TTL of
        infinity -> {noreply, State};
        _ -> {noreply, State#cache_state{timer_ref = erlang:send_after(TTL, self(), purge)}}
    end;
handle_info({'EXIT', _, Reason}, State) ->
    {stop, Reason, State};
handle_info(_Msg, State) ->
    {noreply, State}.

-spec terminate(normal | shutdown | {shutdown, term()} | term(), state()) -> term().
terminate(_Reason, #cache_state{name = Name, timer_ref = TimerRef}) ->
    segmented_cache_helpers:erase_cache_config(Name),
    case TimerRef of
        undefined -> ok;
        _ -> erlang:cancel_timer(TimerRef, [{async, true}, {info, false}])
    end.

send_to_group(Name, Msg) ->
    Scope = segmented_cache_helpers:get_cache_scope(Name),
    Pids = pg:get_members(Scope, Name) -- pg:get_local_members(Scope, Name),
    [gen_server:cast(Pid, Msg) || Pid <- Pids],
    ok.
