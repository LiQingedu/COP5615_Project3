# COP5615_Project3
Implement in Erlang using the actor model the Pastry protocol and a simple object access service to prove its usefulness.

## Build and Run
Requires Erlang/OTP 25 or newer (we use OTP 29).

```bash
erl -make
escript project3 numNodes numRequests
```

`erl -make` compiles `pastry.erl` before `kvstore.erl`, which uses it as a behaviour. Add `verbose=true` to print join progress to stderr. Without the escript wrapper:

```bash
erl -noshell +P 4000000 -pa . -s project3 start -extra 1000 10
```

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

---

## 1. The layer boundary in Erlang

- **§2.3:** Pastry and the application are separate layers. `Application` is "a handle to the application object that provides the Pastry node with the procedures to invoke" (p.6).
- **Open:** the handout says one actor per peer, so both layers live in the same Erlang process. There is no "object".
- **Options:**
  - a callback module (the Pastry loop calls `App:deliver/…`, `App:forward/…`, `App:newLeafs/…`, like a behaviour);
  - app state held as a field that the Pastry loop passes to plain functions;
  - a second actor per peer for the app. Does that break "one actor for each peer"?
- **Decide:** how would a grader reading your code *see* the five §2.3 calls? Who owns the app state (the key → string map)?
- **Decision:** a callback module. `pastry.erl` is the peer actor (join, routing, leaf set, routing table) and declares `deliver/4`, `forward/4` and `new_leafs/2` as a behaviour, plus `init/2` and `handle_info/2` for the application's own setup and messages. `deliver` gets the hop count the routing layer measured as an extra argument. `kvstore.erl` is the application and implements them, and it calls `pastry:route/2` from inside its peer. The key → string map is a field of the peer's state that Pastry passes into each callback and takes back out. One process per peer, and all five calls appear by name.

## 2. `pastryInit(Credentials, Application)`

- **§2.3:** joins an existing network "(or start a new one)", initializes state, returns the nodeId (p.6).
- **Open:**
  - **Bootstrap:** the signature has no argument for *which* existing node to contact, yet a join needs one.
  - **Credentials:** "application-specific … needed to authenticate". Nothing in the project needs them.
  - **Start new vs. join:** how does a node know it's the first?
  - **Return:** in an actor, "returns nodeId" could mean a reply message, the spawn result, or the nodeId being chosen before spawning.
  - **When it returns:** at once, or only when the join is complete? This matters if requests must wait for the join.
- **Decide:** what your init looks like, and whether you state that `Credentials` is omitted.
- **Decision:** `pastry:init(Name, {App, Args}, Bootstrap)` with `Credentials` omitted (nothing in the project authenticates). `Bootstrap = none` starts a new network; otherwise it is the pid of a random node that already joined (there is no proximity metric to pick a nearby one). The nodeId is the MD5 hash of `Name` (`node-<i>`), chosen before spawning, and the call returns `{NodeId, Pid}` only after the join is complete.
- **Join procedure:**
  - Nodes join one at a time: main starts the next node only after the previous one reports that it joined. Joins never overlap, so the paper's timestamp scheme for concurrent arrivals is not needed.
  - The join message is routed with the new node's id as key. Every node on the path appends its routing table and leaf set to the message, and the node numerically closest to the new id sends all of it back in one reply. Erlang does not order messages from different senders, so separate replies would leave the new node unsure when it had heard from the whole path.
  - The new node adds every node it learned about. This covers the paper's rule (row i from the i-th node on the path, leaf set from the last node).
  - The new node sends its state to every node in its leaf set and routing table. They add it and acknowledge, and the join is complete when every acknowledgement is in.
- **Parameters:** 128-bit ids read as 32 hex digits (b = 4) and a leaf set of 16 (8 smaller, 8 larger), as in the paper's experiments. The id space is circular. The neighborhood set is left out: every peer runs on one machine, so there is no network distance, and the paper uses that set only for locality. When two nodes fit the same routing-table slot, the first one seen keeps it.

## 3. `route(msg, key)`

- **§2.3:** route to the node with nodeId numerically closest to key, "among all live Pastry nodes" (p.6).
- **Open:**
  - **No return value.** It's one-way, so the paper's API has no way for a lookup to get its string back.
  - **Who calls it.** In your design the peer calls it on itself, so is it a function call inside the actor or a message to self?
  - **Message format.** The handout lets you change "the message type". What does a msg carry (request kind, string, requester, hop count)?
- **Decide:** how a get request returns its value:
  - deliver sends a direct reply to the requester (outside Pastry);
  - the reply is itself routed with `route(reply, requesterId)`;
  - fire-and-forget, where nobody gets an answer.

  Whichever you pick, does the reply count toward the average hops the handout asks you to print?
- **Decision:**
  - Inside a peer, `route` is a function call; between peers the message is `{route, Msg, Key, Hops}`. Msg carries the request kind (put or get), the key, the string for a put, the requester's pid and the request number.
  - `deliver` sends a get's answer straight to the requester's pid, outside Pastry. The answer is not routed, so it does not count toward the hops.
  - The routing layer adds one hop per forward.

## 4. `deliver(msg, key)`

- **§2.3:** called "when a message is received and the local node's nodeId is numerically closest to key, among all live nodes" (p.7).
- **Open:**
  - This is where the key → string store does its put or get. What does each request kind do here?
  - A get for a key that was never stored returns not found. Is that a valid request, or does your workload only get keys known to exist?
  - A key owned by the requester itself is delivered locally (0 hops). Is it counted?
- **Decide:** what your app does in deliver, and what (if anything) it reports to whoever computes the average.
- **Decision:**
  - A put stores the string; a get looks it up and replies to the requester. Every delivery reports its hop count and the node it reached to the stats actor.
  - Each peer's first request is a put, then it alternates get and put. A get asks for a random key that the same peer stored earlier, so every get must return exactly the string that was put, and the requester checks that.
  - A put's key is the MD5 hash of its string (for example `peer17-obj3`), so keys and nodeIds share one space.
  - A key owned by the requester is delivered locally with 0 hops and is counted. This happens for about one request in N.

## 5. `forward(msg, key, nextId)`

- **§2.3:** called "just before a message is forwarded"; the app "may change the contents of the message or the value of nextId"; setting nextId to NULL "terminates the message at the local node" (p.7).
- **Open:** the paper's applications use it (e.g. SCRIBE records subscriptions along the path, p.2–3), but a key → string store doesn't need to change anything.
- **Options:** a no-op that just returns (msg, nextId) · increment a hop counter inside msg (if so, hop counting becomes an app concern, not Pastry's) · cache values along the path (a PAST-style idea, beyond scope).
- **Decide:** implement it even if trivial, so the API is complete? And should the hop count live in forward or in the routing layer?
- **Decision:** `kvstore:forward` returns the message and nextId unchanged, but Pastry calls it before every forward and stops the message at the local node if it returns `null`. Hop counting stays in the routing layer.

## 6. `newLeafs(leafSet)`

- **§2.3:** called "whenever there is a change in the local node's leaf set", so the app can "adjust application-specific invariants" (p.7).
- **Open:** a single-copy key → string store has no invariant to maintain. This only matters if you replicate values on the closest nodes (the fault-tolerance bonus: values on a node that leaves must survive).
- **Decide:** no-op for the required project? Do you still call it from the Pastry layer, so the API is complete?
- **Decision:** `kvstore:new_leafs` does nothing, but Pastry calls it every time the leaf set changes.

## 7. Running the requests

- **Decision:**
  - Main builds the whole network first, then starts the requests. Each peer sends its first request at a random moment in the first second and one per second after that, `numRequests` in total.
  - A stats actor collects each delivery's hop count and each get result. When `numNodes × numRequests` requests have been delivered and every get has been answered, it tells main, which prints the results and exits.
  - The stats actor knows every nodeId and checks that each request reached the node numerically closest to its key.
  - Output: average hops, ⌈log₁₆ N⌉ for comparison, the hop distribution, how many requests reached the right node, how many gets returned the right string, and a `RESULT,...` line for scripts.
