# COP5615_Project3
Implement in Erlang using the actor model the Pastry protocol and a simple object access service to prove its usefulness.

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

## 2. `pastryInit(Credentials, Application)`

- **§2.3:** joins an existing network "(or start a new one)", initializes state, returns the nodeId (p.6).
- **Open:**
  - **Bootstrap:** the signature has no argument for *which* existing node to contact, yet a join needs one.
  - **Credentials:** "application-specific … needed to authenticate". Nothing in the project needs them.
  - **Start new vs. join:** how does a node know it's the first?
  - **Return:** in an actor, "returns nodeId" could mean a reply message, the spawn result, or the nodeId being chosen before spawning.
  - **When it returns:** at once, or only when the join is complete? This matters if requests must wait for the join.
- **Decide:** what your init looks like, and whether you state that `Credentials` is omitted.

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

## 4. `deliver(msg, key)`

- **§2.3:** called "when a message is received and the local node's nodeId is numerically closest to key, among all live nodes" (p.7).
- **Open:**
  - This is where the key → string store does its put or get. What does each request kind do here?
  - A get for a key that was never stored returns not found. Is that a valid request, or does your workload only get keys known to exist?
  - A key owned by the requester itself is delivered locally (0 hops). Is it counted?
- **Decide:** what your app does in deliver, and what (if anything) it reports to whoever computes the average.

## 5. `forward(msg, key, nextId)`

- **§2.3:** called "just before a message is forwarded"; the app "may change the contents of the message or the value of nextId"; setting nextId to NULL "terminates the message at the local node" (p.7).
- **Open:** the paper's applications use it (e.g. SCRIBE records subscriptions along the path, p.2–3), but a key → string store doesn't need to change anything.
- **Options:** a no-op that just returns (msg, nextId) · increment a hop counter inside msg (if so, hop counting becomes an app concern, not Pastry's) · cache values along the path (a PAST-style idea, beyond scope).
- **Decide:** implement it even if trivial, so the API is complete? And should the hop count live in forward or in the routing layer?

## 6. `newLeafs(leafSet)`

- **§2.3:** called "whenever there is a change in the local node's leaf set", so the app can "adjust application-specific invariants" (p.7).
- **Open:** a single-copy key → string store has no invariant to maintain. This only matters if you replicate values on the closest nodes (the fault-tolerance bonus: values on a node that leaves must survive).
- **Decide:** no-op for the required project? Do you still call it from the Pastry layer, so the API is complete?
