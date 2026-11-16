# Architecture Specification: Write-Back Cache Controller

**Project:** Write-Back Cache Controller
**Course:** MCA Phase I Evaluation
**Hardware Description Language:** Verilog-2001 (Synthesizable RTL)
**Simulation Environment:** Icarus Verilog (`iverilog` v13.0) & GTKWave

---

## 1. Architectural Overview

The memory hierarchy of modern computer systems relies on high-speed cache memory to bridge the substantial performance gap (the "memory wall") between the high-frequency central processing unit (CPU) and relatively slow dynamic RAM (DRAM).

This project implements a **Write-Back Cache Controller** with **write-allocation** and dedicated **dirty-bit management**. A direct-mapped cache organization is employed as an educational, clean architecture that places primary emphasis on the write-back mechanism, dirty-line tracking, and backing memory coherency.

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

---

## 2. Address Decomposition & Mathematical Derivation

The CPU issues 32-bit byte-addressed memory requests (`cpu_addr[31:0]`). The direct-mapped cache parameters dictate the bit allocations:

- **Address Bus Width ($A$):** 32 bits (`cpu_addr[31:0]`)
- **Word Width ($W$):** 32 bits (4 bytes)
- **Words per Block ($K$):** 4 words
- **Block Size ($B$):** $4 \times 4 = 16$ bytes (128 bits)
- **Number of Cache Lines ($M$):** 8 lines
- **Total Data Capacity:** $8 \times 16\text{ bytes} = 128\text{ bytes}$ (32 words)

### Bit Field Allocation

$$\text{Address Width} = \text{Tag Width} + \text{Index Width} + \text{Word Offset Width} + \text{Byte Offset Width}$$

1. **Byte Offset ($\text{BO}$):**
   $$\text{BO} = \log_2(\text{Bytes per Word}) = \log_2(4) = 2\text{ bits} \quad \implies \quad \texttt{cpu\_addr[1:0]}$$
   Since word-aligned 32-bit operations are performed, `cpu_addr[1:0]` is expected to be `2'b00`.

2. **Word Offset ($\text{WO}$):**
   $$\text{WO} = \log_2(\text{Words per Block}) = \log_2(4) = 2\text{ bits} \quad \implies \quad \texttt{cpu\_addr[3:2]}$$
   Selects one of the 4 words within a 128-bit cache line block:
   - `2'b00`: Word 0 (`data[31:0]`)
   - `2'b01`: Word 1 (`data[63:32]`)
   - `2'b10`: Word 2 (`data[95:64]`)
   - `2'b11`: Word 3 (`data[127:96]`)

3. **Cache Index ($\text{Index}$):**
   $$\text{Index} = \log_2(\text{Number of Lines}) = \log_2(8) = 3\text{ bits} \quad \implies \quad \texttt{cpu\_addr[6:4]}$$
   Selects one of the 8 cache lines ($0$ to $7$).

4. **Tag ($\text{Tag}$):**
   $$\text{Tag} = 32 - (\text{Index} + \text{WO} + \text{BO}) = 32 - (3 + 2 + 2) = 25\text{ bits} \quad \implies \quad \texttt{cpu\_addr[31:7]}$$

### Summary Address Map

| Field | Bit Range | Width | Description |
| :--- | :---: | :---: | :--- |
| **Tag** | `[31:7]` | 25 bits | Distinguishes memory blocks mapped to the same cache line |
| **Index** | `[6:4]` | 3 bits | Selects cache line ($0$ to $7$) |
| **Word Offset** | `[3:2]` | 2 bits | Selects target 32-bit word ($0$ to $3$) in the 128-bit block |
| **Byte Offset** | `[1:0]` | 2 bits | Byte selection within 32-bit word (always `00` for word access) |

---

## 3. Storage Hierarchy & Line Format

Each cache line comprises:
- **Valid Bit (1 bit):** Indicates if the cache line holds valid data.
- **Dirty Bit (1 bit):** Indicates if the cached data has been modified by the CPU and differs from main memory.
- **Tag Register (25 bits):** Stores the address tag of the currently resident memory block.
- **Data Block (128 bits):** Stores 4 contiguous 32-bit data words (`Word 0` to `Word 3`).

```
+-------+-------+--------------------+---------------------------------------------------+
| Valid | Dirty |    Tag (25 bits)   |            Data Block (128 bits / 4 Words)        |
| (1 b) | (1 b) |    [31:7]          |  Word 3 [127:96] | Word 2 [95:64] | W1 | W0 [31:0] |
+-------+-------+--------------------+---------------------------------------------------+
```

---

## 4. Cache Policies

### A. Write Policy: Write-Back
- On a **Write Hit**, only the cache line is modified, and its dirty bit is asserted (`dirty = 1'b1`).
- Main memory is **not** immediately updated.
- Main memory is updated only when a dirty line is evicted by a subsequent conflicting access.
- **Benefit:** Minimizes off-chip memory traffic, saving bus bandwidth and power.

### B. Write Allocation: Write-Allocate
- On a **Write Miss**, the required block is fetched from main memory into the cache line.
- The target word is updated in the cache with the CPU's write data.
- The dirty bit is marked `1'b1`.
- **Benefit:** Subsequent reads or writes to neighboring words in that block will result in high-speed cache hits (exploiting spatial locality).

### C. Eviction Logic
When a miss occurs at index $I$:
1. The resident line at index $I$ is evaluated.
2. **Clean Eviction:** If the resident line is clean (`dirty == 0`) or uninitialized (`valid == 0`), write-back is bypassed, transitioning directly to memory block read.
3. **Dirty Eviction:** If the resident line is dirty (`valid == 1 && dirty == 1`), the controller writes the resident block (128 bits) back to its original address $\{\texttt{line\_tag}, \text{index}, 4'b0000\}$ before refilling the new block.

---

## 5. Module Descriptions & Interfaces

### 1. `cache_controller.v`
- Implements the 9-state Mealy/Moore hybrid FSM.
- Manages CPU request latching, hit/miss determination, eviction sequencing, memory refill, and handshake generation.
- **Key Parameters:** `ADDR_WIDTH (32)`, `DATA_WIDTH (32)`, `NUM_LINES (8)`, `INDEX_WIDTH (3)`, `TAG_WIDTH (25)`, `BLOCK_WIDTH (128)`.

### 2. `cache_memory.v`
- Direct-mapped storage registers for tags, valid bits, dirty bits, and 128-bit data blocks.
- Provides combinational lookup outputs (`hit`, `hit_data`, `line_valid`, `line_dirty`, `line_tag`, `line_block_data`).
- Synchronous write ports for single-word update (write hit) and 128-bit block refill (miss allocation).

### 3. `main_memory.v`
- Behavioral 128-bit block memory (1,024 blocks = 16 KB total storage).
- Emulates physical DRAM latency with a configurable 2-cycle wait counter.
- Decodes address bits `[13:4]` (10 bits) to select among its 1,024 blocks. Addresses beyond 16 KB wrap within this window.
- Deterministically initialized such that each word equals `(block_index * 16) + offset + 32'h1000_0000`.
- Provides backdoor function `get_word(addr)` for testbench verification.
- *Note:* This is a behavioral simulation model for cycle-accurate functional verification; physical FPGA/ASIC synthesis and hardware validation have not been performed in Phase I.

### 4. `top_module.v`
- Top-level structural integration wrapping the controller, cache memory, and main memory.
- Exposes standard CPU memory bus signals and hardware status flags.
