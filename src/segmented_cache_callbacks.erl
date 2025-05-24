-module(segmented_cache_callbacks).
-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-endif.
?MODULEDOC(false).

-export([
    is_member_ets_fun/2,
    get_entry_ets_fun/2,
    delete_entry_fun/2,
    delete_pattern_fun/2,
    default_merger_fun/2
]).

-spec is_member_ets_fun(ets:tid(), segmented_cache:key()) -> {continue, false} | {stop, true}.
is_member_ets_fun(EtsSegment, Key) ->
    case ets:member(EtsSegment, Key) of
        true -> {stop, true};
        false -> {continue, false}
    end.

-spec get_entry_ets_fun(ets:tid(), Key) -> {continue, not_found} | {stop, Value} when
    Key :: segmented_cache:key(), Value :: segmented_cache:value().
get_entry_ets_fun(EtsSegment, Key) ->
    case ets:lookup_element(EtsSegment, Key, 2, '$not_found') of
        '$not_found' -> {continue, not_found};
        Value -> {stop, Value}
    end.

-spec delete_entry_fun(ets:tid(), segmented_cache:key()) -> {continue, true}.
delete_entry_fun(EtsSegment, Key) ->
    ets:delete(EtsSegment, Key),
    {continue, true}.

-spec delete_pattern_fun(ets:tid(), ets:match_pattern()) -> {continue, true}.
delete_pattern_fun(EtsSegment, Pattern) ->
    ets:match_delete(EtsSegment, Pattern),
    {continue, true}.

%% This merger simply discards the older value
-spec default_merger_fun(T, T) -> T when T :: dynamic().
default_merger_fun(_OldValue, NewValue) ->
    NewValue.
