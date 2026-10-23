# COP5615_Project3

- Yingzhu Chen 83945095
- Qing Li 16912349

## Build and Run
Requires Erlang/OTP 25 or newer (we use OTP 29).

```bash
erl -make
./project3 numNodes numRequests
```

`project3` is an executable escript with a `#!/usr/bin/env escript` shebang;
`escript ./project3 numNodes numRequests` is equivalent. The bare command
`project3 numNodes numRequests` works when the current directory is on `PATH`.
`erl -make` compiles `pastry.erl` before `kvstore.erl`, which uses it as a
behaviour. Add `verbose=true` to print join progress to stderr. Without the
escript wrapper:

```bash
erl -noshell +P 4000000 -pa . -s project3 start -extra 1000 10
erl -noshell +P 4000000 -pa . -s project3 start 1000 10
```

Both `-extra` arguments (read by `init:get_plain_arguments/0`) and direct
arguments (passed by `-s` to `start/1`) are supported. The `./` is needed when
running an executable in the current directory because shells do not search
the current directory by default.

## What Is Working

- Pastry peers are modeled as Erlang actors, with one process per peer.
- Nodes join through an existing peer and initialize leaf sets and routing tables.
- Routing follows the Pastry leaf-set, routing-table, and rare-case rules.
- In normal mode, messages are delivered to the numerically closest node for
  the key.
- The key-value application implements put and get operations for 128-bit keys.
- Each peer sends about one request per second, with a randomized delay before
  its first request.
- The program reports average hops, hop distribution, delivery correctness, and
  get correctness.

The neighborhood set is omitted because all simulated peers run on one machine
and the project does not define a proximity metric. The optional failure-model
work and its results are documented separately in
[BONUS-REPORT.md](./BONUS-REPORT.md).

Failure experiments can randomly stop nodes, block directed overlay links, or
combine both. For example, `failure=percent:30` stops 30% of nodes,
`failure=edges:30` blocks 30% of known directed overlay links, and
`failure=temporary-edges:30` temporarily blocks 30% of known links for 3 seconds;
`failure=combined-percent:30` applies both. The report includes 10,000-node
results for these failure types at 10%, 20%, 30%, 40%, and 50%. See
[BONUS-REPORT.md](./BONUS-REPORT.md) for commands and captured output.

## Largest Network Tested

The largest successful test used 100,000 Pastry nodes and 5 requests per node,
for 500,000 total requests:

- 500,000 / 500,000 requests delivered
- 500,000 / 500,000 requests reached the numerically closest node
- 200,000 / 200,000 gets returned the correct string
- Average hops: 3.9596

The captured output is preserved in
[results/run-100000.txt](./results/run-100000.txt). To reproduce this
measurement on a machine with sufficient memory and process limits:

```bash
erl -make
escript ./project3 100000 5
```

The final `RESULT` line has the machine-dependent build and request timings;
the delivery, closest-node, get-correctness, and hop statistics are the
correctness measurements.

## Hop-Count and API Semantics

- `route/2` creates a request with `Hops = 0`.
- A local `deliver` therefore records 0 hops.
- Each peer-to-peer route message increments `Hops` exactly once before it is
  sent to the next peer.
- The average is `total_hops / delivered_requests`, including locally
  delivered requests.
- A get response is sent directly from `deliver/4` to the requester PID. It
  does not traverse Pastry and is intentionally excluded from the hop count.
- `forward/4` is called immediately before every peer-to-peer forward. If the
  callback returns `null`, `route_msg/4` stops the request at the current peer
  and does not send another route message.
- `new_leafs/2` is called by `insert_all/2` whenever the local leaf-set
  contents change.
- Requests are not started until `build/6` has completed every join. Each
  `pastry:init/3` returns only after the joining peer has received all
  announce acknowledgements, so leaf-set and routing-state initialization
  precedes workload generation.

## Files
| File | What it is |
| --- | --- |
| `pastry.erl` | The Pastry peer actor: join, routing, leaf set, routing table, and the application API as a behaviour |
| `kvstore.erl` | The application: key → string store and the request workload |
| `project3.erl` | Main process (builds the network, prints the results) and the stats actor |
| `project3` | escript wrapper so the program runs as `escript project3 ...` |

---

## The API at a glance

| Call | Direction | §2.3 definition |
|---|---|---|
| `nodeId = pastryInit(Credentials, Application)` | app → Pastry | join an existing network (or start one), initialize state, return nodeId |
| `route(msg, key)` | app → Pastry | route msg to the live node whose nodeId is numerically closest to key |
| `deliver(msg, key)` | Pastry → app | called at the node numerically closest to key |
| `forward(msg, key, nextId)` | Pastry → app | called just before forwarding; app may change msg or nextId; nextId = NULL ends the message here |
| `newLeafs(leafSet)` | Pastry → app | called whenever the local leaf set changes |

### 1. Layer Boundary in Erlang

The implementation separates the Pastry routing layer from the application layer using a callback module. `pastry.erl` manages peer initialization, routing, the leaf set, and the routing table. It defines the application callbacks `deliver/4`, `forward/4`, and `new_leafs/2`, as well as `init/2` and `handle_info/2` for application initialization and message handling.

`kvstore.erl` implements these callbacks and invokes `pastry:route/2` to send requests. The key-value map is stored in the peer's state and passed between the routing layer and application callbacks. Each peer runs in a single Erlang process, and all five application interface functions are explicitly defined.

### 2. `pastryInit(Credentials, Application)`

The implementation uses `pastry:init(Name, {App, Args}, Bootstrap)`. The `Credentials` parameter is omitted because the project does not require authentication. If `Bootstrap = none`, the node starts a new network; otherwise, it joins through an existing peer.

Each node's ID is the MD5 hash of its name, such as `node-<i>`, represented as a 128-bit value. The function returns `{NodeId, Pid}` after the join completes.

Nodes join sequentially. The new node routes a join message using its node ID as the key. Each peer along the path appends its routing table and leaf set to the message. The numerically closest peer returns the collected information in a single reply. The new node merges the discovered information, then sends its state to peers in its routing table and leaf set. The join completes after all acknowledgements arrive.

The implementation uses 128-bit IDs, a base of 16 (`b = 4`), and a leaf set of 16 nodes, with eight smaller and eight larger IDs. The ID space is circular. The neighborhood set is omitted because all peers run on the same machine. When multiple nodes fit the same routing-table slot, the first discovered node is retained.

### 3. `route(msg, key)`

The routing layer forwards each message toward the live node whose ID is numerically closest to the key. Within a peer, `route` is called directly; communication between peers uses messages of the form `{route, Msg, Key, Hops}`.

Each message contains the request type (`put` or `get`), key, value when applicable, requester's PID, and request number. The routing layer increments the hop count for each forward.

For `get` requests, `deliver` sends the result directly to the requester's PID. The response does not pass through Pastry routing and is excluded from hop-count statistics.

### 4. `deliver(msg, key)`

The application callback handles requests at the destination peer. A `put` request stores the key-value pair, while a `get` request retrieves the stored value and returns it to the requester. Each delivery reports its hop count and destination node ID to the statistics actor.

Each peer's first request is a `put`, followed by alternating `get` and `put` requests. Every `get` targets a key previously stored by the same peer, allowing the requester to verify the returned value. Put keys are generated by hashing their strings with MD5, placing keys and node IDs in the same identifier space.

Local deliveries are counted with zero hops. The statistics actor records all deliveries and verifies their destinations.

### 5. `forward(msg, key, nextId)`

The `kvstore:forward` callback returns the message and `nextId` unchanged. Pastry invokes it before each forwarding operation. If the callback returns `null` as the next hop, the message terminates at the local peer. Hop counting remains the responsibility of the routing layer.

### 6. `newLeafs(leafSet)`

The `kvstore:new_leafs` callback is a no-op because the key-value application has no leaf-set-dependent invariants. Pastry invokes it whenever the local leaf set changes, keeping the application interface complete.

## Experimental Results

The following results were obtained from actual runs of the implementation.
All results in this section are from the normal, no-failure mode.

| Nodes | Requests per node | Total requests | Delivered | Average hops | Closest node | Gets |
|---:|---:|---:|---:|---:|---:|---:|
| 4 | 2 | 8 | 8/8 | 0.7500 | 8/8 | 4/4 |
| 12 | 4 | 48 | 48/48 | 0.9583 | 48/48 | 24/24 |
| 100,000 | 5 | 500,000 | 500,000/500,000 | 3.9596 | 500,000/500,000 | 200,000/200,000 |

For the 100,000-node run, the hop distribution was:

```text
1: 338
2: 7,920
3: 83,520
4: 328,070
5: 80,152
```

The complete captured output for the largest run is available in
[results/run-100000.txt](./results/run-100000.txt). It can be reproduced with:

```bash
erl -make
escript ./project3 100000 5
```

The reported average is calculated over all delivered requests, including
local deliveries with zero hops. The get response is sent directly to the
requester PID and is not included as an additional Pastry hop.
