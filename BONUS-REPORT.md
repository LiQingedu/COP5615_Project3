# Pastry Failure-Model Bonus Report

## Failure models

The test program supports random peer exits, random directed overlay-link
failures, temporary link failures, and combined peer and link failures. Node
failures stop peer processes after all nodes have joined but before requests
begin. Link failures are chosen from actual directed neighbors in the peers'
routing tables and leaf sets. Temporary link failures are blocked for 3,000 ms
and become usable again after that timeout. In combined runs, nodes are stopped
first, then links are sampled from the remaining live overlay.

Use these options:

```bash
escript ./project3 10000 2 failure=percent:30
escript ./project3 10000 2 failure=edges:30
escript ./project3 10000 5 failure=temporary-edges:30
escript ./project3 10000 2 failure=combined-percent:30
```

Each percentage is sampled independently. A node percentage stops
`ceil(P × numNodes / 100)` peers. An edge percentage independently blocks each
directed live overlay link with probability P%. The program prints the number
of blocked links and the total eligible links. Permanent node, link, and
combined tests used 10,000 nodes and 2 requests per surviving node. Temporary
link tests used 10,000 nodes and 5 requests per node so requests continued
after the 3,000 ms block expired. One random draw was run for each failure
percentage; these are individual runs, not averages over repeated seeds.

The average hop count starts at zero, adds one for each peer-to-peer forward,
and includes local deliveries. Get replies go directly to the requester and
are not counted as Pastry hops. “Closest” compares each destination with the
numerically closest live node after failure injection. Delivery and closest
are separate measures: a request can be delivered to a live node that is not
the closest live node.

## Results

| Failure model | Failure rate | Nodes stopped | Directed links blocked | Delivered | Closest live node | Avg. hops | Gets correct |
|---|---:|---:|---:|---:|---:|---:|---:|
| Nodes | 10% | 1,000 | — | 18,000/18,000 | 18,000/18,000 | 3.205 | 9,000/9,000 |
| Nodes | 20% | 2,000 | — | 16,000/16,000 | 16,000/16,000 | 3.205 | 8,000/8,000 |
| Nodes | 30% | 3,000 | — | 14,000/14,000 | 14,000/14,000 | 3.206 | 7,000/7,000 |
| Nodes | 40% | 4,000 | — | 12,000/12,000 | 12,000/12,000 | 3.210 | 6,000/6,000 |
| Nodes | 50% | 5,000 | — | 10,000/10,000 | 10,000/10,000 | 3.273 | 5,000/5,000 |
| Links | 10% | — | 54,956/549,381 | 20,000/20,000 | 19,524/20,000 | 3.475 | 10,000/10,000 |
| Links | 20% | — | 110,195/549,376 | 20,000/20,000 | 18,696/20,000 | 3.712 | 10,000/10,000 |
| Links | 30% | — | 165,108/549,376 | 20,000/20,000 | 18,012/20,000 | 4.003 | 10,000/10,000 |
| Links | 40% | — | 219,593/549,376 | 20,000/20,000 | 16,712/20,000 | 4.386 | 10,000/10,000 |
| Links | 50% | — | 274,526/549,376 | 20,000/20,000 | 15,236/20,000 | 4.914 | 10,000/10,000 |
| Nodes + links | 10% | 1,000 | 43,789/440,456 | 18,000/18,000 | 17,626/18,000 | 3.805 | 9,000/9,000 |
| Nodes + links | 20% | 2,000 | 73,451/366,724 | 16,000/16,000 | 14,994/16,000 | 4.030 | 8,000/8,000 |
| Nodes + links | 30% | 3,000 | 79,517/264,720 | 14,000/14,000 | 12,436/14,000 | 5.149 | 7,000/7,000 |
| Nodes + links | 40% | 4,000 | 78,897/196,830 | 12,000/12,000 | 9,704/12,000 | 6.201 | 6,000/6,000 |
| Nodes + links | 50% | 5,000 | 61,806/123,417 | 10,000/10,000 | 5,956/10,000 | 8.253 | 5,000/5,000 |

Temporary links were sampled independently at each rate and restored after 3
seconds. These runs used 5 requests per node (50,000 total requests, including
20,000 gets):

| Failure model | Failure rate | Directed links temporarily blocked | Delivered | Closest live node | Avg. hops | Gets correct |
|---|---:|---:|---:|---:|---:|---:|
| Temporary links (3 s) | 10% | 55,009/549,379 | 50,000/50,000 | 49,400/50,000 | 3.365 | 19,793/20,000 |
| Temporary links (3 s) | 20% | 110,278/549,378 | 50,000/50,000 | 48,265/50,000 | 3.530 | 19,439/20,000 |
| Temporary links (3 s) | 30% | 165,975/549,376 | 50,000/50,000 | 46,831/50,000 | 3.707 | 18,941/20,000 |
| Temporary links (3 s) | 40% | 219,751/549,376 | 50,000/50,000 | 45,100/50,000 | 3.923 | 18,386/20,000 |
| Temporary links (3 s) | 50% | 275,103/549,371 | 50,000/50,000 | 42,764/50,000 | 11.040 | 17,652/20,000 |

All 20 runs delivered every request. Node exits alone preserved closest-node
delivery in these runs. Permanent link failures reduced closest-node accuracy
as their rate increased. Combined failures further increased routing cost: at
50% node loss and 50% link failure, the average was 8.253 hops, and 5,956 of
10,000 requests reached the closest live node.

Temporary links became usable again after 3 seconds, and the workload continued
after that point. However, get correctness fell as more links were temporarily
blocked. A put routed during an outage can be stored at a live node that is not
the key's closest node; after the link recovers, a later get may route to the
closest node and not find that copy. At 50% temporary link failures, all
requests were delivered but 2,348 of 20,000 gets returned not found. 

## Captured output

Each run's full output, including the randomly selected node indices or the
number of blocked links, is saved here:

- Node exits: [10%](./results/bonus-nodes-10-percent.txt), [20%](./results/bonus-nodes-20-percent.txt), [30%](./results/bonus-nodes-30-percent.txt), [40%](./results/bonus-nodes-40-percent.txt), [50%](./results/bonus-nodes-50-percent.txt).
- Link failures: [10%](./results/bonus-edges-10-percent.txt), [20%](./results/bonus-edges-20-percent.txt), [30%](./results/bonus-edges-30-percent.txt), [40%](./results/bonus-edges-40-percent.txt), [50%](./results/bonus-edges-50-percent.txt).
- Temporary links: [10%](./results/bonus-temporary-edges-10-percent.txt), [20%](./results/bonus-temporary-edges-20-percent.txt), [30%](./results/bonus-temporary-edges-30-percent.txt), [40%](./results/bonus-temporary-edges-40-percent.txt), [50%](./results/bonus-temporary-edges-50-percent.txt).
- Combined failures: [10%](./results/bonus-combined-10-percent.txt), [20%](./results/bonus-combined-20-percent.txt), [30%](./results/bonus-combined-30-percent.txt), [40%](./results/bonus-combined-40-percent.txt), [50%](./results/bonus-combined-50-percent.txt).
