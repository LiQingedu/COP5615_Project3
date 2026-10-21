-module(kvstore).
-behaviour(pastry).
%% The application on top of Pastry: a simple object store that maps a key
%% (a 128-bit id, like a nodeId) to a string. It also generates the workload.
%% After `start` the peer sends one request per second, numRequests in total.
%% Odd requests put a new string under the hash of the string; even requests
%% get a random key this peer stored earlier, and the answer is checked
%% against the string that was put.

-export([init/2, deliver/4, forward/4, new_leafs/2, handle_info/2]).

-record(kv, {id, index, requests, stats, sent = 0,
             store = #{},           % objects this node is responsible for
             own = #{},             % objects this peer put: Key => String
             own_keys = []}).

init(NodeId, {Index, Requests, Stats}) ->
    #kv{id = NodeId, index = Index, requests = Requests, stats = Stats}.

%% Called at the node numerically closest to Key.
deliver({put, String, _From}, Key, Hops, S = #kv{store = Store}) ->
    delivered(Key, Hops, S),
    S#kv{store = Store#{Key => String}};
deliver({get, From}, Key, Hops, S = #kv{store = Store}) ->
    delivered(Key, Hops, S),
    From ! {get_reply, Key, maps:get(Key, Store, not_found)},
    S.

%% The store does not need to change messages on their way.
forward(Msg, _Key, NextId, S) ->
    {Msg, NextId, S}.

%% Values are stored once, so there is no invariant to keep on the leaf set.
new_leafs(_LeafSet, S) ->
    S.

handle_info(start, S = #kv{requests = 0}) ->
    S;
handle_info(start, S) ->
    erlang:send_after(rand:uniform(1000) - 1, self(), tick),
    S;
handle_info(tick, S = #kv{sent = Sent, requests = Requests}) ->
    K = Sent + 1,
    case K < Requests of
        true -> erlang:send_after(1000, self(), tick);
        false -> ok
    end,
    request(K, S#kv{sent = K});
handle_info({get_reply, Key, Value}, S = #kv{own = Own, stats = Stats}) ->
    Result = case maps:get(Key, Own) of
                 Value -> ok;
                 _ when Value =:= not_found -> not_found;
                 _ -> wrong
             end,
    Stats ! {get_result, Result},
    S.

request(K, S = #kv{index = Index, own = Own, own_keys = Keys}) when K rem 2 =:= 1 ->
    String = lists:flatten(io_lib:format("peer~b-obj~b", [Index, K])),
    Key = pastry:id(String),
    pastry:route({put, String, self()}, Key),
    S#kv{own = Own#{Key => String}, own_keys = [Key | Keys]};
request(_, S = #kv{own_keys = Keys}) ->
    Key = lists:nth(rand:uniform(length(Keys)), Keys),
    pastry:route({get, self()}, Key),
    S.

delivered(Key, Hops, #kv{id = Id, stats = Stats}) ->
    Stats ! {delivered, Key, Id, Hops}.
