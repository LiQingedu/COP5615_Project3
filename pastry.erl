-module(pastry).
%% Pastry peer (Rowstron and Druschel, Middleware 2001).
%%
%% Every peer is one Erlang process. It holds the Pastry state (leaf set and
%% routing table) and the state of the application running on top of it. The
%% application is a callback module implementing the application side of the
%% section 2.3 API: deliver, forward and newLeafs (here new_leafs).
%%
%% Ids are 128-bit integers read as 32 hex digits (b = 4) on a circular id
%% space. The leaf set holds the 8 numerically closest smaller and the 8
%% numerically closest larger nodeIds. The neighborhood set is left out: all
%% peers run on one machine, so there is no proximity metric to keep it by.

-export([init/3, route/2, id/1, digit/2, shl/2, distance/2]).

-define(DIGITS, 32).            % 128-bit ids, 4 bits per digit
-define(SPACE, (1 bsl 128)).
-define(HALF_LEAF, 8).          % |L| = 16
-define(JOIN_TIMEOUT, 60000).

%% Application API, called by Pastry inside the peer process.
-callback init(NodeId :: integer(), Args :: term()) -> AppState :: term().
%% deliver(msg, key), plus the number of hops the routing layer counted.
-callback deliver(Msg :: term(), Key :: integer(), Hops :: non_neg_integer(),
                  AppState :: term()) -> AppState :: term().
%% forward(msg, key, nextId): may change Msg or NextId; null ends the message here.
-callback forward(Msg :: term(), Key :: integer(), NextId :: integer(),
                  AppState :: term()) ->
    {Msg :: term(), NextId :: integer() | null, AppState :: term()}.
-callback new_leafs(LeafSet :: [{integer(), pid()}], AppState :: term()) ->
    AppState :: term().
%% Every message that is not Pastry's own goes to the application.
-callback handle_info(Info :: term(), AppState :: term()) -> AppState :: term().

%% Leaf set halves are lists of {Distance, Id, Pid}, closest first. lo holds
%% the nodes counterclockwise (smaller ids), hi the nodes clockwise. The
%% routing table maps {Row, Digit} to {Id, Pid}.
-record(st, {id, app, app_state, lo = [], hi = [], rt = #{},
             caller, pending = 0}).

%%% API

%% pastryInit: start a peer whose nodeId is the hash of Name, join the
%% network through the peer Bootstrap (none starts a new network) and return
%% {NodeId, Pid} once the join is complete. The paper's Credentials argument
%% is omitted because nothing here authenticates.
init(Name, {App, Args}, Bootstrap) ->
    Id = id(Name),
    Caller = self(),
    Pid = spawn(fun() -> start(Id, App, Args, Bootstrap, Caller) end),
    receive
        {joined, Pid} -> {Id, Pid}
    after ?JOIN_TIMEOUT ->
        error({join_timeout, Name})
    end.

%% route(msg, key): called by the application inside its peer.
route(Msg, Key) ->
    self() ! {route, Msg, Key, 0},
    ok.

%% 128-bit id of a name: used for nodeIds and for object keys.
id(Name) ->
    <<Id:128>> = erlang:md5(Name),
    Id.

%% Digit I (0 = most significant) of an id.
digit(Id, I) ->
    (Id bsr (4 * (?DIGITS - 1 - I))) band 15.

%% Length of the prefix (in digits) that two ids share.
shl(A, B) ->
    shl_digits(A bxor B, 0).

shl_digits(_, ?DIGITS) -> ?DIGITS;
shl_digits(X, I) ->
    case digit(X, I) of
        0 -> shl_digits(X, I + 1);
        _ -> I
    end.

%% Numerical distance on the circular id space.
distance(A, B) ->
    D = abs(A - B),
    min(D, ?SPACE - D).

%%% Peer process

start(Id, App, Args, Bootstrap, Caller) ->
    St = #st{id = Id, app = App, app_state = App:init(Id, Args), caller = Caller},
    case Bootstrap of
        none -> Caller ! {joined, self()};
        Pid -> Pid ! {join, {Id, self()}, []}
    end,
    loop(St).

loop(St) ->
    receive
        {route, Msg, Key, Hops} ->
            loop(route_msg(Msg, Key, Hops, St));
        {join, X, Path} ->
            loop(join_msg(X, Path, St));
        {join_reply, Path} ->
            loop(join_reply(Path, St));
        {announce, X = {_, XPid}, Known} ->
            XPid ! announce_ack,
            loop(insert_all([X | Known], St));
        announce_ack ->
            loop(announce_ack(St));
        Info ->
            #st{app = App, app_state = AS} = St,
            loop(St#st{app_state = App:handle_info(Info, AS)})
    end.

%%% Routing (figure 2 of the paper)

route_msg(Msg, Key, Hops, St = #st{app = App, app_state = AS}) ->
    case next_hop(Key, St) of
        self ->
            St#st{app_state = App:deliver(Msg, Key, Hops, AS)};
        {NextId, NextPid} ->
            case App:forward(Msg, Key, NextId, AS) of
                {_, null, AS2} ->
                    St#st{app_state = AS2};
                {Msg2, NextId2, AS2} ->
                    Pid = case NextId2 of
                              NextId -> NextPid;
                              _ -> pid_of(NextId2, NextPid, St)
                          end,
                    Pid ! {route, Msg2, Key, Hops + 1},
                    St#st{app_state = AS2}
            end
    end.

%% The next node for Key, or self when this node is the numerically closest.
next_hop(Key, #st{id = Key}) ->
    self;
next_hop(Key, St = #st{id = Me, rt = Rt}) ->
    case in_leaf_range(Key, St) of
        true ->
            closest_leaf(Key, St);
        false ->
            Row = shl(Key, Me),
            case maps:find({Row, digit(Key, Row)}, Rt) of
                {ok, Ref} -> Ref;
                error -> rare_case(Key, Row, St)
            end
    end.

%% A leaf set that is not full, or whose halves overlap, holds every other
%% node in the network.
in_leaf_range(_, #st{lo = Lo, hi = Hi})
  when length(Lo) < ?HALF_LEAF; length(Hi) < ?HALF_LEAF ->
    true;
in_leaf_range(Key, #st{id = Me, lo = Lo, hi = Hi}) ->
    Cw = (Key - Me + ?SPACE) rem ?SPACE,
    {FarHi, _, _} = lists:last(Hi),
    {FarLo, _, _} = lists:last(Lo),
    Cw =< FarHi orelse ?SPACE - Cw =< FarLo
        orelse lists:any(fun({_, Id, _}) -> lists:keymember(Id, 2, Hi) end, Lo).

closest_leaf(Key, #st{id = Me, lo = Lo, hi = Hi}) ->
    {_, _, Best} = lists:min([{distance(Me, Key), Me, self} |
                              [{distance(Id, Key), Id, {Id, Pid}}
                               || {_, Id, Pid} <- Lo ++ Hi]]),
    Best.

%% No routing table entry: any known node that shares at least as long a
%% prefix with Key and is numerically closer to it than this node.
rare_case(Key, Row, St = #st{id = Me}) ->
    MyDist = distance(Me, Key),
    case [{D, Id, {Id, Pid}} || {Id, Pid} <- known(St), shl(Id, Key) >= Row,
                                D <- [distance(Id, Key)], D < MyDist] of
        [] -> self;
        Candidates -> element(3, lists:min(Candidates))
    end.

pid_of(Id, Default, St) ->
    proplists:get_value(Id, known(St), Default).

%%% Join (section 2.4)

%% A join message for the new node X travels like a message routed to X's id.
%% Each node on the path adds its state to it, and the node numerically
%% closest to X sends the whole path's state back in one reply.
join_msg(X = {XId, XPid}, Path, St) ->
    Path2 = [[{St#st.id, self()} | known(St)] | Path],
    case next_hop(XId, St) of
        self -> XPid ! {join_reply, Path2};
        {_, Pid} -> Pid ! {join, X, Path2}
    end,
    St.

%% X builds its leaf set and routing table from every node on the path, then
%% sends its state to each node it now knows. The join is complete when all
%% of them have acknowledged.
join_reply(Path, St) ->
    St2 = insert_all(lists:append(Path), St),
    Known = known(St2),
    Me = {St2#st.id, self()},
    [Pid ! {announce, Me, Known} || {_, Pid} <- Known],
    St2#st{pending = length(Known)}.

announce_ack(St = #st{pending = 1, caller = Caller}) ->
    Caller ! {joined, self()},
    St#st{pending = 0};
announce_ack(St = #st{pending = P}) ->
    St#st{pending = P - 1}.

%%% State tables

insert_all(Refs, St0) ->
    St = lists:foldl(fun insert/2, St0, Refs),
    case St#st.lo =:= St0#st.lo andalso St#st.hi =:= St0#st.hi of
        true -> St;
        false ->
            #st{app = App, app_state = AS} = St,
            St#st{app_state = App:new_leafs(leaf_set(St), AS)}
    end.

insert({Me, _}, St = #st{id = Me}) ->
    St;
insert(Ref = {Id, Pid}, St = #st{id = Me, lo = Lo, hi = Hi, rt = Rt}) ->
    Cw = (Id - Me + ?SPACE) rem ?SPACE,
    Row = shl(Me, Id),
    Slot = {Row, digit(Id, Row)},
    Rt2 = case maps:is_key(Slot, Rt) of
              true -> Rt;
              false -> Rt#{Slot => Ref}
          end,
    St#st{hi = add_leaf(Cw, Id, Pid, Hi),
          lo = add_leaf(?SPACE - Cw, Id, Pid, Lo),
          rt = Rt2}.

add_leaf(D, Id, Pid, Leaves) when length(Leaves) < ?HALF_LEAF ->
    case lists:keymember(Id, 2, Leaves) of
        true -> Leaves;
        false -> lists:keysort(1, [{D, Id, Pid} | Leaves])
    end;
add_leaf(D, Id, Pid, Leaves) ->
    {Far, _, _} = lists:last(Leaves),
    case D < Far andalso not lists:keymember(Id, 2, Leaves) of
        true -> lists:droplast(lists:keysort(1, [{D, Id, Pid} | Leaves]));
        false -> Leaves
    end.

leaf_set(#st{lo = Lo, hi = Hi}) ->
    lists:usort([{Id, Pid} || {_, Id, Pid} <- Lo ++ Hi]).

%% Every node in the leaf set and routing table, each once.
known(#st{lo = Lo, hi = Hi, rt = Rt}) ->
    Leaves = maps:from_list([{Id, Pid} || {_, Id, Pid} <- Lo ++ Hi]),
    maps:to_list(maps:merge(Leaves, maps:from_list(maps:values(Rt)))).
