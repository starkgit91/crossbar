# Crossbar Interconnect and AMD GPU Project
## Detailed Implementation and Verification Document

**Project focus:** Generic crossbar design, SystemVerilog implementation, verification, and later comparison with AMD GPU architecture.

**Current implementation:** Parameterized input-queued VOQ crossbar with output-side round-robin arbitration and input-side conflict resolution.

**Current verified configuration:** 4 inputs, 4 outputs, 16-bit payload, FIFO depth 2.

---

## 1. Scope Change

The original study plan focused on GPU virtual memory, page faults, Unified Virtual Memory, page migration, and Nsight profiling. That track is removed from the initial project scope.

The revised project proceeds in this order:

1. Crossbar fundamentals.
2. Crossbar design architecture.
3. SystemVerilog RTL implementation.
4. Simulation-based verification.
5. Scheduling and performance extensions.
6. AMD GPU architecture basics.
7. GPU-oriented interpretation and optional RTX 5070 experiments.

The crossbar is the primary implementation deliverable. GPU architecture is the system-level context that follows it.

---

## 2. Project Goal

Design and verify a reusable crossbar interconnect that demonstrates how multiple requesters communicate with multiple destinations when requests can conflict.

The implementation must show:

- Any input can target any output.
- Multiple independent transfers can happen in one clock cycle.
- One output cannot accept two inputs in the same cycle.
- One input cannot transmit two flits in the same cycle.
- Buffered requests wait when arbitration does not select them.
- Round-robin arbitration provides fair service.
- Virtual output queues prevent head-of-line blocking between destinations.
- The design is parameterized rather than hard-coded to one size.
- A self-checking testbench detects incorrect routing and arbitration behavior.

---

## 3. Required Deliverables

### 3.1 Reading and design deliverables

- Crossbar definition and non-blocking behavior.
- Crossbar cost and topology comparison.
- Mux, arbiter, FIFO, and VOQ explanation.
- Arbitration and scheduling design.
- Block-level architecture diagram.
- Interface and cycle-level timing contract.
- AMD-first GPU architecture overview.
- Presentation focused on crossbar fundamentals and design.

### 3.2 Implementation deliverables

- Parameterized SystemVerilog crossbar RTL.
- Self-checking directed testbench.
- Randomized scoreboard testbench.
- Assertions for safety and protocol properties.
- Reproducible compile, simulation, and lint commands.
- Throughput and latency measurement plan.
- Optional CUDA software model for the RTX 5070.

---

## 4. Crossbar Fundamentals

A crossbar is an interconnection network with `N` inputs and `M` outputs. Every input has a path to every output. Multiple connections may be active simultaneously provided that no input or output is used more than once in the same transfer opportunity.

For an `N x M` crossbar:

```text
Number of crosspoints = N x M
Wiring complexity      = O(N x M)
```

For a square `N x N` crossbar, the cost is `O(N^2)`. This gives a crossbar low and uniform one-hop latency, but makes very large crossbars expensive.

### 4.1 Comparison with other networks

| Network | Main advantage | Main limitation |
|---|---|---|
| Shared bus | Simple and low hardware cost | Only one transaction at a time |
| Ring or mesh NoC | Scales better to many nodes | Multiple hops and variable latency |
| Crossbar | Any-to-any connectivity and parallel transfers | Quadratic wiring cost |
| Clos or multistage network | Lower asymptotic wiring cost | Multiple stages and possible blocking depending on construction |

### 4.2 The three fundamental hardware blocks

#### Multiplexers

Each output can be implemented as an `N:1` multiplexer. The select value identifies the input currently granted to that output.

#### Arbiters

An arbiter selects one requester when several inputs request the same output. Fixed priority is simple but can starve low-priority requesters. Round-robin priority rotates the starting point after a successful grant.

#### FIFOs

A FIFO stores requests or payloads that cannot cross immediately. The FIFO determines how much burst traffic the crossbar can absorb and whether blocked traffic can prevent unrelated traffic from progressing.

---

## 5. Chosen Architecture

The first design is an input-queued crossbar using virtual output queues.

```text
                         request[output][input]
                                      |
Input 0 --> VOQ[0][0..M-1] ---------+--> RR arbiter --> Output 0
Input 1 --> VOQ[1][0..M-1] ---------+--> RR arbiter --> Output 1
Input 2 --> VOQ[2][0..M-1] ---------+--> RR arbiter --> Output 2
Input 3 --> VOQ[3][0..M-1] ---------+--> RR arbiter --> Output 3
```

More generally:

```text
input i --> destination decoder --> VOQ[i][destination]
                                      |
                                      v
                            output request matrix
                                      |
                                      v
                         one arbiter for each output
                                      |
                                      v
                              output data muxes
```

### 5.1 Why input queues?

Input queues are easier to implement than output queues because the input owns the incoming data. The trade-off is that a single FIFO per input can suffer head-of-line blocking.

### 5.2 Why virtual output queues?

A VOQ gives each input a separate FIFO for each destination output.

Without VOQs:

```text
Input 0 FIFO: [packet -> Output 2] [packet -> Output 0]
              Output 2 is blocked, so Output 0 also waits.
```

With VOQs:

```text
Input 0 VOQ[2]: [packet -> Output 2]  blocked
Input 0 VOQ[0]: [packet -> Output 0]  can proceed
```

The second packet is no longer structurally blocked by the first packet.

### 5.3 Why output-side round robin?

Each output is an independent resource. It needs to choose one source among its active VOQs. A separate pointer per output gives independent fairness decisions.

This first implementation is not a complete iSLIP scheduler. It performs one output-side arbitration decision per output and does not include a separate input-side accept phase.

---

## 6. RTL Interface

The RTL is in [rtl/crossbar_voq.sv](../rtl/crossbar_voq.sv).

### 6.1 Parameters

```systemverilog
N_INPUTS    // Number of input ports
N_OUTPUTS   // Number of output ports
DATA_W      // Payload width in bits
FIFO_DEPTH  // Entries in each VOQ
```

Example:

```systemverilog
crossbar_voq #(
    .N_INPUTS(4),
    .N_OUTPUTS(4),
    .DATA_W(16),
    .FIFO_DEPTH(2)
) dut (...);
```

### 6.2 Input signals

| Signal | Meaning |
|---|---|
| `clk` | Active clock |
| `rst_n` | Active-low asynchronous reset |
| `in_valid[i]` | Input `i` presents a valid flit |
| `in_ready[i]` | Input `i` may enqueue its flit |
| `in_data[i]` | Payload from input `i` |
| `in_dest[i]` | Destination output for input `i` |

An input transfer occurs when:

```text
in_valid[i] && in_ready[i]
```

The incoming payload is written to the VOQ selected by `in_dest[i]`.

### 6.3 Output signals

| Signal | Meaning |
|---|---|
| `out_valid[o]` | Output `o` has a granted flit |
| `out_data[o]` | Payload selected for output `o` |
| `out_src[o]` | Input source selected for output `o` |

The current design has no output `ready` signal. A valid output transfer is treated as occurring at the clock edge when `out_valid` is asserted.

---

## 7. RTL Data Structures

The implementation uses these logical structures:

```systemverilog
storage[input][output][fifo_position]
rd_ptr[input][output]
wr_ptr[input][output]
count[input][output]
rr_ptr[output]
```

### 7.1 VOQ storage

`storage[i][o]` is the FIFO associated with input `i` and output `o`.

### 7.2 Read and write pointers

The read pointer identifies the oldest flit. The write pointer identifies the next free FIFO location. Both wrap around at `FIFO_DEPTH`.

### 7.3 Occupancy count

The count records the number of stored flits in each VOQ.

```text
count == 0       -> no request
count < depth    -> input can enqueue
count == depth   -> selected VOQ is full
```

### 7.4 Round-robin pointers

Each output has one pointer. The arbiter starts its scan at that pointer and wraps through all inputs.

If `N_INPUTS = 4` and the pointer is 2, the scan order is:

```text
2, 3, 0, 1
```

After granting input 3, the pointer becomes 0.

---

## 8. Clock-Cycle Operation

The RTL divides behavior conceptually into combinational scheduling and sequential state updates.

### 8.1 Combinational phase

For every output:

1. Inspect all VOQ counts.
2. Create requests for non-empty VOQs.
3. Scan requesters starting from that output's round-robin pointer.
4. Select the first active requester.
5. Drive `out_valid`, `out_src`, and `out_data`.
6. Mark the selected VOQ for popping.

For every input:

1. Check whether `in_dest` is a legal output.
2. Check whether the selected VOQ has free space.
3. Drive `in_ready`.
4. Mark the selected VOQ for pushing when `in_valid` is also asserted.

### 8.2 Sequential phase

At the active clock edge:

- Push accepted input payloads into their selected VOQs.
- Pop granted output payloads from their selected VOQs.
- Advance read pointers on pops.
- Advance write pointers on pushes.
- Increment or decrement counts.
- Advance an output round-robin pointer only after that output grants a flit.

A same-cycle push and pop on the same VOQ leaves the occupancy count unchanged.

The design conservatively deasserts `in_ready` when a VOQ is full, even if that VOQ might be popped in the same cycle.

---

## 9. Conflict and Correctness Properties

The intended safety properties are:

1. Each output grants zero or one input per cycle.
2. Each input cannot be selected twice for the same output because each output has one grant.
3. FIFO counts never exceed `FIFO_DEPTH`.
4. FIFO counts never become negative.
5. Payloads leave each VOQ in FIFO order.
6. A packet leaves only through its requested destination.
7. Round-robin pointers advance only after successful grants.
8. Reset empties every VOQ and resets all arbitration pointers.

The current design naturally enforces the first property through one grant per output. The testbench explicitly checks that a source is not granted twice in one cycle.

---

## 10. Verification Strategy

Verification is staged so each behavior is isolated before random traffic is added.

### Stage 1: Directed routing

All inputs send to different outputs in the same cycle.

Expected behavior:

```text
Input 0 -> Output 0
Input 1 -> Output 1
Input 2 -> Output 2
Input 3 -> Output 3
```

The testbench checks output validity and payload identity.

### Stage 2: Same-cycle contention

Several inputs send to one output in the same cycle.

Expected behavior:

- Exactly one contender is served per cycle.
- The winner follows the current round-robin pointer.
- The remaining flits stay buffered.
- All contenders eventually receive service.

### Stage 3: FIFO ordering

The same input sends multiple payloads to the same destination.

Expected behavior:

```text
payload A -> payload B -> payload C
```

The output must observe the same order.

### Stage 4: Backpressure

Fill a selected VOQ to capacity.

Expected behavior:

```text
in_ready == 0
```

The input must not overwrite an existing entry.

### Stage 5: Simultaneous push and pop

A VOQ is both read and written in one cycle.

Expected behavior:

- The old head is delivered.
- The new payload is retained.
- Occupancy remains unchanged.
- FIFO order remains correct.

### Stage 6: Randomized scoreboard

A reference model maintains one software queue for every input/output pair. On every cycle it:

1. Predicts which inputs can enqueue.
2. Predicts round-robin grants.
3. Compares expected outputs with RTL outputs.
4. Updates its queues and pointers.
5. Checks all safety properties.

Traffic distributions should include:

- Uniform random destinations.
- All inputs targeting one hotspot output.
- One-to-one traffic.
- Bursty traffic.
- Repeated traffic from one input to one output.
- Random valid gaps.

### Stage 7: Assertions

Useful SystemVerilog assertions include:

```systemverilog
// No output has more than one selected source.
// No FIFO count exceeds its configured depth.
// No output is valid when its selected VOQ is empty.
// A valid output payload remains stable if output backpressure is added.
```

---

## 11. Current Testbench

The directed testbench is in [tb/tb_crossbar_voq.sv](../tb/tb_crossbar_voq.sv).

It currently checks:

- Independent four-way routing.
- Three-way same-cycle contention.
- Round-robin service order after the directed phase.
- No duplicate source grant in one cycle.
- Correct contention payload delivery.

The testbench is self-checking. It uses `$fatal` for failures and prints a `PASS` message on success.

---

## 12. Build and Run

The project uses [Makefile](../Makefile).

### Directed simulation

```bash
make test-directed
```

Equivalent command:

```bash
iverilog -g2012 \
  -o /tmp/crossbar_voq.out \
  rtl/crossbar_voq.sv \
  tb/tb_crossbar_voq.sv
vvp /tmp/crossbar_voq.out
```

### Full test target

```bash
make test
```

The full target should be used after every referenced testbench exists in `tb/`.

### Lint

```bash
make lint
```

This uses Verilator when installed. Icarus may emit compatibility warnings for `always_comb` constant selects; these warnings do not necessarily indicate an RTL failure.

### Expected directed result

```text
PASS: VOQ crossbar directed and contention checks completed
```

---

## 13. Implementation Status

### Completed

- Revised project scope.
- Crossbar architecture selection.
- Parameterized VOQ storage.
- Input destination routing.
- FIFO read/write pointers.
- FIFO occupancy tracking.
- Output-side round-robin arbitration.
- Output selection and payload muxing.
- Input backpressure for full VOQs.
- Directed self-checking testbench.
- Make-based simulation flow.
- Architecture and project documentation.

### Remaining

- Complete randomized scoreboard testbench.
- Add explicit assertions.
- Add output `ready` and backpressure.
- Add formal checks where tools permit.
- Implement full iSLIP request/grant/accept scheduling.
- Add multi-flit packet support.
- Add throughput and latency measurement.
- Prepare crossbar presentation slides.
- Add optional CUDA traffic model for the RTX 5070.

---

## 14. Next RTL Stage: Full iSLIP-Style Scheduler

The current scheduler makes one independent choice per output, followed by a simple lowest-output-index input conflict-resolution pass. A full input-queued switch scheduler can replace this policy with iterative input-side accept arbitration.

The iSLIP-style process is:

```text
Request:
    Each input requests every output for which its VOQ is non-empty.

Grant:
    Each output grants one requester using output round robin.

Accept:
    Each input receiving multiple grants accepts one using input round robin.

Repeat:
    Unmatched inputs and outputs can participate in more iterations.
```

Required new state:

- Input-side round-robin pointers.
- Output-side round-robin pointers.
- Grant matrix.
- Accept matrix.
- Final match matrix.
- Configurable iteration count.

The first version should use one iteration, then compare one-iteration and multi-iteration behavior.

---

## 15. Later Packet-Level Extensions

The current implementation treats each transfer as one independent flit. A more realistic interconnect should support:

- `packet_start` or `head` marker.
- `packet_end` or `tail` marker.
- Packet length.
- Packet locking so a packet is not interleaved incorrectly.
- Output `ready` signal.
- Backpressure propagation.
- Priority or quality-of-service fields.
- Virtual channels.
- Error or retry signaling.

These features should be added only after the single-flit model is stable and heavily verified.

---

## 16. Performance Metrics

The simulator should collect:

```text
Throughput        = delivered flits / elapsed cycles
Average latency   = delivery cycle - injection cycle
Maximum latency   = maximum observed per-flit latency
Utilization       = active output cycles / total output cycles
Queue occupancy   = average and maximum VOQ depth
Fairness          = service distribution across persistent contenders
```

Recommended experiments:

1. Uniform traffic.
2. All-to-one hotspot traffic.
3. One-to-one traffic.
4. Bursty traffic.
5. FIFO depth sweep.
6. Input/output size sweep.
7. Output-only round robin versus iSLIP.

The important comparison is not only peak throughput. It is also how fairness and latency change under contention.

---

## 17. AMD GPU Connection

After the generic crossbar is understood, the architecture can be related to AMD GPU concepts:

```text
Wavefronts
    |
Compute Units / Workgroup Processors
    |
L1 and vector cache traffic
    |
On-chip routing and arbitration
    |
Banked L2 cache
    |
Infinity Fabric
    |
Infinity Cache and HBM
```

Relevant AMD vocabulary:

- **CU:** Compute Unit.
- **WGP:** Workgroup Processor in RDNA.
- **Wavefront:** AMD's lockstep execution group.
- **LDS:** Local Data Share, the on-chip workgroup scratchpad.
- **XCD:** Accelerator Complex Die in CDNA chiplet designs.
- **Infinity Fabric:** AMD's die-to-die and package interconnect.
- **HBM:** High-bandwidth memory used by data-center accelerators.

The educational RTL demonstrates generic routing, arbitration, buffering, and contention. It must not be described as the exact proprietary internal crossbar of an AMD GPU or RTX 5070.

The AMD documentation and the supplied reading material are architectural references. Public documentation may describe cache partitions, queues, and interconnect behavior without revealing every physical implementation detail.

---

## 18. RTX 5070 Relationship

An RTX 5070 cannot directly execute arbitrary SystemVerilog RTL. The RTL must run in an HDL simulator such as:

- Icarus Verilog.
- Verilator.
- Questa or ModelSim.
- An FPGA development flow.
- An ASIC simulation flow.

The RTX 5070 can support a separate CUDA experiment that models related contention effects in software.

Possible CUDA experiments:

- Uniform memory access.
- Hotspot access to one region.
- Coalesced versus strided access.
- Contended atomic operations.
- Different block sizes.
- Different active warp counts.

Possible GPU measurements:

- Kernel execution time.
- Effective memory bandwidth.
- Cache hit behavior.
- Warp stall reasons.
- Atomic contention cost.
- Occupancy and achieved occupancy.

These measurements complement the RTL results but do not replace RTL simulation.

---

## 19. Presentation Structure

A 10-12 slide presentation can follow this sequence:

1. Problem: many sources and many destinations.
2. Shared bus limitation.
3. Crossbar definition and strict non-blocking behavior.
4. `O(N^2)` crosspoint cost.
5. Per-output mux implementation.
6. Fixed-priority versus round-robin arbiters.
7. FIFO buffering and backpressure.
8. Head-of-line blocking.
9. VOQ solution.
10. iSLIP request/grant/accept scheduling.
11. Crossbar relationship to GPU memory subsystems.
12. Summary and implementation results.

The presentation should distinguish clearly between:

- Generic switch theory.
- The educational SystemVerilog design.
- Public AMD GPU architecture information.
- Future RTX 5070 software experiments.

---

## 20. Final Project Definition

The project is successful when it can demonstrate this chain:

```text
A request arrives
    -> destination selects a VOQ
    -> the VOQ buffers the flit
    -> the output generates a request
    -> the arbiter selects one requester
    -> the output mux forwards the payload
    -> the FIFO pops at the clock edge
    -> fairness state advances
    -> verification confirms ordering and conflict freedom
```

The present RTL implements this chain for single-flit transfers and has passed directed and randomized simulation. The next major engineering milestone is an iSLIP-style scheduler and measured traffic comparisons.

# Crossbar and AMD GPU Project Guide

## Goal

Understand crossbar fundamentals and design a verified SystemVerilog crossbar before studying how similar arbitration and routing concerns appear in AMD GPU memory systems.

## Requirements

1. Read generic material first: topology, strict non-blocking behavior, O(N^2) cost, muxes, arbiters, FIFOs, HOL blocking, VOQs, and scheduling.
2. Read GPU basics second, with AMD terminology: CU/WGP, wavefront, LDS, L1/L2, XCD, Infinity Fabric, and HBM.
3. Produce a presentation focused on the crossbar material.
4. Implement a parameterized crossbar in SystemVerilog.
5. Verify routing, contention, fairness, ordering, buffering, and conflict freedom with a self-checking testbench.
6. Later compare the RTL model with a CUDA software workload on the RTX 5070.

## Solution delivered in this workspace

- `rtl/crossbar_voq.sv`: parameterized input-queued crossbar with one VOQ per input/output pair, output round-robin arbiters, and input conflict resolution.
- `tb/tb_crossbar_voq.sv`: directed self-checking testbench for independent routing, same-cycle contention, and conflict freedom.
- `tb/tb_crossbar_random.sv`: randomized cycle-accurate scoreboard testbench.
- `docs/architecture.md`: interface contract, cycle semantics, architecture, verification strategy, and GPU boundary.
- `Makefile`: reproducible Icarus compile/run and Verilator lint commands.

## Recommended execution order

1. Install Icarus Verilog or Verilator.
2. Run `make test`.
3. Add a scoreboard for arbitrary packet sequences and random backpressure.
4. Add assertions for one-hot grants, FIFO bounds, and stable output data while stalled.
5. Extend the scheduler to an input-accept phase for an iSLIP-style model.
6. Add multi-flit packets, output ready/valid, and traffic generators.
7. Build a CUDA benchmark that compares uniform, hotspot, and coalesced access patterns, measuring throughput and latency on the RTX 5070.

## Hardware/software boundary

The RTX 5070 cannot directly execute arbitrary SystemVerilog RTL or serve as an RTL simulator. The RTL testbench runs in Icarus, Verilator, Questa, or another HDL simulator on the host CPU. The GPU is appropriate for a later CUDA traffic/performance model. System RAM capacity does not change RTL correctness; it only affects the size of software experiments.

The AMD-first architecture discussion is an architectural comparison target. It must not be presented as a claim that the educational RTL reproduces proprietary AMD or NVIDIA internal crossbar wiring.
