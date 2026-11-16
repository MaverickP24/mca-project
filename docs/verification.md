# Verification Guide: Write-Back Cache Controller

**Testbench:** `testbench/tb_cache_controller.v`  
**Simulation Tool:** Icarus Verilog (`iverilog` v13.0) & VVP runtime  
**Waveform Output:** `simulation/waveforms/cache_simulation.vcd`  
**Overall Result:** **23/23 CHECKS PASSED (100% Pass Rate)**  

---

## 1. Verification Strategy

The verification suite is implemented as a fully self-checking, cycle-accurate testbench (`tb_cache_controller.v`). Rather than relying solely on visual waveform inspection or unverified print statements, the testbench dynamically executes transactions, samples hardware signals during synchronous handshakes, compares values against mathematically derived golden references, and asserts pass/fail status per check.

### Key Verification Features
1. **Self-Checking Assertions:** Explicit comparisons between returned data and golden memory models.
2. **Backdoor Memory Verification:** Directly inspects physical memory arrays to guarantee write-back operations update backing memory.
3. **Deadlock Watchdog:** A 100,000 ns simulation timeout aborts the testbench if an FSM state becomes deadlocked.
4. **Automated VCD Waveform Generation:** Dumps all internal signals to `simulation/waveforms/cache_simulation.vcd` for GTKWave inspection.

---

## 2. Test Scenarios and Results

### Scenario 1: Read Miss Followed by Read Hit
- **Objective:** Verify cold miss detection, main memory block fetch, cache line installation, and subsequent zero-latency read hit to a neighbor word in the same block.
- **Transactions:**
  1. Read from `0x0000_0040` (Set 0, Tag 1, Word 0): Cold miss (`status_hit = 0`), loads 4-word block from main memory, returns `0x1000_0040`.
  2. Read from `0x0000_0044` (Set 0, Tag 1, Word 1): Read hit (`status_hit = 1`, no memory bus request), returns `0x1000_0044`.
- **Status:** `[PASS]` (Checks S1.1, S1.2)

### Scenario 2: Write Hit and Dirty-Bit Verification
- **Objective:** Verify that a write to an already cached address updates the cache word, asserts the line's dirty bit, and leaves main memory unmodified (write-back policy).
- **Transactions:**
  1. Write `0xDEAD_BEEF` to `0x0000_0040`. Verified that `status_hit = 1` and `way0_dirty = 1`.
  2. Read back `0x0000_0040`. Returns `0xDEAD_BEEF` on a cache hit.
- **Status:** `[PASS]` (Checks S2.1, S2.2)

### Scenario 3: Write Miss with Write Allocation
- **Objective:** Verify that a write miss allocates a line, fetches the target block from memory, updates the requested word with write data, leaves untouched words intact, and sets the dirty bit.
- **Transactions:**
  1. Write `0xCAFE_BABE` to `0x0000_0080` (Set 0, Tag 2, Word 0). Confirmed miss, allocation into Way 1, and dirty bit assertion.
  2. Read from neighbor word `0x0000_0084` (Word 1). Verified read hit returning memory value `0x1000_0084`.
  3. Read from written word `0x0000_0080` (Word 0). Verified read hit returning written value `0xCAFE_BABE`.
- **Status:** `[PASS]` (Checks S3.1, S3.2, S3.3)

### Scenarios 4 & 5: Dirty Eviction & Memory Write-Back Verification
- **Objective:** Verify that replacing a dirty cache line forces the controller to write the entire 128-bit block back to main memory before refilling the new block.
- **Setup:** Set 0 currently contains:
  - Way 0: Tag 1 (`0x0000_0040`), dirty=1, modified word = `0xDEAD_BEEF`.
  - Way 1: Tag 2 (`0x0000_0080`), dirty=1 (MRU).
  - LRU points to Way 0.
- **Transactions:**
  1. Backdoor check of main memory before eviction: `Mem[0x0040] == 0x1000_0040` (unmodified).
  2. Read `0x0000_00C0` (Set 0, Tag 3). Forces eviction of Way 0.
  3. Verified `status_dirty_evict == 1` asserted and memory write-back executed.
  4. Backdoor check of main memory after eviction: `Mem[0x0040] == 0xDEAD_BEEF` (data safely written to memory).
  5. Verified new block read returns `0x1000_00C0`.
- **Status:** `[PASS]` (Checks S4.0, S4.1, S4.2, S5.1)

### Scenario 6: Clean Cache Line Eviction without Write-Back
- **Objective:** Verify that evicting an unmodified (clean) cache line bypasses the memory write-back state, saving off-chip bus cycles.
- **Setup:** Set 1 filled with clean blocks in Way 0 (`0x0000_0050`) and Way 1 (`0x0000_0090`).
- **Transactions:**
  1. Read `0x0000_00D0` (Set 1, Tag 3). Forces replacement of clean Way 0.
  2. Verified `status_dirty_evict == 0` (FSM transitions directly from `EVICT_CHECK` to `MEMORY_READ`).
  3. Verified replacement block data returns `0x1000_00D0`.
- **Status:** `[PASS]` (Checks S6.1, S6.2, S6.3, S6.4)

### Scenario 7: LRU Replacement Policy Verification
- **Objective:** Prove that touching an existing line promotes it to MRU and protects it from replacement, correctly evicting the least recently used line.
- **Transactions:**
  1. Load Block X (`0x0000_0060`, Way 0) and Block Y (`0x0000_00A0`, Way 1) into Set 2.
  2. Touch Block X (Read hit). This promotes Way 0 to MRU, making Way 1 the LRU victim.
  3. Access Block Z (`0x0000_00E0`, Set 2).
  4. Verified Way 1 (Block Y) is replaced with Block Z.
  5. Verified Block X is still present in cache (Read Hit).
  6. Verified Block Y was evicted (Read Miss).
- **Status:** `[PASS]` (Checks S7.1, S7.2, S7.3, S7.4)

### Scenario 8: Multiple Consecutive Back-to-Back Transactions
- **Objective:** Stress-test controller pipeline transitions with 0 idle clock cycles between `cpu_ready` and the subsequent `cpu_req`.
- **Transactions:**
  1. Read `0x0000_0070` (Cold miss, fetches block).
  2. Next cycle write `0x5555_AAAA` to `0x0000_0074` (Write hit).
  3. Next cycle read `0x0000_0074` (Read hit, returns `0x5555_AAAA`).
  4. Next cycle read `0x0000_0078` (Read hit, returns `0x1000_0078`).
- **Status:** `[PASS]` (Checks S8.1, S8.2, S8.3, S8.4)

---

## 3. Summary Results Table

| Check ID | Description | Expected Value | Observed Value | Result |
| :---: | :--- | :---: | :---: | :---: |
| **S1.1** | Cold Read Miss (`0x0040`) | `0x10000040`, Miss | `0x10000040`, Miss | **PASS** |
| **S1.2** | Neighbor Word Read Hit (`0x0044`) | `0x10000044`, Hit | `0x10000044`, Hit | **PASS** |
| **S2.1** | Write Hit & Dirty Bit Set | Hit, Dirty=1 | Hit, Dirty=1 | **PASS** |
| **S2.2** | Read Hit of Modified Word | `0xDEADBEEF`, Hit | `0xDEADBEEF`, Hit | **PASS** |
| **S3.1** | Write Miss & Allocate | Miss, Dirty=1 | Miss, Dirty=1 | **PASS** |
| **S3.2** | Neighbor Word Hit on Allocated Block | `0x10000084`, Hit | `0x10000084`, Hit | **PASS** |
| **S3.3** | Read Written Word in Allocated Block | `0xCAFEBABE`, Hit | `0xCAFEBABE`, Hit | **PASS** |
| **S4.0** | Pre-Eviction Main Memory Verification | `0x10000040` | `0x10000040` | **PASS** |
| **S4.1** | Dirty Eviction Pulse Detection | Evict=1, Miss | Evict=1, Miss | **PASS** |
| **S4.2** | Replacement Block Read (`0x00C0`) | `0x100000C0`, Miss | `0x100000C0`, Miss | **PASS** |
| **S5.1** | Post-Eviction Main Memory Verification | `0xDEADBEEF` | `0xDEADBEEF` | **PASS** |
| **S6.1** | Cold Read Set 1 (Way 0) | `0x10000050`, Miss | `0x10000050`, Miss | **PASS** |
| **S6.2** | Cold Read Set 1 (Way 1) | `0x10000090`, Miss | `0x10000090`, Miss | **PASS** |
| **S6.3** | Clean Eviction Bypass Write-Back | Evict=0, Miss | Evict=0, Miss | **PASS** |
| **S6.4** | Replacement Data Fetched | `0x100000D0`, Miss | `0x100000D0`, Miss | **PASS** |
| **S7.1** | Touch Block X (MRU Update) | `0x10000060`, Hit | `0x10000060`, Hit | **PASS** |
| **S7.2** | Evict LRU Victim (Block Z Loaded) | `0x100000E0`, Miss | `0x100000E0`, Miss | **PASS** |
| **S7.3** | Block X Retained (Hit) | `0x10000060`, Hit | `0x10000060`, Hit | **PASS** |
| **S7.4** | Block Y Evicted (Miss) | `0x100000A0`, Miss | `0x100000A0`, Miss | **PASS** |
| **S8.1** | Back-to-Back Trans 1 (Read Miss) | `0x10000070`, Miss | `0x10000070`, Miss | **PASS** |
| **S8.2** | Back-to-Back Trans 2 (Write Hit) | Hit=1 | Hit=1 | **PASS** |
| **S8.3** | Back-to-Back Trans 3 (Read Hit Written) | `0x5555AAAA`, Hit | `0x5555AAAA`, Hit | **PASS** |
| **S8.4** | Back-to-Back Trans 4 (Read Neighbor) | `0x10000078`, Hit | `0x10000078`, Hit | **PASS** |

---

## 4. Running the Verification Suite

To run the simulation from the terminal:
```bash
make test
```

To view the generated waveforms:
```bash
make wave
```
or open `simulation/waveforms/cache_simulation.vcd` directly in GTKWave.

