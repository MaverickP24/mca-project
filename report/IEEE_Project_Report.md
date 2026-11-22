# Design, Implementation, and Cycle-Accurate Verification of a Write-Back Cache Controller in Verilog-2001

**Course / Evaluation:** Master of Computer Applications (MCA) — Phase I Evaluation<br>
**Project Title:** Write-Back Cache Controller<br>
**Team:** MCA_Project_2024_D_Team2<br>
**Institution:** Rishihood University<br>
**Authors:** Hrishabh Prajapati (2401020027), Jigyasu Kalyan (2401010201), Pratyush Parida (2401010351), Preet Vardhan (2401010352), Raghav Gupta (2401010365)<br>
**Document Format:** IEEE Conference Style Technical Report<br>
**Date:** November 16, 2026

---

## Abstract

In contemporary computer architectures, the divergence between high-frequency central processing units (CPUs) and relatively slow off-chip dynamic RAM (DRAM)—frequently characterized as the "memory wall"—constitutes a fundamental system throughput bottleneck. Cache memory systems mitigate this latency by exploiting spatial and temporal locality of reference. Among cache design dimensions, the write policy critically dictates bus bandwidth utilization, system power dissipation, and memory traffic. This paper presents the architecture, Register-Transfer Level (RTL) implementation, and cycle-accurate functional verification of a **Write-Back Cache Controller** with **write-allocation** and dedicated per-line **dirty-bit management**. Designed in Verilog-2001, the cache employs a direct-mapped organization comprising 8 cache lines with 4 words (128 bits) per block (128 bytes total data capacity), serving aligned 32-bit word requests (`cpu_addr[1:0] == 2'b00`) from a host processor using a 25-bit Tag `[31:7]`, 3-bit Line Index `[6:4]`, and 2-bit Word Offset `[3:2]`. A 9-state Mealy/Moore hybrid Finite State Machine (FSM) orchestrates request decoding, hit/miss detection, clean eviction bypass, and dirty line write-backs prior to block refills. The controller connects to a behavioral 16 KB main memory simulation model (1,024 blocks of 128 bits indexed via address bits `[13:4]`). Functional verification was conducted using Icarus Verilog and GTKWave across twelve targeted verification scenarios exercising cold read misses, resident read hits, write hits with dirty-bit assertion, proof of main memory preservation during write hits, write misses with write-allocation, dirty line evictions with memory write-back, clean line eviction bypass, reading previously written-back data, and zero-idle-cycle back-to-back CPU transactions. All 19 programmed assertions passed successfully with zero defects, verifying the correctness of the write-back and write-allocation architecture.

---

## Keywords

Cache Controller, Write-Back Policy, Write-Allocate, Dirty Bit, Memory Coherency, Finite State Machine (FSM), Verilog-2001, Hardware Verification, Computer Architecture.

---

## I. Introduction

The relentless advancement of microprocessor execution pipelines has amplified the performance disparity between fast processing cores and slow main storage [1]. Without intermediate cache memory, modern microprocessors would remain stalled for the vast majority of machine cycles awaiting DRAM response. High-speed SRAM caches organized adjacent to the processor core exploit two foundational properties of program execution [2]:
1. **Temporal Locality:** Memory locations accessed recently are highly probable to be re-accessed in the immediate future (e.g., loop indices, function call frames).
2. **Spatial Locality:** Memory addresses contiguous to recently referenced locations are highly probable to be accessed soon (e.g., sequential instruction fetches, array iterations).

While cache read operations are largely standardized across architectures, the choice of **write policy** exerts a profound impact on bus utilization and energy efficiency [3]. Under a **write-through** policy, every processor write operation immediately updates both the cache line and backing main memory. Although write-through simplifies memory coherency, it saturates the memory bus with high write traffic and forces frequent CPU write stalls [1].

Conversely, a **write-back** policy updates only the local cache line upon a write hit, marking a dedicated hardware flag known as the **dirty bit** (or modified bit) [4]. Main memory is not modified during write hits. Backing storage is updated only when a dirty line is subsequently evicted to make room for a new memory block. By filtering repeated writes locally within high-speed SRAM, a write-back cache reduces off-chip bus transactions substantially.

This project focuses on the formal modeling, synthesizable RTL implementation, and cycle-accurate simulation verification of a **Write-Back Cache Controller** for MCA Phase I evaluation.

---

## II. Literature Review

The classic analytical survey by Alan Jay Smith [3] established the mathematical principles of cache operation, analyzing replacement algorithms, block sizes, and write policies. Smith demonstrated that write operations account for approximately $10\%$ to $30\%$ of all memory references in typical instruction set architectures (ISAs). Under write-through schemes, these writes create memory bus bottlenecks. A write-back policy drastically mitigates this contention by coalescing multiple consecutive writes to the same cache block before a single burst flush to main memory.

Hennessy and Patterson [1] formalized the interaction between write policies and cache allocation schemes:
- **Write-Allocate (Fetch-on-Write):** On a write miss, the required block is fetched from main memory into the cache line, the specific target word is modified, and the line is marked dirty. Subsequent writes or reads to the same block hit immediately in cache, exploiting spatial locality.
- **No-Write-Allocate (Write-Around):** On a write miss, the block is written directly to main memory without being loaded into cache.

Jouppi [5] investigated the trade-offs of write-back caching and write buffers, emphasizing that write-back with write-allocation offers optimal throughput for workloads exhibiting spatial write locality, such as array initialization, streaming matrix computations, and structure updates.

Przybylski [6] explored cache design trade-offs, showing that direct-mapped cache architectures provide the shortest hit critical path delay, eliminating comparator and multiplexer delays associated with multi-way tag matching. The IEEE 1364-2001 standard [7] specifies deterministic coding methodologies for synchronous FSM controllers and race-free hardware execution.

---

## III. Problem Statement

To design, implement in Verilog-2001, and verify via cycle-accurate simulation a robust, synthesizable **Write-Back Cache Controller** satisfying the following operational criteria:
1. Service 32-bit byte-addressed CPU read and write transactions.
2. Implement a direct-mapped cache organization with 4 words (128 bits) per cache line to exploit spatial locality.
3. Enforce the **write-back policy**, ensuring that write hits update only local cache storage and set the dirty bit while leaving backing main memory unmodified.
4. Implement the **write-allocate policy**, refilling memory blocks on write misses, modifying the target word, and marking the cache line dirty.
5. Guarantee data coherency during evictions: detect dirty cache lines, preserve their original address, and write the full 128-bit block back to main memory prior to fetching the replacement block.
6. Bypass unnecessary write-back operations when evicting clean lines, saving off-chip bus cycles.
7. Support continuous, zero-idle-cycle back-to-back CPU memory transactions without race conditions or protocol deadlocks.

---

## IV. Project Objectives

1. **Architectural Derivation:** Formulate a mathematically consistent address decomposition mapping 32-bit CPU addresses into Tag, Index, Word Offset, and Byte Offset fields.
2. **Modular RTL Design:** Structure the hardware into cohesive, synthesizable modules:
   - `cache_controller.v`: 9-state Mealy/Moore FSM and control sequencing.
   - `cache_memory.v`: Storage arrays for tags, valid bits, dirty bits, and data words.
   - `main_memory.v`: Behavioral 128-bit block memory with realistic multi-cycle DRAM latency.
   - `top_module.v`: Structural integration encapsulating all inter-module buses.
3. **Rigorous Verification Suite:** Develop an automated, self-checking testbench (`tb_cache_controller.v`) verifying twelve functional scenarios with programmatic assertions.
4. **Waveform and Signal Analysis:** Generate and inspect VCD waveforms in GTKWave to confirm cycle-accurate state transitions and bus protocols.

---

## V. Proposed Architecture

The cache subsystem connects between a host CPU interface and a backing main memory model:

```
+-------------------------------------------------------------------------+
|                               top_module                                |
|                                                                         |
|  +--------------------+        +-------------------------------------+  |
|  |                    |<------>|            cache_memory             |  |
|  |  cache_controller  |        |  - Direct-Mapped Storage (8 Lines)  |  |
|  |     (9-State FSM)  |        |  - Valid Array [7:0]                |  |
|  |                    |        |  - Dirty Array [7:0]                |  |
|  |                    |        |  - Tag Array [7:0] (25 bits)        |  |
|  |                    |        |  - Data Array [7:0][3:0] (128 bits) |  |
|  +--------------------+        +-------------------------------------+  |
|            ^                                                            |
|            | 128-bit Block Bus (mem_req, mem_write, mem_ready)          |
|            v                                                            |
|  +-------------------------------------------------------------------+  |
|  |                     main_memory (1024 Blocks)                     |  |
|  +-------------------------------------------------------------------+  |
+-------------------------------------------------------------------------+
```

### Address Decomposition

The CPU issues 32-bit byte addresses (`cpu_addr[31:0]`). The prototype controller is designed for word-aligned 32-bit memory accesses (`cpu_addr[1:0] == 2'b00`). The direct-mapped cache parameters are derived as follows:
- **Address Width ($A$):** 32 bits (`cpu_addr[31:0]`)
- **Word Width ($W$):** 32 bits (4 bytes)
- **Words per Block ($K$):** 4 words
- **Block Size ($B$):** $4 \times 4 = 16$ bytes (128 bits)
- **Number of Cache Lines ($M$):** 8 lines
- **Total Cache Data Capacity:** $8 \times 16\text{ bytes} = 128\text{ bytes}$ (32 data words)

$$\text{Address Width} = \text{Tag Width} + \text{Index Width} + \text{Word Offset Width} + \text{Byte Offset Width}$$

1. **Byte Offset ($\text{BO}$):** $\log_2(4\text{ bytes}) = 2\text{ bits} \implies \texttt{cpu\_addr[1:0]}$. Word-aligned accesses maintain `2'b00`.
2. **Word Offset ($\text{WO}$):** $\log_2(4\text{ words}) = 2\text{ bits} \implies \texttt{cpu\_addr[3:2]}$. Selects one of the four 32-bit words within a block:
   - `2'b00`: Word 0 (`data[31:0]`)
   - `2'b01`: Word 1 (`data[63:32]`)
   - `2'b10`: Word 2 (`data[95:64]`)
   - `2'b11`: Word 3 (`data[127:96]`)
3. **Cache Index ($\text{Index}$):** $\log_2(8\text{ lines}) = 3\text{ bits} \implies \texttt{cpu\_addr[6:4]}$. Directly indexes one of the 8 cache lines ($0$ to $7$).
4. **Tag ($\text{Tag}$):** $32 - (3 + 2 + 2) = 25\text{ bits} \implies \texttt{cpu\_addr[31:7]}$. Uniquely identifies memory blocks mapped to each line.

$$\underbrace{\texttt{cpu\_addr[31:7]}}_{\text{Tag: 25 bits}} \quad \vert \quad \underbrace{\texttt{cpu\_addr[6:4]}}_{\text{Index: 3 bits}} \quad \vert \quad \underbrace{\texttt{cpu\_addr[3:2]}}_{\text{Word Offset: 2 bits}} \quad \vert \quad \underbrace{\texttt{cpu\_addr[1:0]}}_{\text{Byte Offset: 2 bits}}$$

### Behavioral Main Memory Subsystem & Simulation Scope

The simulation environment integrates a behavioral main memory model (`rtl/main_memory.v`):
- **Storage Capacity:** 1,024 blocks of 128 bits, totaling 16 KB of backing storage.
- **Addressing Mechanism:** The memory model uses address bits `[13:4]` (10 bits) to select among its 1,024 blocks, addressing bytes `0x0000_0000` through `0x0000_3FFF`.
- **Architectural Scope Limitation:** Memory requests with identical `[13:4]` address bits alias to the same simulated block location. This abstraction avoids multi-megabyte simulation memory overhead while providing cycle-accurate latency modeling for functional verification, but represents a simulation modeling limitation.
- **Simulation Verification Boundary:** The cache controller and cache memory are structured using standard synthesizable Verilog-2001 constructs. However, all verification in Phase I was conducted via cycle-accurate RTL simulation in Icarus Verilog; no physical FPGA synthesis, ASIC place-and-route, or physical hardware measurements have been conducted.

---

## VI. Cache Organization

A direct-mapped organization was selected as the underlying cache geometry for this Write-Back Cache Controller project. In a direct-mapped cache, each memory address maps to exactly one specific line in the cache determined by its index field:
$$\text{Line Index} = (\text{Block Address}) \pmod M$$
This organization provides:
1. **Minimal Hit Latency:** Eliminates multi-way tag comparators and multiplexing logic, enabling single-cycle tag evaluation.
2. **Simplified Control:** Eviction candidates are deterministic; when a miss occurs at index $I$, the resident line at index $I$ is the sole candidate for replacement.
3. **Clear Focus on Write-Back:** Isolates the write-back and dirty-bit mechanisms without conflating them with multi-way associativity or replacement heuristics.

Each line in `cache_memory.v` contains:
- `valid` (1 bit): Indicates if the line holds valid data (`1`) or is uninitialized (`0`).
- `dirty` (1 bit): Indicates if cached data has been modified relative to main memory.
- `tag` (25 bits): Stores the address tag of the resident memory block.
- `data` (128 bits): Stores four 32-bit words (`Word 0` to `Word 3`).

---

## VII. Write-Back Policy and Dirty-Bit Management

The core architectural subject of this project is the **Write-Back Policy** with **Dirty-Bit Management**:

### A. Write Hit Operation
When a write request matches an existing valid line (`cache_hit == 1`):
1. The target 32-bit word in cache memory is updated with `cpu_write_data`.
2. The line's dirty bit is asserted: $\texttt{dirty\_array}[\text{index}] \leftarrow 1'b1$.
3. Main memory is **not** written. Off-chip memory bus signals (`mem_req`, `mem_write`) remain deasserted (`0`).
4. The transaction completes with `cpu_ready = 1`.

### B. Write Miss Operation (Write-Allocate)
When a write request misses (`cache_hit == 0`):
1. If the resident line is dirty, it is first written back to main memory.
2. The requested block is fetched from main memory into a temporary register.
3. The CPU's write data is merged into the fetched block at `req_offset`.
4. The merged 128-bit block is written to the cache line with `valid = 1'b1` and `dirty = 1'b1`.

### C. Dirty Eviction
When a new memory block must be installed into a line that is valid and dirty (`valid == 1 && dirty == 1`):
1. The controller reconstructs the original block address: $\{\texttt{line\_tag}, \text{index}, 4'b0000\}$.
2. The entire 128-bit block is written back to main memory.
3. Only after the memory write handshake completes (`mem_ready == 1`) does the controller issue the read request for the replacement block.

### D. Clean Eviction Bypass
If the resident line is clean (`dirty == 0`) or invalid (`valid == 0`):
1. The memory write-back step is completely bypassed.
2. The controller immediately issues the memory read request, saving 3 bus cycles.

---

## VIII. FSM Design and State Transitions

The controller is implemented as a 9-state Mealy/Moore hybrid FSM:

```
                      +------------------+
                      |    STATE_IDLE    |
                      +------------------+
                               | (cpu_req == 1)
                               v
                      +------------------+
                      |   STATE_LOOKUP   |
                      +------------------+
                        /        |       \
        (Hit && !write)/         |        \(Miss)
                      v          |         v
        +----------------+       |       +-------------------+
        | STATE_READ_HIT |       |       | STATE_EVICT_CHECK |
        +----------------+       |       +-------------------+
                \                |         /               \
                 \ (Hit && write)|        / (Clean)         \ (Dirty)
                  v              v       v                   v
                +-----------------+  +-----------------+  +------------------+
                | STATE_WRITE_HIT |  |   MEMORY_READ   |  | STATE_WRITE_BACK |
                +-----------------+  +-----------------+  +------------------+
                         \                    ^                    /
                          \                   | (mem_ready == 1)  /
                           \                  +------------------+
                            \                 | (mem_ready == 1)
                             \                v
                              \      +--------------------+
                               \     | STATE_CACHE_UPDATE |
                                \    +--------------------+
                                 \            /
                                  v          v
                               +----------------+
                               | STATE_COMPLETE |
                               +----------------+
                                       |
                                       v
                                  STATE_IDLE
```

1. **`STATE_IDLE` (4'd0):** Awaits `cpu_req`. Registers CPU inputs (`req_addr`, `req_wdata`, `req_write`). Next: `STATE_LOOKUP`.
2. **`STATE_LOOKUP` (4'd1):** Evaluates `cache_hit = valid[index] && (tag[index] == req_tag)`.
   - Hit & Read $\to$ `STATE_READ_HIT`.
   - Hit & Write $\to$ `STATE_WRITE_HIT`.
   - Miss $\to$ `STATE_EVICT_CHECK`.
3. **`STATE_READ_HIT` (4'd2):** Cache memory drives requested word to `cpu_read_data`. Next: `STATE_COMPLETE`.
4. **`STATE_WRITE_HIT` (4'd3):** Updates target word in cache; asserts `dirty = 1'b1`. Next: `STATE_COMPLETE`.
5. **`STATE_EVICT_CHECK` (4'd4):** Inspects resident line at `req_index`.
   - If `valid && dirty` $\to$ `STATE_WRITE_BACK` (dirty eviction).
   - If `!dirty || !valid` $\to$ `STATE_MEMORY_READ` (clean eviction bypass).
6. **`STATE_WRITE_BACK` (4'd5):** Asserts `mem_req = 1`, `mem_write = 1` with write-back address and 128-bit block data. When `mem_ready == 1` $\to$ `STATE_MEMORY_READ`.
7. **`STATE_MEMORY_READ` (4'd6):** Asserts `mem_req = 1`, `mem_write = 0` with requested block address. When `mem_ready == 1` $\to$ latches block, next: `STATE_CACHE_UPDATE`.
8. **`STATE_CACHE_UPDATE` (4'd7):** Writes fetched block into cache line `req_index`. For read miss: `dirty = 0`, extracts read word. For write miss: merges `req_wdata`, `dirty = 1`. Next: `STATE_COMPLETE`.
9. **`STATE_COMPLETE` (4'd8):** Asserts `cpu_ready = 1'b1` for one clock cycle. Next: `STATE_IDLE`.

---

## IX. Verilog Implementation

The RTL design conforms strictly to IEEE 1364-2001 synthesizable standards:
- **Sequential and Combinational Separation:** State registers and data path registers are updated on `posedge clk or negedge rst_n`. Next-state transitions and control outputs are evaluated in combinational blocks with complete default signal assignments to prevent latch inference.
- **Synthesizable Storage:** Cache arrays are structured as synthesizable 1D and 2D register files, mapping directly to FPGA distributed RAM or standard-cell flip-flops.
- **Back-to-Back Handshake Protocol:** The controller cleanly transitions from `STATE_COMPLETE` to `STATE_IDLE` in 1 cycle, supporting consecutive requests with 0 idle cycles.

---

## X. Simulation Methodology and Verification

The testbench (`testbench/tb_cache_controller.v`) executes twelve targeted verification scenarios with programmatic pass/fail assertions. A 100 MHz clock period (10 ns) was used alongside a 2-cycle deterministic main memory latency model.

```
+---------------------------------------------------------------------------------+
|               SUMMARY OF VERIFICATION SCENARIOS & RESULTS                       |
+-----+---------------------------------------------------+---------+-------------+
| ID  | Scenario Description                              | Checks  | Status      |
+-----+---------------------------------------------------+---------+-------------+
| T1  | Cold Read Miss (Addr 0x0000_0090)                 | 1       | PASS (1/1)  |
| T2  | Read Hit on Resident Block (Addr 0x0000_0094)     | 1       | PASS (1/1)  |
| T3  | Write Hit Confirmed & Dirty Bit Set               | 1       | PASS (1/1)  |
| T4  | Read Hit of Modified Word (0xDEAD_BEEF)           | 1       | PASS (1/1)  |
| T5  | Main Memory Unchanged (Write-Back Proof)          | 1       | PASS (1/1)  |
| T6  | Write Miss & Write-Allocate (Neighbors Intact)    | 3       | PASS (3/3)  |
| T7  | Dirty Eviction Detected on Conflict               | 1       | PASS (1/1)  |
| T8  | Main Memory Verified (Matches Written-Back Data)  | 1       | PASS (1/1)  |
| T9  | Memory Refill & Clean Status Verification         | 2       | PASS (2/2)  |
| T10 | Clean Eviction Without Write-Back                 | 2       | PASS (2/2)  |
| T11 | Reading Previously Written-Back Data              | 1       | PASS (1/1)  |
| T12 | Four Consecutive Back-to-Back CPU Transactions    | 4       | PASS (4/4)  |
+-----+---------------------------------------------------+---------+-------------+
|     | TOTAL VERIFICATION CHECKS EXECUTED                | 19      | PASS (19/19)|
+-----+---------------------------------------------------+---------+-------------+
```

### Detailed Scenario Observations:
1. **Cold Read Miss (T1):** Accessing `0x0000_0090` (Index 1, Tag 1) triggers a cold miss. The controller fetches memory block 9 (`0x1000_0090..0x1000_009C`) and installs it with `valid = 1`, `dirty = 0`.
2. **Read Hit (T2):** Accessing neighbor word `0x0000_0094` in resident block hits immediately in cache without off-chip bus activity.
3. **Write Hit & Dirty Bit (T3, T4):** Writing `0xDEAD_BEEF` to `0x0000_0090` hits in cache. The dirty bit is asserted (`line_dirty = 1`). Reading back returns `0xDEAD_BEEF`.
4. **Write-Back Proof (T5):** Backdoor inspection of main memory at `0x0000_0090` confirms the value is still `0x1000_0090`. Main memory was **not** updated, proving write-back behavior.
5. **Write Miss & Write-Allocate (T6):** Writing `0xCAFE_BABE` to cold address `0x0000_00A0` (Index 2) fetches the block, updates Word 0, leaves neighbor Word 1 (`0x1000_00A4`) intact, and sets `dirty = 1`.
6. **Dirty Eviction & Write-Back (T7, T8):** Accessing `0x0000_0110` (Index 1, Tag 2) conflicts with resident dirty Block A. The controller asserts `status_dirty_evict`, writes `0xDEAD_BEEF` back to memory at `0x0000_0090`, and refills Block B. Memory check verifies `Mem[0x0090] == 0xDEAD_BEEF`.
7. **Clean Eviction (T10):** Evicting clean Block B with Tag 3 bypasses write-back (`evict_flag = 0`).
8. **End-to-End Coherency (T11):** Reading evicted address `0x0000_0090` fetches `0xDEAD_BEEF` from main memory, proving complete coherency.
9. **Back-to-Back Transactions (T12):** Four continuous requests execute with 0 dead cycles.

---

## XI. Results and Discussion

The empirical simulation results demonstrate:
1. **Bus Traffic Reduction:** Write hits incur zero off-chip memory transactions. For workloads exhibiting high temporal and spatial write locality, the write-back policy substantially reduces off-chip memory bus utilization and eliminates processor write stalls compared to a write-through approach.
2. **Deterministic Hit Latency:** Both read hits and write hits complete in 2 clock cycles (1 cycle lookup, 1 cycle execution/handshake).
3. **Hardware Coherency:** Reconstructing victim block addresses from resident tag registers ensures dirty data is never lost or misdirected.
4. **Synthesizability:** The controller and cache memory modules exhibit zero timing loops, no unsynthesizable constructs, and clean synchronous reset initialization.

---

## XII. Individual Contributions

Hrishabh Prajapati (2401020027) led the architecture design, prepared the diagrams, implemented and integrated the Verilog RTL, developed the testbench, and verified the design through simulation. Pratyush Parida (2401010351) finalized the IEEE project report, updated the architecture documentation and README, and documented the prototype demonstration. No technical contributions were reported for the other listed team members.

| Team Member | Roll / Reg. No. | Contribution |
| :--- | :---: | :--- |
| **Hrishabh Prajapati** | 2401020027 | Architecture and diagrams; RTL implementation and integration; testbench development; verification |
| **Jigyasu Kalyan** | 2401010201 | No technical contribution reported |
| **Pratyush Parida** | 2401010351 | IEEE report finalization, architecture documentation, README updates, and prototype demonstration documentation |
| **Preet Vardhan** | 2401010352 | No technical contribution reported |
| **Raghav Gupta** | 2401010365 | No technical contribution reported |

---

## XIII. Conclusion and Future Scope

This project designed, implemented, and verified a **Write-Back Cache Controller** in Verilog-2001. A 9-state Mealy/Moore FSM coordinates request decoding, hit/miss detection, clean eviction bypass, and dirty line write-backs prior to block refills. Cycle-accurate functional verification confirmed that all 19 programmed assertions passed across 12 targeted verification scenarios, validating the write-back, write-allocation, and eviction mechanisms.

### Future Scope (Phase II):
1. **Standard Bus Protocol Compliance:** Interface the controller with standard AMBA AXI4 or Wishbone bus interfaces.
2. **Non-Blocking Caching:** Introduce Miss Status Holding Registers (MSHRs) to support hit-under-miss concurrency.
3. **Multi-Core Snoop Coherence:** Extend the controller with MESI / MOESI snooping bus logic for multi-processor shared-memory systems.
4. **FPGA Prototyping:** Synthesize and physically benchmark the design on a Xilinx Artix-7 or Intel Cyclone IV FPGA board.

---

## XIV. References

1. J. L. Hennessy and D. A. Patterson, *Computer Architecture: A Quantitative Approach*, 6th ed. Cambridge, MA, USA: Morgan Kaufmann, 2017.
2. D. A. Patterson and J. L. Hennessy, *Computer Organization and Design: The Hardware/Software Interface (RISC-V Edition)*. Cambridge, MA, USA: Morgan Kaufmann, 2018.
3. A. J. Smith, "Cache Memories," *ACM Computing Surveys*, vol. 14, no. 3, pp. 473–530, Sep. 1982.
4. M. D. Hill, "Aspects of Cache Memory and Instruction Buffer Performance," Ph.D. dissertation, Dept. Elect. Eng. Comput. Sci., Univ. California, Berkeley, CA, USA, 1987.
5. N. P. Jouppi, "Improving direct-mapped cache performance by the addition of a small fully-associative cache and prefetch buffers," in *Proc. 17th Annual International Symposium on Computer Architecture (ISCA)*, Seattle, WA, USA, 1990, pp. 364–373.
6. S. A. Przybylski, *Cache and Memory Hierarchy Design: A Performance-Directed Approach*. San Francisco, CA, USA: Morgan Kaufmann, 1990.
7. *IEEE Standard for Verilog Hardware Description Language*, IEEE Std 1364-2001, 2001.
