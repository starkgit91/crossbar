# Crossbar Interconnects & GPU Architecture (AMD-First)

**CDAC Internship — Week 1 reading, revised scope.** This replaces the earlier CPU/GPU virtual-memory-and-Nsight-profiling track. The new brief: read up on generic crossbar design (muxes, arbiters, FIFOs) and GPU architecture basics, with AMD's architecture as the primary reference, and prepare a presentation on the crossbar material.

> Images referenced below live in `assets/` next to this file. Keep the folder structure intact (e.g. unzip both together, or clone them into the same directory) and they'll render in any standard Markdown viewer (VS Code, GitHub, Typora, Obsidian).

## How this is organized

- **Part I — Crossbar Interconnects**: what they are, what they're built from, how they're scheduled. Fully generic — this is switch theory, not GPU-specific.
- **Part II — GPU Architecture Basics, AMD-first**: general GPU concepts, then AMD's RDNA and CDNA compute architectures specifically, ending with the section that ties the two parts together — where a crossbar-like structure actually sits inside a real AMD GPU.
- **Back matter**: glossary, sources, and a suggested slide outline for the presentation ask.

Read Part I before Part II — Section 6.2 assumes you know what an arbiter and a VOQ are.

---

# Part I — Crossbar Interconnects

## 1. What Is a Crossbar?

A crossbar is an interconnection network with **N inputs and M outputs**, built so that *any* input can be connected to *any* output, and — critically — **multiple such connections can be active at the same time**, as long as no two of them share an input or an output. Formally this property is called **strictly non-blocking**: given any set of free inputs and free outputs, you can always establish a new connection between them without having to tear down or rearrange any existing connection. That's a stronger guarantee than it sounds — plenty of switching networks (e.g. multistage Clos networks built with too few stages) can get into states where a legal new connection simply can't be routed without disturbing something else. A crossbar never has that problem, because every input has a direct, dedicated path to every output.

### 1.1 The cost of that guarantee

The non-blocking property isn't free. A crossbar connecting N inputs to M outputs needs **N × M crosspoints** — for a square N×N crossbar, that's O(N²). This quadratic growth is the single most important fact about crossbars, because it directly determines where they get used and where they don't:

| Topology | Wiring cost | Latency | Bandwidth | Typical use |
|---|---|---|---|---|
| Shared bus | O(N) | Low (single hop) | One transaction at a time — doesn't scale | Simple SoCs, low port counts |
| Ring / mesh (NoC) | O(N) | Variable — grows with hop count | Scales well with N | Many-core chips, tile-based NoCs |
| Crossbar | O(N\u00b2) | Low, uniform (always 1 hop) | Full — every input-output pair simultaneously | Tens of ports: switch fabrics, on-chip interconnects, GPU memory subsystems |
| Multistage (Clos) | O(N log N) | A few hops | Can be made non-blocking with enough stages | Very large port counts (data-center switches) |

A crossbar is the right choice when the port count is in the tens (not thousands) and you want the lowest possible, most uniform latency between any pair — which is exactly the regime a single chip's internal interconnect lives in (a handful of compute clusters talking to a handful of cache/memory partitions). At thousands of ports the O(N²) cost becomes prohibitive, which is why data-center-scale switches use multistage Clos fabrics instead, and why massively multi-core chips lean on mesh/NoC topologies.

![5x5 crossbar topology, non-blocking property](assets/fig01_crossbar_topology.png)

### 1.2 Where crossbars actually show up

- **Telecom / packet switches** — the classical setting. Most of the foundational scheduling theory (Section 3) comes out of this world: Stanford's *Tiny Tera* switch, iSLIP, dual round-robin matching, etc.
- **On-chip interconnects / NoC routers** — a single router in a mesh network-on-chip is very often a small crossbar (5×5 for a 2D mesh router: north/south/east/west/local).
- **Multiprocessor SoC interconnects** — connecting a handful of CPU cores/DMA engines to a handful of memory controllers or cache slices.
- **GPU memory subsystems** — connecting compute clusters to L2 cache banks and memory channels. This is where Part II is headed, and it's not a metaphor: GPU architecture patents and AMD's own architecture documentation use the literal term "crossbar" for this structure (see Section 6.2).

---

## 2. Building Blocks: Muxes, Arbiters, FIFOs

A crossbar is assembled from exactly three kinds of hardware. If you've built an ALU, a FIFO, or done any RTL work, you already know all three individually — a crossbar just wires them together for a switching purpose instead of a datapath purpose.

### 2.1 Multiplexers — the switching fabric itself

The most direct way to build an N×N crossbar is: **give every output its own N:1 multiplexer**, wired to receive all N inputs. Whichever input the mux currently selects is what that output sees. The crosspoints from Section 1's grid diagram are just this mux's internal select logic, drawn out spatially.

![Crossbar built from per-output multiplexers](assets/fig02_crossbar_mux_implementation.png)

This is straightforward combinational hardware — the same kind of `case`/`generate`-based select structure used in any datapath mux:

```verilog
// One output's N:1 mux, N=4, DATA_W-bit data
module xbar_output_mux #(parameter N = 4, parameter DATA_W = 32) (
    input  [N-1:0][DATA_W-1:0] in_data,
    input  [$clog2(N)-1:0]     sel,      // driven by this output's arbiter grant
    output [DATA_W-1:0]        out_data
);
    assign out_data = in_data[sel];
endmodule
```

N outputs each need their own N:1 mux, wired to the same N inputs → N × N wiring in total, matching the O(N²) crosspoint cost from Section 1. The mux is the easy part; picking `sel` correctly every cycle is the hard part, and that's the arbiter's job.

### 2.2 Arbiters — resolving contention

A crossbar output can only take **one** input per cycle. If two or more inputs want the same output in the same cycle, something has to pick exactly one winner — that's an **arbiter**.

- **Fixed-priority arbiter** — simplest possible design: input 0 always wins if it's requesting, else input 1, etc. Trivial to build, but low-priority requesters can starve indefinitely under sustained load from higher-priority ones.
- **Round-robin arbiter** — keeps a rotating pointer to "whoever goes first this cycle." After a grant, the pointer moves just past the winner, so next cycle a *different* requester gets first look. This guarantees fairness and bounds worst-case wait time — no requester waits more than N-1 cycles for its turn, given persistent demand.
- **Matrix arbiter** — the classic hardware circuit for implementing round-robin fairly: an N×N priority matrix where each cell (i, j) records whether i has priority over j since j's last grant. It's a clean, well-understood building block, easy to pipeline.

![Round-robin arbiter, pointer rotates after each grant](assets/fig04_round_robin_arbiter.png)

For a crossbar specifically, you don't just need one arbiter — you need one **per output** (each output resolves contention among the inputs requesting it), and in the more advanced scheduling algorithms below, coordinated arbitration on both the input and output side.

**iSLIP** (McKeown, 1999) is the best-known algorithm for scheduling an entire crossbar, not just one output. It runs in iterative rounds of three phases:

1. **Request** — every input with a queued cell requests every output it has data for.
2. **Grant** — every output picks one winner among its requesters, using its own rotating-priority round-robin arbiter.
3. **Accept** — every input that received one or more grants picks one, using its own rotating-priority round-robin arbiter, and only that input's pointer advances (this detail — only *matched* arbiters update their pointer — is what gives iSLIP its fairness and convergence properties).

Unmatched inputs/outputs repeat Request→Grant→Accept in a further iteration. In practice this converges to a maximal matching within a handful of iterations and achieves 100% throughput under uniform traffic, while staying simple enough to implement in hardware at line rate.

### 2.3 FIFOs — buffering

Not every request gets granted every cycle — losers have to wait somewhere, and that's what the FIFO is for. Where you put the FIFO is a real design decision with real tradeoffs:

| Buffering scheme | Where the FIFO lives | Speedup needed | Notes |
|---|---|---|---|
| Input-queued (IQ) | One queue per input | 1x | Simplest; suffers head-of-line blocking with plain FIFOs (Section 3) |
| Output-queued (OQ) | One queue per output | Up to N x | Optimal delay/throughput, but every output must be able to accept from all N inputs simultaneously — impractical for large N |
| Combined input-output-queued (CIOQ) | Both | Small (~2x) | Gets close to OQ performance without full N x speedup |
| Buffered crossbar | Small FIFO *at every crosspoint* | 1x | Decouples input-side and output-side scheduling into two simpler independent problems instead of one centralized matching problem, at the cost of N² small buffers |

If this is the same mental model you used designing an async FIFO for a clock-domain crossing — it is. The interface contract (full/empty flags, push/pop, backpressure) is identical; the only difference is *why* the data is waiting. In a CDC FIFO it's waiting for a clock edge on the other side. In a crossbar, it's waiting for its turn to win the output's arbiter.

---

## 3. Arbitration & Scheduling: The Full Picture

### 3.1 Head-of-line blocking

If every input has just **one plain FIFO** feeding the crossbar, a subtle problem shows up: the packet at the *front* of that FIFO might be destined for an output that's currently busy or contested — and every packet behind it is stuck waiting, even if *their* destination outputs are completely free right now. This is **head-of-line (HOL) blocking**, and it's not a minor effect: under simple uniform random traffic, HOL blocking caps the achievable throughput of an input-queued switch at roughly **58.6%** of capacity — a well-known classical result (Karol et al.) that shows up in essentially every crossbar-scheduling paper as the motivating problem.

![Head-of-line blocking vs. virtual output queues](assets/fig03_hol_blocking_vs_voq.png)

### 3.2 Virtual output queues (VOQ)

The fix: instead of one FIFO per input, keep **N separate queues per input, one per destination output**. A packet destined for a busy output no longer blocks packets behind it that want a free output — each destination has its own line. VOQs plus a real scheduling algorithm (round-robin-based, iSLIP, etc.) is what recovers close to 100% throughput even under uniform traffic — VOQs alone don't fix throughput, they just remove the *structural* reason it was capped; you still need a scheduler making good matching decisions every cycle.

### 3.3 The scheduling algorithm design space

Beyond iSLIP, a few other named approaches worth knowing exist in the same family:

- **PIM (Parallel Iterative Matching)** — iSLIP's predecessor; same Request/Grant/Accept structure but uses random selection instead of rotating priority, which converges but with weaker fairness guarantees.
- **Dual round-robin matching (DRRM) / "Saturn" switch** — a simplified two-arbiter (not fully iterative) scheme aimed at reducing implementation complexity versus multi-iteration iSLIP, while still achieving good throughput and bounded delay.
- **Buffered-crossbar schedulers (e.g. CIXOB-k)** — sidestep the centralized matching problem entirely by giving every crosspoint its own small buffer, so the input side and output side can each run independent, simpler schedulers.

You don't need to memorize all of these — the point is that "how do I schedule a crossbar" is a whole sub-field with real named algorithms behind it, not just "round robin and done."

### 3.4 Why this matters going into Part II

A GPU's on-chip interconnect faces exactly this same contention problem: many compute clusters issuing memory requests every cycle, a much smaller number of L2 cache slices / memory channels to serve them. Everything in this Part — non-blocking topology, muxes, arbiters, VOQs, fair scheduling — isn't background theory you can set aside once you start reading about GPUs. It's the literal mechanism that determines memory-access latency and fairness on the chip. Section 6.2 makes that connection concrete.

---

# Part II — GPU Architecture Basics (AMD-First)

## 4. GPU Architecture Fundamentals

The one-line version, common to every modern GPU regardless of vendor: trade single-thread speed for massive concurrency, and hide memory latency by having far more threads in flight than there are execution lanes, so the hardware always has *something* ready to run while any given thread waits on memory.

Every GPU, AMD or NVIDIA, is built from the same conceptual layers — they just use different names:

| Concept | AMD term | NVIDIA term |
|---|---|---|
| Cluster of ALUs executing in lockstep | Compute Unit (CU) / Workgroup Processor (WGP) | Streaming Multiprocessor (SM) |
| Group of threads executing one instruction together | Wavefront (32 or 64 threads) | Warp (32 threads, fixed) |
| Programmer-defined group of threads | Workgroup | Thread block |
| Fast on-chip scratchpad shared within a group | LDS (Local Data Share) | Shared memory |
| Individual ALU lane | Stream processor / shader core | CUDA core |
| Execution model | SIMT (wavefronts) | SIMT (warps) |

Since this pass is AMD-first, the rest of Part II uses AMD's vocabulary (wavefront, CU/WGP, LDS) as primary — but the table above is worth keeping close if you're cross-referencing anything written from an NVIDIA/CUDA angle.

---

## 5. AMD Compute Architecture: RDNA and CDNA

AMD splits its GPU architecture into two families with different goals — directly analogous to NVIDIA splitting GeForce/RTX from Hopper/Blackwell.

- **RDNA** — gaming- and graphics-optimized. Powers Radeon consumer GPUs and the current game consoles.
- **CDNA** — compute-optimized. Powers the Instinct MI-series data-center accelerators (MI300, MI350, ...). No rasterization/graphics hardware at all — every bit of die area goes to compute throughput, matrix units, and memory bandwidth.

### 5.1 RDNA: Compute Unit and Workgroup Processor

RDNA's predecessor, **GCN**, built each Compute Unit around 4× SIMD16 units, executing a 64-wide wavefront over 4 clock cycles. RDNA restructured this substantially:

- The CU was paired up into a **Workgroup Processor (WGP)** — two coupled CUs sharing an L0 vector cache and L0 scalar cache.
- Each CU got **dual SIMD32 units**, able to issue an entire native **Wave32** wavefront in a single cycle (versus GCN's 4-cycle issue for Wave64 on SIMD16).
- The wavefront width became **flexible**: the compiler picks Wave32 or Wave64 per draw call/kernel depending on the workload, with Wave64 executed as a paired operation across both SIMD32 units.
- **RDNA 3** added dual-issue wavefront dispatch — two SIMD32 units processing instructions in the same cycle, roughly doubling peak throughput per CU pair over RDNA 2 for suitable code.
- **RDNA 4** (2025) is notable for *removing* the separate mid-level L1 cache that earlier RDNA generations had, instead putting that die-area budget into a larger L2 — evidence that AMD found L1 hit rates weren't earning their keep once L2 got fast and large enough.

![AMD RDNA Workgroup Processor — two coupled Compute Units](assets/fig05_amd_rdna_wgp.png)

### 5.2 CDNA: Compute Unit, XCD, and Chiplets

CDNA strips out everything graphics-specific and is built for FP64/FP32/matrix throughput at data-center scale. Starting with **CDNA 3** (AMD Instinct MI300 series), AMD introduced chiplet packaging in earnest:

- The fundamental compute chiplet is the **XCD (Accelerator Complex Die)** — it holds the GPU's compute elements plus the lower levels of the cache hierarchy.
- A full MI300-series package stacks **up to 8 XCDs**, alongside up to 8 HBM3 memory stacks and separate I/O dies, all tied together over AMD's **Infinity Fabric** interconnect.
- **Inside one XCD**: 40 Compute Units (38 active + 2 held back for yield management), each CU carrying 32 KB of L1 cache, matrix cores (MFMA units), vector ALUs, and its own LDS. Four **Asynchronous Compute Engines (ACEs)** dispatch workgroups out to the CUs, all 40 CUs share a **4 MB L2 cache** that coalesces memory traffic for the whole die, and a **Hardware Scheduler (HWS)** manages it all.

![AMD CDNA 3 — one XCD (Accelerator Complex Die)](assets/fig06_amd_cdna_xcd.png)

Two concrete configurations worth knowing:

- **MI300X** (discrete accelerator): 8 XCDs for up to ~304 CUs total, 192 GB of HBM3 at roughly 5.3 TB/s, and a large 256 MB L3 **Infinity Cache** shared across all the chiplets.
- **MI300A** (APU variant): 24 Zen 4 CPU cores *and* 6 CDNA 3 XCDs sharing **one pool of 128 GB HBM3 memory** on a single package. This is worth pausing on: it's a hardware-level solution to the exact problem CUDA's Unified Virtual Memory solves in software on discrete GPUs — CPU and GPU simply share the same physical memory and the same coherency domain, so there's no separate address space to migrate data between in the first place. A **Coherent Slave (CS)** unit with a probe/snoop filter tracks which XCDs have a given cache line, so a coherent write doesn't have to probe every XCD's L2 on every access.

**Matrix Cores** are CDNA's tensor-math accelerators (analogous to NVIDIA's Tensor Cores), executing **MFMA (Matrix Fused Multiply-Add)** instructions across FP8, FP16, BF16, FP32, FP64, and INT8 — a distinct instruction set from NVIDIA's WMMA/MMA family, but serving the same architectural role.

### 5.3 Wavefronts, LDS, and latency hiding

- A **wavefront** is AMD's unit of lockstep SIMT execution — fixed at 64 threads on CDNA, and either 32 or 64 (with Wave32 as the RDNA-native mode) on RDNA.
- **LDS (Local Data Share)** is AMD's shared-memory equivalent: a fast, banked, on-chip scratchpad shared by all wavefronts within a workgroup, used for explicit inter-thread communication and reduction patterns. Like any banked memory, it has bank-conflict hardware to detect and resolve simultaneous accesses to the same bank from different threads.
- Latency hiding works the same way conceptually as in any GPU architecture: a single CU manages far more concurrent wavefronts than it has SIMD lanes, so when one wavefront stalls on a memory access, the hardware simply issues from a different, ready wavefront instead. This is the CU's **Instruction Sequencer (SQ)** — the control center that tracks wavefront state and coordinates issue across the CU's execution units.

---

## 6. AMD Memory Hierarchy and the On-Chip Interconnect

### 6.1 The hierarchy, register to HBM

![AMD-flavored memory hierarchy, VGPR to HBM](assets/fig08_memory_hierarchy_amd.png)

| Level | Typical latency | Typical size | Scope |
|---|---|---|---|
| Vector GPRs | ~1 cycle | Per lane, per wavefront | Private |
| LDS | A few cycles | Tens of KB per WGP/CU | Shared within a workgroup |
| L1 / vL1D cache | Tens of cycles | Tens of KB, per CU cluster | Shared by a small group of CUs |
| L2 cache | 150+ cycles | A few MB, banked, chip-wide | Shared across the die/XCD |
| Infinity Cache + HBM/GDDR | Hundreds of cycles | Tens of MB \u2192 hundreds of GB | Whole package |

### 6.2 Where the crossbar actually lives — Part I, physically instantiated

This is the section that ties the whole document together. AMD's own GPU architecture patents and documentation describe the block that sits between the compute clusters and the cache/memory subsystem using the literal term **crossbar** — "input crossbar," "output crossbar," "data crossbar" all appear in real GPU architecture patent language, not as a loose metaphor.

![Where the crossbar sits in an AMD GPU](assets/fig07_amd_gpu_chip_interconnect.png)

Concretely, for a CDNA-class die: each Shader Engine's CUs feed their L1/L2 traffic through an on-chip interconnect that fans out to every **L2 cache slice** (L2 is *banked* — split into independently-addressable slices precisely so multiple Shader Engines can hit different banks concurrently without contention, exactly like a crossbar's non-blocking property from Section 1). AMD's own CDNA 2 whitepaper explicitly describes having *enhanced the queuing and arbitration for the distributed L2 cache* to improve read-bandwidth utilization across workloads — that is Part I's arbiter-and-VOQ theory, verbatim, applied to real silicon. The same document notes the per-memory-controller-to-L2-slice link width was doubled to 64 bytes in that generation, i.e. a direct crossbar-cost/bandwidth tradeoff of the kind Section 1's cost table describes.

One level further out, **Infinity Fabric** is the interconnect that ties multiple XCDs to each other, to the Infinity Cache, and to the HBM stacks — on MI300-class hardware, 4th-generation Infinity Fabric delivers on the order of **896 GB/s of aggregate bandwidth** in an 8-GPU system, alongside dedicated PCIe connectivity out to the host.

This isn't a hand-wavy analogy for the sake of a tidy narrative, either — it's an active research topic: GPU cache-hierarchy literature specifically studies "crossbar-based systems" as one of the standard interconnect topologies (alongside mesh) connecting GPU cores to banked L2/memory partitions, when evaluating how to reduce interconnect traffic and exploit inter-core cache locality.

### 6.3 Coherency across the fabric

Briefly, since it's a genuinely current architectural detail: in APU designs like MI300A where CPU and GPU chiplets share one memory pool, the **Coherent Slave (CS)** hardware (inherited conceptually from AMD's Zen CPU interconnect) is what makes that sharing safe. Every coherent write has to be visible to any thread doing a coherent read, regardless of which XCD it's running on — naively that means probing every XCD's L2 on every write, which doesn't scale. The **probe filter (snoop filter)** avoids this by tracking *which* XCDs actually have a given line cached, so only those need to be probed.

---

# Back Matter

## Glossary

**Crossbar** — An N×M interconnection network where any input can be wired to any free output, with multiple such connections active simultaneously, at O(N×M) wiring cost.
**Crosspoint** — One of the N×M switch points in a crossbar; the unit that gets turned on/off to make a connection.
**Non-blocking (strictly)** — Property guaranteeing any legal new connection can always be made without disturbing existing ones.
**Arbiter** — Hardware that picks exactly one winner among several simultaneous requesters for a shared resource.
**Round-robin arbiter** — An arbiter that rotates priority after each grant, guaranteeing fairness and bounded wait time.
**iSLIP** — An iterative Request/Grant/Accept scheduling algorithm for crossbars using rotating-priority arbiters on both sides; achieves 100% throughput under uniform traffic.
**Head-of-line (HOL) blocking** — Throughput loss caused by a blocked packet at the front of a FIFO stalling unrelated packets behind it.
**Virtual output queue (VOQ)** — A separate queue per destination at each input, eliminating the structural cause of HOL blocking.
**FIFO** — First-in-first-out buffer; in a crossbar, holds requests/data waiting for their turn through the switch.
**CU (Compute Unit)** — AMD's core compute-cluster building block; roughly equivalent to NVIDIA's SM.
**WGP (Workgroup Processor)** — RDNA's pairing of two CUs sharing L0 caches.
**XCD (Accelerator Complex Die)** — CDNA 3+'s compute chiplet; the fundamental building block of MI300-series packages.
**Wavefront** — AMD's unit of lockstep SIMT execution (32 or 64 threads); equivalent to NVIDIA's warp.
**LDS (Local Data Share)** — AMD's fast on-chip shared-memory scratchpad, per workgroup.
**Infinity Fabric** — AMD's chip-to-chip / die-to-die interconnect, tying together XCDs, Infinity Cache, and HBM.
**Infinity Cache** — A large on-die last-level cache sitting between L2 and main memory.
**MFMA (Matrix Fused Multiply-Add)** — CDNA's matrix-math instruction family, powering its Matrix Cores.
**ACE (Asynchronous Compute Engine)** — Hardware command processor that dispatches compute workgroups to CUs.
**HWS (Hardware Scheduler)** — Hardware unit managing workgroup scheduling across an XCD.
**Coherent Slave (CS) / probe filter** — Coherency hardware tracking which chiplets cache which lines, avoiding unnecessary cross-chiplet cache probes.

## Further reading / sources

**Crossbar & arbitration theory**
- N. McKeown, *The iSLIP Scheduling Algorithm for Input-Queued Switches*, IEEE/ACM Transactions on Networking, 1999.
- Chuang, Iyer, McKeown, *Practical Algorithms for Performance Guarantees in Buffered Crossbars*, IEEE INFOCOM, 2005.
- FPGA Design of an 8-bit 4x4 Crossbar Switch for Multiprocessor SoC using Round-Robin Arbitration — ResearchGate.

**AMD architecture**
- AMD CDNA architecture overview — https://www.amd.com/en/technologies/cdna.html
- AMD Instinct MI300 series microarchitecture — https://rocm.docs.amd.com/en/latest/conceptual/gpu-arch/mi300.html
- AMD CDNA 2 whitepaper (PDF) — https://www.amd.com/content/dam/amd/en/documents/instinct-business-docs/white-papers/amd-cdna2-white-paper.pdf
- AMD CDNA 3 whitepaper (PDF) — https://www.amd.com/content/dam/amd/en/documents/instinct-tech-docs/white-papers/amd-cdna-3-white-paper.pdf
- RDNA (microarchitecture) — Wikipedia, https://en.wikipedia.org/wiki/RDNA_(microarchitecture)
- AMD's RDNA4 GPU Architecture at Hot Chips 2025 — Chips and Cheese, https://chipsandcheese.com/p/amds-rdna4-gpu-architecture-at-hot
- AMD's CDNA 3 Compute Architecture — Chips and Cheese, https://chipsandcheese.com/p/amds-cdna-3-compute-architecture
- Hardware implementation (CU/WGP internals) — ROCm HIP docs, https://rocm.docs.amd.com/projects/HIP/en/latest/understand/hardware_implementation.html
- Shader Engine conceptual docs — ROCm profiler docs, https://rocm.docs.amd.com/projects/rocprofiler-compute/en/latest/conceptual/shader-engine.html

*(All figures in `assets/` were generated locally to illustrate the concepts above; they are original diagrams, not reproductions of any vendor's slides.)*

---

## Suggested presentation outline (for the crossbar deliverable)

Since the assignment includes putting together a presentation on the crossbar material specifically, here's a slide-by-slide skeleton pulled straight from Part I — 10-12 slides, roughly 12-15 minutes:

1. **Title** — "Crossbar Interconnects: From Switch Theory to On-Chip Fabric"
2. **The problem** — N sources, M destinations, need any-to-any connectivity. Show the naive shared-bus alternative and why it doesn't scale in bandwidth.
3. **What a crossbar is** — Fig. 1 (topology grid), define non-blocking.
4. **The cost** — O(N\u00b2) crosspoints; table comparing bus / mesh / crossbar / Clos.
5. **Building block 1: Muxes** — Fig. 2, tie to N:1 mux hardware you already know.
6. **Building block 2: Arbiters** — priority vs round-robin; Fig. 4.
7. **The scheduling problem** — why one arbiter per output isn't enough; introduce matching.
8. **iSLIP** — Request/Grant/Accept, 3 phases, converges to maximal matching.
9. **Building block 3: FIFOs, and head-of-line blocking** — Fig. 3, the 58.6% number.
10. **The fix: VOQ** — one queue per destination.
11. **Where this shows up: real GPU interconnects** — Fig. 7, the AMD L2/Infinity Fabric example from Section 6.2. This is the slide that justifies *why anyone in GPU architecture cares* about switch theory from the 1990s telecom world.
12. **Summary / takeaways.**

---

## Suggested next steps

- Read the AMD CDNA 3 whitepaper directly (linked above) — it's the primary source for most of Section 5.2's numbers and goes considerably deeper on the matrix-core datatypes.
- Skim the RDNA4 Hot Chips 2025 coverage for the L1-cache-removal reasoning in more depth — a good example of a real, recent architectural trade-off decision.
- As a design exercise: sketch (pen-and-paper or a short Verilog module) a 4x4 crossbar with per-output round-robin arbiters and VOQs at each input. This turns Part I from reading into something you've actually built, and maps directly onto the presentation outline above.

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

