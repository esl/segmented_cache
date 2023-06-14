%% @private
-module(segmented_cache_callbacks).

-export([is_member_ets_fun/2, get_entry_ets_fun/2,
         delete_entry_fun/2, delete_pattern_fun/2,
         default_merger_fun/2]).

-spec is_member_ets_fun(ets:tid(), segmented_cache:key()) -> {continue, false} | {stop, true}.
is_member_ets_fun(EtsSegment, Key) ->
    case ets:member(EtsSegment, Key) of
        true -> {stop, true};
        false -> {continue, false}
    end.

-spec get_entry_ets_fun(ets:tid(), Key) ->
    {continue, not_found} | {stop, Value}
      when Key :: segmented_cache:key(), Value :: segmented_cache:value().
get_entry_ets_fun(EtsSegment, Key) ->
    case ets:lookup(EtsSegment, Key) of
        [{_, Value}] -> {stop, Value};
        [] -> {continue, not_found}
    end.

-spec delete_entry_fun(ets:tid(), segmented_cache:key()) -> {continue, true}.
delete_entry_fun(EtsSegment, Key) ->
    ets:delete(EtsSegment, Key),
    {continue, true}.

-spec delete_pattern_fun(ets:tid(), ets:match_pattern()) -> {continue, true}.
delete_pattern_fun(EtsSegment, Pattern) ->
    ets:match_delete(EtsSegment, Pattern),
    {continue, true}.

%% @doc This merger simply discards the older value
-spec default_merger_fun(T, T) -> T when T :: term().
default_merger_fun(_OldValue, NewValue) ->
    NewValue.
