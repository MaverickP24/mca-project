# Architecture Specification: Write-Back Cache Controller

**Project:** 2-Way Set-Associative Write-Back Cache Controller  
**Course:** MCA Phase I Evaluation  
**Hardware Description Language:** Verilog-2001 (Synthesizable RTL)  
**Simulation Environment:** Icarus Verilog (`iverilog`) & GTKWave  

---

## 1. Architectural Overview

The memory hierarchy of modern computer systems relies on high-speed cache memory to bridge the substantial performance gap (the "memory wall") between the high-frequency central processing unit (CPU) and relatively slow dynamic RAM (DRAM).

This project implements a **2-way set-associative write-back cache controller** with **write-allocate** policy and **least recently used (LRU)** replacement logic. The design is structured into modular, synthesizable Verilog modules with a decoupled behavioral main memory model that simulates realistic bus transaction latencies.

```
+-------------------------------------------------------------------------+
|                               top_module                                |
|                                                                         |
|  +--------------------+        +-------------------------------------+  |
|  |                    |<------>|            cache_memory             |  |
|  |  cache_controller  |        |  - Way 0 Tag, Valid, Dirty, Data    |  |
|  |     (9-State FSM)  |        |  - Way 1 Tag, Valid, Dirty, Data    |  |
|  |                    |        |  - Per-Set 1-Bit LRU Array          |  |
|  +--------------------+        +-------------------------------------+  |
|            ^                                                            |
|            | 128-bit Block Bus (mem_req, mem_ready)                     |
|            v                                                            |
|  +-------------------------------------------------------------------+  |
|  |                     main_memory (1024 Blocks)                     |  |
|  +-------------------------------------------------------------------+  |
+-------------------------------------------------------------------------+
```

---

## 2. Address Decomposition & Mathematical Derivation

The CPU issues 32-bit byte-addressed memory requests (`cpu_addr[31:0]`). The cache parameters dictate the bit allocations:

- **Address Bus Width ($A$):** 32 bits (`cpu_addr[31:0]`)
- **Word Width ($W$):** 32 bits (4 bytes)
- **Words per Block ($K$):** 4 words
- **Block Size ($B$):** $4 \times 4 = 16$ bytes
- **Number of Sets ($S$):** 4 sets
- **Number of Ways ($N$):** 2 ways per set
- **Total Cache Lines:** $4 \times 2 = 8$ lines
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

3. **Set Index ($\text{Index}$):**
   $$\text{Index} = \log_2(\text{Number of Sets}) = \log_2(4) = 2\text{ bits} \quad \implies \quad \texttt{cpu\_addr[5:4]}$$
   Selects one of the 4 sets (`Set 0`, `Set 1`, `Set 2`, `Set 3`).

4. **Tag ($\text{Tag}$):**
   $$\text{Tag} = 32 - (\text{Index} + \text{WO} + \text{BO}) = 32 - (2 + 2 + 2) = 26\text{ bits} \quad \implies \quad \texttt{cpu\_addr[31:6]}$$

### Summary Address Map

| Field | Bit Range | Width | Description |
| :--- | :---: | :---: | :--- |
| **Tag** | `[31:6]` | 26 bits | Distinguishes memory blocks mapped to the same set |
| **Index** | `[5:4]` | 2 bits | Selects cache set ($0$ to $3$) |
| **Word Offset** | `[3:2]` | 2 bits | Selects target 32-bit word ($0$ to $3$) in the 128-bit block |
| **Byte Offset** | `[1:0]` | 2 bits | Byte selection within 32-bit word (always `00` for word access) |

> **Note on 16-Bit Tag Configurations:** In 22-bit address spaces (common in embedded architectures), $16 + 2 + 2 + 2 = 22\text{ bits}$ produces a 16-bit tag. For standard 32-bit systems, the tag is 26 bits. Our implementation parameterizes `TAG_WIDTH = ADDR_WIDTH - INDEX_WIDTH - WORD_OFFSET_WIDTH - BYTE_OFFSET_WIDTH`, ensuring total mathematical consistency.

---

## 3. Storage Hierarchy & Line Format

Each cache line comprises:
- **Valid Bit (1 bit):** Indicates if the cache line holds valid data.
- **Dirty Bit (1 bit):** Indicates if the cached data has been modified by the CPU and differs from main memory.
- **Tag Register (26 bits):** Stores the address tag of the currently resident memory block.
- **Data Block (128 bits):** Stores 4 contiguous 32-bit data words (`Word 0` to `Word 3`).

```
+-------+-------+--------------------+---------------------------------------------------+
| Valid | Dirty |    Tag (26 bits)   |            Data Block (128 bits / 4 Words)        |
| (1 b) | (1 b) |    [31:6]          |  Word 3 [127:96] | Word 2 [95:64] | W1 | W0 [31:0] |
+-------+-------+--------------------+---------------------------------------------------+
```

### LRU Array
For a 2-way set-associative cache, true LRU requires exactly **1 bit per set**:
- `lru[set] == 1'b0`: Way 0 is LRU (candidate victim for replacement); Way 1 is MRU.
- `lru[set] == 1'b1`: Way 1 is LRU (candidate victim for replacement); Way 0 is MRU.

When any way $W$ in set $S$ is accessed (read or write):
$$\texttt{lru}[S] \leftarrow \sim W$$
The non-accessed way becomes the LRU.

---

## 4. Cache Policies

### A. Write Policy: Write-Back
- On a **Write Hit**, only the cache line is modified, and its dirty bit is asserted (`dirty = 1'b1`).
- Main memory is **not** immediately updated.
- Main memory is updated only when a dirty line is evicted by the replacement algorithm.
- **Benefit:** Minimizes off-chip memory traffic, saving bus bandwidth and power.

### B. Write Allocation: Write-Allocate
- On a **Write Miss**, the required block is fetched from main memory into the cache line.
- The target word is updated in the cache with the CPU's write data.
- The dirty bit is marked `1'b1`.
- **Benefit:** Subsequent reads or writes to neighboring words in that block will result in high-speed cache hits (exploiting spatial locality).

### C. Eviction Logic: Two-Level Victim Selection
1. **Cold Line Priority:** If Way 0 is invalid (`valid == 0`), Way 0 is selected. Otherwise, if Way 1 is invalid, Way 1 is selected. This avoids evicting live data while empty slots exist.
2. **LRU Selection:** If both ways are valid, the victim is chosen strictly by `lru[set]`.
3. **Clean Eviction:** If the selected victim is clean (`dirty == 0`), write-back is bypassed, transitioning directly to memory fetch.
4. **Dirty Eviction:** If the selected victim is dirty (`valid == 1 && dirty == 1`), the controller writes the victim block (128 bits) back to `{victim_tag, set_index, 4'b0000}` before refilling.

---

## 5. Module Descriptions & Interfaces

### 1. `cache_controller.v`
- Implements the 9-state Mealy/Moore hybrid FSM.
- Manages CPU request latching, hit/miss determination, eviction sequencing, memory refill, and handshake generation.
- **Key Parameters:** `ADDR_WIDTH (32)`, `DATA_WIDTH (32)`, `BLOCK_WIDTH (128)`.

### 2. `cache_memory.v`
- Contains dual-way storage registers for tags, valid bits, dirty bits, data blocks, and LRU bits.
- Provides combinational lookup outputs (`hit`, `hit_way`, `hit_data`, `victim_way`, `victim_valid`, `victim_dirty`, `victim_block_data`).
- Synchronous write ports for single-word update (write hit) and 128-bit block refill (miss allocation).

### 3. `main_memory.v`
- Behavioral 128-bit block memory (1024 blocks = 16 KB).
- Emulates physical DRAM latency with a configurable 2-cycle wait counter.
- Deterministically initialized such that each word equals `(block_index * 16) + offset + 32'h1000_0000`.
- Provides backdoor function `get_word(addr)` for testbench verification.

### 4. `top_module.v`
- Top-level structural integration wrapping the controller, cache memory, and main memory.
- Exposes standard CPU memory bus signals and hardware status flags.

