# Verification Guide: Write-Back Cache Controller

**Testbench:** `testbench/tb_cache_controller.v`
**Simulation Tool:** Icarus Verilog (`iverilog` v13.0) & VVP runtime
**Waveform Output:** `simulation/waveforms/cache_simulation.vcd`
**Overall Result:** **19/19 CHECKS PASSED (100% Pass Rate)**

---

## 1. Verification Strategy

The verification suite is implemented as a fully self-checking, cycle-accurate testbench (`tb_cache_controller.v`). It verifies the hardware implementation of the **Write-Back Cache Controller** across twelve critical operational scenarios, using programmatic assertions, direct backdoor memory inspection, and timeout watchdog monitoring.

### Key Verification Features
1. **Self-Checking Assertions:** Explicit comparisons between returned data and golden memory models.
2. **Backdoor Memory Verification:** Directly inspects physical memory arrays to guarantee that write hits do NOT update memory immediately (write-back proof) and that dirty evictions properly flush modified lines.
3. **Deadlock Watchdog:** A 100,000 ns simulation timeout aborts the testbench if an FSM state becomes deadlocked.
4. **Automated VCD Waveform Generation:** Dumps all internal signals to `simulation/waveforms/cache_simulation.vcd` for GTKWave inspection.

---

## 2. Test Scenarios and Results

### Test 1: Cold Read Miss
- **Objective:** Verify cold miss detection on an uninitialized line, memory block fetch, cache line installation, and data delivery to the CPU.
- **Transaction:** Read from `0x0000_0090` (Index 1, Tag 1, Word 0).
- **Result:** Cold miss (`status_hit = 0`), loads 4-word block from main memory, returns `0x1000_0090`. Line 1 becomes valid with dirty = 0.
- **Status:** `[PASS]` (Check T1.1)

### Test 2: Read Hit After Refill
- **Objective:** Verify that subsequent access to a neighboring word in the resident block hits in cache without main memory access.
- **Transaction:** Read from `0x0000_0094` (Index 1, Tag 1, Word 1).
- **Result:** Read hit (`status_hit = 1`, no memory bus request), returns `0x1000_0094`.
- **Status:** `[PASS]` (Check T2.1)

### Tests 3 & 4: Write Hit and Dirty-Bit Setting
- **Objective:** Verify that a write to an already cached address updates the cache word, asserts the line's dirty bit, and leaves main memory unmodified.
- **Transactions:**
  1. Write `0xDEAD_BEEF` to `0x0000_0090`. Verified that `status_hit = 1` and `line_dirty = 1`.
  2. Read back `0x0000_0090`. Returns `0xDEAD_BEEF` on a cache hit.
- **Status:** `[PASS]` (Checks T3.1, T4.1)

### Test 5: Main Memory Unchanged Immediately After Write Hit (Write-Back Proof)
- **Objective:** Prove the Write-Back policy by confirming that backing main memory is NOT modified during a write hit.
- **Verification:** Backdoor read from main memory array: `Mem[0x0000_0090]`.
- **Result:** Value is `0x1000_0090` (original unwritten data). Proves write was buffered in cache only.
- **Status:** `[PASS]` (Check T5.1)

### Test 6: Write Miss with Write Allocation
- **Objective:** Verify that a write miss allocates the cache line, fetches the target block from memory, updates the requested word with write data, leaves untouched words intact, and sets the dirty bit.
- **Transactions:**
  1. Write `0xCAFE_BABE` to cold address `0x0000_00A0` (Index 2, Tag 1, Word 0). Confirmed miss, allocation into Line 2, and dirty bit assertion.
  2. Read from neighbor word `0x0000_00A4` (Word 1). Verified read hit returning memory value `0x1000_00A4`.
  3. Read from written word `0x0000_00A0` (Word 0). Verified read hit returning written value `0xCAFE_BABE`.
- **Status:** `[PASS]` (Checks T6.1, T6.2, T6.3)

### Tests 7 & 8: Dirty Eviction & Memory Write-Back
- **Objective:** Verify that replacing a dirty cache line forces the controller to write the entire 128-bit block back to main memory before refilling the new block.
- **Setup:** Line 1 holds Block A (`0x0000_0090`, Tag 1) with modified word `0xDEAD_BEEF` (dirty=1).
- **Transactions:**
  1. Read `0x0000_0110` (Index 1, Tag 2). Forces conflict eviction of resident dirty Block A.
  2. Verified `status_dirty_evict == 1` asserted and memory write-back executed.
  3. Backdoor check of main memory: `Mem[0x0090] == 0xDEAD_BEEF` (data safely written to memory).
- **Status:** `[PASS]` (Checks T7.1, T8.1)

### Test 9: Memory Refill After Eviction
- **Objective:** Confirm that the newly fetched replacement block is properly installed and clean.
- **Verification:** Read data returns `0x1000_0110`; Line 1 is marked `valid = 1`, `dirty = 0`.
- **Status:** `[PASS]` (Checks T9.1, T9.2)

### Test 10: Clean Eviction Without Write-Back
- **Objective:** Verify that evicting an unmodified (clean) cache line bypasses the memory write-back state, saving off-chip bus cycles.
- **Transaction:** Read `0x0000_0190` (Index 1, Tag 3) while Line 1 holds clean Block B.
- **Result:** Verified `status_dirty_evict == 0` (FSM transitions directly from `EVICT_CHECK` to `MEMORY_READ`). Replacement data `0x1000_0190` returned.
- **Status:** `[PASS]` (Checks T10.1, T10.2)

### Test 11: Reading Previously Written-Back Data (End-to-End Coherency)
- **Objective:** Verify that data written back during dirty eviction can be read back from main memory, proving end-to-end memory coherency.
- **Transaction:** Read `0x0000_0090` (Block A, currently not in cache).
- **Result:** Fetches `0xDEAD_BEEF` from main memory.
- **Status:** `[PASS]` (Check T11.1)

### Test 12: Multiple Consecutive Back-to-Back Transactions
- **Objective:** Stress-test controller pipeline transitions with 0 idle clock cycles between `cpu_ready` and the subsequent `cpu_req`.
- **Transactions:**
  1. Read `0x0000_0030` (Cold miss, fetches block).
  2. Next cycle write `0x5555_AAAA` to `0x0000_0034` (Write hit).
  3. Next cycle read `0x0000_0034` (Read hit, returns `0x5555_AAAA`).
  4. Next cycle read `0x0000_0038` (Read hit, returns `0x1000_0038`).
- **Status:** `[PASS]` (Checks T12.1, T12.2, T12.3, T12.4)

---

## 3. Summary Results Table

| Check ID | Description | Expected Value | Observed Value | Result |
| :---: | :--- | :---: | :---: | :---: |
| **T1.1** | Cold Read Miss (`0x0090`) | `0x10000090`, Miss | `0x10000090`, Miss | **PASS** |
| **T2.1** | Neighbor Word Read Hit (`0x0094`) | `0x10000094`, Hit | `0x10000094`, Hit | **PASS** |
| **T3.1** | Write Hit Confirmed & Dirty Bit Set | Hit, Dirty=1 | Hit, Dirty=1 | **PASS** |
| **T4.1** | Read Hit of Modified Word | `0xDEADBEEF`, Hit | `0xDEADBEEF`, Hit | **PASS** |
| **T5.1** | Main Memory Unchanged (Write-Back Proof) | `0x10000090` | `0x10000090` | **PASS** |
| **T6.1** | Write Miss & Allocate | Miss, Dirty=1 | Miss, Dirty=1 | **PASS** |
| **T6.2** | Neighbor Word Hit on Allocated Block | `0x100000A4`, Hit | `0x100000A4`, Hit | **PASS** |
| **T6.3** | Read Written Word in Allocated Block | `0xCAFEBABE`, Hit | `0xCAFEBABE`, Hit | **PASS** |
| **T7.1** | Dirty Eviction Pulse Detection | Evict=1, Miss | Evict=1, Miss | **PASS** |
| **T8.1** | Post-Eviction Main Memory Verification | `0xDEADBEEF` | `0xDEADBEEF` | **PASS** |
| **T9.1** | Replacement Block Data Read | `0x10000110`, Miss | `0x10000110`, Miss | **PASS** |
| **T9.2** | Refilled Line Status (Clean) | Valid=1, Dirty=0 | Valid=1, Dirty=0 | **PASS** |
| **T10.1**| Clean Eviction Bypass Write-Back | Evict=0, Miss | Evict=0, Miss | **PASS** |
| **T10.2**| Clean Replacement Data Fetched | `0x10000190`, Miss | `0x10000190`, Miss | **PASS** |
| **T11.1**| Read Evicted Block from Main Memory | `0xDEADBEEF`, Miss | `0xDEADBEEF`, Miss | **PASS** |
| **T12.1**| Back-to-Back Trans 1 (Read Miss) | `0x10000030`, Miss | `0x10000030`, Miss | **PASS** |
| **T12.2**| Back-to-Back Trans 2 (Write Hit) | Hit=1 | Hit=1 | **PASS** |
| **T12.3**| Back-to-Back Trans 3 (Read Hit Written) | `0x5555AAAA`, Hit | `0x5555AAAA`, Hit | **PASS** |
| **T12.4**| Back-to-Back Trans 4 (Read Neighbor) | `0x10000038`, Hit | `0x10000038`, Hit | **PASS** |

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
