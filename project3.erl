-module(project3).
%% COP5615 Project 3: the Pastry protocol with a simple key -> string store.
%%
%% Usage: escript ./project3 numNodes numRequests
%%        [verbose=true] [failure=true|single|nodes:N|percent:P|edges:P|temporary-edges:P|combined-percent:P|permanent|temporary|multiple]
%%
%% The main process creates the peers one at a time; each joins through a
%% random peer that has already joined. Then every peer makes numRequests
%% requests, one per second. A stats actor collects the hop count of every
%% delivered request, checks that it reached the node numerically closest to
%% its key, and tells the main process when all requests are done.

-export([main/1, start/0, start/1, start/2]).

-define(STALL_MS, 10000).

start() ->
    main(init:get_plain_arguments()),
    halt().

%% `erl -noshell -s project3 start 1000 10` passes one list of atoms.
start(Args) when is_list(Args) ->
    main([arg_string(Arg) || Arg <- Args]),
    halt().

%% Also accept runtimes or wrappers that invoke start/2 directly.
start(NodesArg, RequestsArg) ->
    main([arg_string(NodesArg), arg_string(RequestsArg)]),
    halt().

arg_string(Arg) when is_atom(Arg) -> atom_to_list(Arg);
arg_string(Arg) -> Arg.

main([NodesArg, RequestsArg | Opts]) ->
    try {list_to_integer(NodesArg), list_to_integer(RequestsArg)} of
        {N, R} when N >= 1, R >= 0 -> run(N, R, options(Opts));
        _ -> usage()
    catch
        error:badarg -> usage()
    end;
main(_) ->
    usage().

usage() ->
    io:format("usage: project3 numNodes numRequests [verbose=true] "
              "[failure=true|single|nodes:N|percent:P|edges:P|temporary-edges:P|combined-percent:P|permanent|temporary|multiple]~n"),
    halt(1).

options(Opts) ->
    lists:foldl(fun("verbose=true", O) -> O#{verbose => true};
                   ("failure=true", O) -> O#{failure => combined};
                   ("failure=single", O) -> O#{failure => single};
                   ("failure=permanent", O) -> O#{failure => permanent};
                   ("failure=temporary", O) -> O#{failure => temporary};
                   ("failure=multiple", O) -> O#{failure => multiple};
                   (Opt, O) -> failure_nodes_option(Opt, O)
                end, #{verbose => false, failure => false}, Opts).

failure_nodes_option(Opt, O) ->
    case string:split(Opt, "failure=nodes:", leading) of
        [[], CountArg] ->
            case string:to_integer(CountArg) of
                {Count, []} when Count >= 1 -> O#{failure => {nodes, Count}};
                _ -> io:format("invalid failure option ~s~n", [Opt]), usage()
            end;
        _ -> failure_percentage_option(Opt, O)
    end.

failure_percentage_option(Opt, O) ->
    Prefixes = [{"failure=percent:", nodes}, {"failure=edges:", edges},
                {"failure=temporary-edges:", temporary_edges},
                {"failure=combined-percent:", combined}],
    case [{Kind, string:split(Opt, Prefix, leading)} || {Prefix, Kind} <- Prefixes,
                                                         string:prefix(Opt, Prefix) =/= nomatch] of
        [{Kind, [[], PercentArg]}] ->
            case string:to_integer(PercentArg) of
                {Percent, []} when Percent >= 1, Percent < 100 ->
                    O#{failure => {Kind, Percent}};
                _ -> io:format("invalid failure option ~s~n", [Opt]), usage()
            end;
        _ -> io:format("unknown option ~s~n", [Opt]), usage()
    end.

run(N, R, #{verbose := Verbose, failure := Failure}) ->
    Main = self(),
    Ids = lists:sort([pastry:id(node_name(I)) || I <- lists:seq(1, N)]),
    Gets = N * (R div 2),
    Stats = spawn_link(fun() -> stats(list_to_tuple(Ids), N * R, Gets, Main) end),
    io:format("Pastry: ~b nodes, ~b requests per node (b = 4, leaf set 16)~n", [N, R]),

    T0 = erlang:monotonic_time(millisecond),
    Peers = build(1, N, R, Stats, #{}, Verbose),
    T1 = erlang:monotonic_time(millisecond),
    io:format("Network built in ~b ms~n", [T1 - T0]),

    LivePeers = case Failure of
                        false -> Peers;
                        Mode -> inject_failures(Peers, Mode)
                    end,
    LiveIds = lists:sort([pastry:id(node_name(I)) || {I, Pid} <- maps:to_list(LivePeers),
                                                   is_process_alive(Pid)]),
    Stats ! {live_ids, lists:sort(LiveIds), R},
    Stats ! start,
    [Pid ! start || Pid <- maps:values(LivePeers), is_process_alive(Pid)],
    Summary = receive {stats_done, S} -> S end,
    T2 = erlang:monotonic_time(millisecond),
    report(length(LiveIds), R, Summary, T1 - T0, T2 - T1).

inject_failures(Peers, single) ->
    [{DeadId, DeadPid} | _] = maps:to_list(Peers),
    exit(DeadPid, kill),
    io:format("Failure test: stopped node ~b~n", [DeadId]),
    maps:remove(DeadId, Peers);
inject_failures(Peers, {nodes, Count}) when Count < map_size(Peers) ->
    stop_random_nodes(Peers, Count);
inject_failures(Peers, {nodes, Count}) ->
    io:format("failure=nodes:~b requires 1 <= N < numNodes (~b)~n",
              [Count, map_size(Peers)]),
    usage();
inject_failures(Peers, {percent, Percent}) ->
    Count = (map_size(Peers) * Percent + 99) div 100,
    stop_random_nodes(Peers, Count);
inject_failures(Peers, {edges, Percent}) ->
    block_random_edges(Peers, Percent, infinity);
inject_failures(Peers, {temporary_edges, Percent}) ->
    block_random_edges(Peers, Percent, 3000);
inject_failures(Peers, {combined, Percent}) ->
    Count = (map_size(Peers) * Percent + 99) div 100,
    LivePeers = stop_random_nodes(Peers, Count),
    block_random_edges(LivePeers, Percent, infinity);
inject_failures(Peers, permanent) ->
    [{SourceId, SourcePid}, {TargetId, TargetPid} | _] = maps:to_list(Peers),
    SourcePid ! {disconnect, TargetPid, infinity},
    io:format("Failure test: permanently blocked connection ~b -> ~b~n",
              [SourceId, TargetId]),
    Peers;
inject_failures(Peers, temporary) ->
    [{SourceId, SourcePid}, {TargetId, TargetPid} | _] = maps:to_list(Peers),
    SourcePid ! {disconnect, TargetPid, 3000},
    io:format("Failure test: temporarily blocked connection ~b -> ~b for 3000 ms~n",
              [SourceId, TargetId]),
    Peers;
inject_failures(Peers, multiple) ->
    Entries = maps:to_list(Peers),
    [{DeadId, DeadPid}, {SourceId, SourcePid}, {TempId, TempPid},
     {TargetId, TargetPid} | _] = Entries,
    exit(DeadPid, kill),
    SourcePid ! {disconnect, TempPid, infinity},
    TempPid ! {disconnect, TargetPid, 3000},
    io:format("Failure test: stopped node ~b; permanently blocked ~b -> ~b; "
              "temporarily blocked ~b -> ~b for 3000 ms~n",
              [DeadId, SourceId, TempId, TempId, TargetId]),
    maps:remove(DeadId, Peers);
inject_failures(Peers, combined) ->
    Entries = maps:to_list(Peers),
    case Entries of
        [{DeadId, DeadPid} | Rest] when Rest =/= [] ->
            exit(DeadPid, kill),
            [{SourceId, SourcePid} | More] = Rest,
            SourcePid ! {disconnect, DeadPid, infinity},
            case More of
                [{TempId, TempPid} | _] ->
                    TempPid ! {disconnect, SourcePid, 500},
                    io:format("Failure test: stopped node ~b; blocked connections from ~b permanently and ~b temporarily~n",
                              [DeadId, SourceId, TempId]);
                [] ->
                    io:format("Failure test: stopped node ~b; blocked connection from ~b permanently~n",
                              [DeadId, SourceId])
            end,
            maps:remove(DeadId, Peers);
        _ ->
            io:format("Failure test: requires at least 2 nodes; no node stopped~n"),
            Peers
    end.

stop_random_nodes(Peers, Count) ->
    Shuffled = rand:shuffle(maps:to_list(Peers)),
    {Dead, Live} = lists:split(Count, Shuffled),
    [exit(Pid, kill) || {_, Pid} <- Dead],
    DeadIndices = lists:sort([I || {I, _} <- Dead]),
    io:format("Failure test: randomly stopped ~b nodes (indices): ~p~n",
              [Count, DeadIndices]),
    maps:from_list(Live).

block_random_edges(Peers, Percent, Duration) ->
    LivePids = sets:from_list(maps:values(Peers)),
    Edges = lists:usort([{SourcePid, TargetPid} || SourcePid <- maps:values(Peers),
                                                    {_, TargetPid} <- pastry:known_peers(SourcePid),
                                                    TargetPid =/= SourcePid,
                                                    sets:is_element(TargetPid, LivePids)]),
    Failed = [{SourcePid, TargetPid} || {SourcePid, TargetPid} <- Edges,
                                        rand:uniform(100) =< Percent],
    [SourcePid ! {disconnect, TargetPid, Duration} ||
        {SourcePid, TargetPid} <- Failed],
    case Duration of
        infinity ->
            io:format("Failure test: randomly blocked ~b/~b directed overlay links permanently (~b%)~n",
                      [length(Failed), length(Edges), Percent]);
        Ms ->
            io:format("Failure test: randomly blocked ~b/~b directed overlay links temporarily for ~b ms (~b%)~n",
                      [length(Failed), length(Edges), Ms, Percent])
    end,
    Peers.

node_name(I) ->
    "node-" ++ integer_to_list(I).

%% Joins happen one at a time: pastry:init returns once the join is complete.
build(I, N, _, _, Peers, _) when I > N ->
    Peers;
build(I, N, R, Stats, Peers, Verbose) ->
    Bootstrap = case I of
                    1 -> none;
                    _ -> maps:get(rand:uniform(I - 1), Peers)
                end,
    {_, Pid} = pastry:init(node_name(I), {kvstore, {I, R, Stats}}, Bootstrap),
    Verbose andalso N >= 10 andalso I rem (N div 10) =:= 0
        andalso io:format(standard_error, "  ~b/~b joined~n", [I, N]),
    build(I + 1, N, R, Stats, Peers#{I => Pid}, Verbose).

report(N, R, S, BuildMs, RequestMs) ->
    #{delivered := Delivered, hops := Hops, hist := Hist, closest := Closest,
      gets := #{ok := GetOk, wrong := GetWrong, not_found := GetMissing},
      complete := Complete} = S,
    Avg = case Delivered of 0 -> 0.0; _ -> Hops / Delivered end,
    io:format("Requests: ~b/~b delivered in ~.1f s~s~n",
              [Delivered, N * R, RequestMs / 1000,
               case Complete of true -> ""; false -> " (stopped: no progress for 10 s)" end]),
    io:format("Average hops: ~.3f  (ceil(log16 N) = ~b)~n", [Avg, ceil_log16(N)]),
    io:format("Hop distribution:~s~n",
              [[io_lib:format("  ~b: ~b", [H, C]) || {H, C} <- lists:sort(maps:to_list(Hist))]]),
    io:format("Reached the numerically closest node: ~b/~b~n", [Closest, Delivered]),
    io:format("Gets: ~b ok, ~b wrong string, ~b not found~n", [GetOk, GetWrong, GetMissing]),
    io:format("RESULT,~b,~b,~.4f,~b,~b,~b,~b,~b,~b,~b,~b~n",
              [N, R, Avg, Delivered, N * R, Closest, GetOk, GetWrong, GetMissing,
               BuildMs, RequestMs]).

ceil_log16(N) -> ceil_log16(N, 1, 0).
ceil_log16(N, P, K) when P >= N -> K;
ceil_log16(N, P, K) -> ceil_log16(N, P * 16, K + 1).

%%% Stats actor

stats(Ids, Total, Gets, Main) ->
    S = #{ids => Ids, total => Total, expected_gets => Gets,
          delivered => 0, hops => 0, hist => #{}, closest => 0,
          gets => #{ok => 0, wrong => 0, not_found => 0}, got => 0},
    %% The stall timer only runs once the requests have started.
    receive
        {live_ids, LiveIds, Requests} ->
            receive start -> ok end,
            stats_loop(S#{ids := list_to_tuple(LiveIds),
                          total := length(LiveIds) * Requests,
                          expected_gets := length(LiveIds) * (Requests div 2)}, Main);
        start ->
            stats_loop(S, Main)
    end.

stats_loop(S = #{delivered := D, total := T, got := G, expected_gets := EG}, Main)
  when D >= T, G >= EG ->
    Main ! {stats_done, S#{complete => true}};
stats_loop(S, Main) ->
    receive
        {delivered, Key, NodeId, Hops} ->
            #{ids := Ids, delivered := D, hops := H, hist := Hist, closest := C} = S,
            Right = case closest(Key, Ids) of NodeId -> 1; _ -> 0 end,
            stats_loop(S#{delivered := D + 1, hops := H + Hops,
                          hist := maps:update_with(Hops, fun(X) -> X + 1 end, 1, Hist),
                          closest := C + Right}, Main);
        {get_result, Result} ->
            #{gets := Gets, got := G} = S,
            stats_loop(S#{gets := maps:update_with(Result, fun(X) -> X + 1 end, Gets),
                          got := G + 1}, Main)
    after ?STALL_MS ->
        Main ! {stats_done, S#{complete => false}}
    end.

%% The node whose id is numerically closest to Key, from the sorted ids.
closest(Key, Ids) ->
    N = tuple_size(Ids),
    I = lower_bound(Key, Ids, 1, N + 1),
    Succ = element(case I > N of true -> 1; false -> I end, Ids),
    Pred = element(case I =:= 1 of true -> N; false -> I - 1 end, Ids),
    {_, Id} = min({pastry:distance(Succ, Key), Succ}, {pastry:distance(Pred, Key), Pred}),
    Id.

lower_bound(_, _, Lo, Hi) when Lo >= Hi ->
    Lo;
lower_bound(Key, Ids, Lo, Hi) ->
    Mid = (Lo + Hi) div 2,
    case element(Mid, Ids) < Key of
        true -> lower_bound(Key, Ids, Mid + 1, Hi);
        false -> lower_bound(Key, Ids, Lo, Mid)
    end.
