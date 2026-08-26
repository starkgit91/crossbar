# Crossbar Implementation Plan

## Goal

Build and verify a parameterized input-queued crossbar that demonstrates the generic machinery from the Week 1 scope: per-input virtual output queues, output-side round-robin arbitration, multiplexed data paths, buffering, backpressure, and one-hop parallel transfers.

## Scope and requirements

- SystemVerilog RTL, parameterized by input count, output count, data width, and FIFO depth.
- One input stream per input port. Each accepted flit has a destination output and payload.
- One flit can leave each output per cycle.
- Each input can leave for at most one output per cycle.
- Per-input VOQ: one FIFO for each input/output destination pair.
- One round-robin arbiter per output.
- `in_ready` must prevent writes to a full VOQ.
- `out_valid`, `out_data`, and `out_src` identify transfers.
- No input or output may be granted twice in one cycle.
- A portable, self-checking simulator testbench is required.

## Architecture

```text
input i --> route by destination --> VOQ[i][0..M-1] --> request matrix
                                                            |
                                      round-robin arbiter per output
                                                            |
                                      one-hot grants / output muxes
                                                            |
outputs 0..M-1 <---------------------------------------------+
```

The request matrix is `request[output][input]`. An output scans requesters starting at its rotating pointer and grants the first active input. A second input-side conflict-resolution pass accepts the lowest-index output when independent output arbiters select the same input, making the final grants conflict-free without a multi-iteration input-side accept phase.

## Cycle semantics

- Requests and grants are combinational from the current FIFO state.
- A granted output observes the current head flit during the cycle.
- On the active clock edge, granted flits are popped and accepted input flits are pushed.
- An arbiter pointer advances only when its output grants a flit.
- An output grant is discarded if its selected input already won an earlier output in the same cycle.
- A full VOQ is conservatively not ready, even when a same-cycle pop would create space.

## Verification strategy

1. Directed no-contention routing verifies each destination path.
2. Sustained contention verifies round-robin service and absence of starvation.
3. Simultaneous traffic verifies independent transfers on multiple outputs.
4. Backpressure verifies FIFO-full behavior.
5. Scoreboard and assertions verify payload ordering, legal destinations, and no duplicate source/output use.

## GPU relationship

The RTL is an educational crossbar model, not an implementation of the proprietary internal interconnect of an RTX 5070 or AMD GPU. The RTX 5070 can be used later to benchmark a CUDA software model of contention and memory-access latency. RTL behavior must be verified with an RTL simulator, FPGA, or ASIC flow; a consumer GPU cannot execute arbitrary SystemVerilog RTL directly.

## Later extensions

- Separate input-side accept arbitration to model iSLIP.
- Ready/valid output backpressure.
- Multi-flit packets and packet atomicity.
- Virtual-channel or priority fields.
- Mesh/NoC comparison model.
- CUDA benchmark comparing serialized, contended, and coalesced access patterns on the RTX 5070.
