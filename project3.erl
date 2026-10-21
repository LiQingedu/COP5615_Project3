-module(project3).
%% COP5615 Project 3: the Pastry protocol with a simple key -> string store.
%%
%% Usage: escript project3 numNodes numRequests [verbose=true]
%%
%% The main process creates the peers one at a time; each joins through a
%% random peer that has already joined. Then every peer makes numRequests
%% requests, one per second. A stats actor collects the hop count of every
%% delivered request, checks that it reached the node numerically closest to
%% its key, and tells the main process when all requests are done.

-export([main/1, start/0]).

-define(STALL_MS, 10000).

start() ->
    main(init:get_plain_arguments()),
    halt().

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
    io:format("usage: project3 numNodes numRequests [verbose=true]~n"),
    halt(1).

options(Opts) ->
    lists:foldl(fun("verbose=true", O) -> O#{verbose => true};
                   (Opt, _) -> io:format("unknown option ~s~n", [Opt]), usage()
                end, #{verbose => false}, Opts).

run(N, R, #{verbose := Verbose}) ->
    Main = self(),
    Ids = lists:sort([pastry:id(node_name(I)) || I <- lists:seq(1, N)]),
    Gets = N * (R div 2),
    Stats = spawn_link(fun() -> stats(list_to_tuple(Ids), N * R, Gets, Main) end),
    io:format("Pastry: ~b nodes, ~b requests per node (b = 4, leaf set 16)~n", [N, R]),

    T0 = erlang:monotonic_time(millisecond),
    Peers = build(1, N, R, Stats, #{}, Verbose),
    T1 = erlang:monotonic_time(millisecond),
    io:format("Network built in ~b ms~n", [T1 - T0]),

    Stats ! start,
    [Pid ! start || Pid <- maps:values(Peers)],
    Summary = receive {stats_done, S} -> S end,
    T2 = erlang:monotonic_time(millisecond),
    report(N, R, Summary, T1 - T0, T2 - T1).

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
    receive start -> ok end,
    stats_loop(S, Main).

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
