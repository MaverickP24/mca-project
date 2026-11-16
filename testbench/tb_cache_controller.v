// ============================================================================
// Module Name:  tb_cache_controller
// Project:      Write-Back Cache Controller — MCA Phase I
// Description:  Comprehensive self-checking testbench for Write-Back Cache Controller.
//               Validates all core write-back mechanisms:
//               1. Cold read miss.
//               2. Read hit after refill.
//               3. Write hit.
//               4. Dirty-bit setting.
//               5. Main memory unchanged immediately after write hit (write-back proof).
//               6. Write miss with write allocation.
//               7. Dirty cache-line eviction.
//               8. Correct write-back to original memory block address.
//               9. Correct memory refill after eviction.
//               10. Clean eviction without write-back.
//               11. Reading previously written-back data (end-to-end coherency).
//               12. Multiple consecutive back-to-back CPU transactions.
// Language:     Verilog-2001
// ============================================================================

`timescale 1ns / 1ps

module tb_cache_controller;

    // ------------------------------------------------------------------------
    // Parameters & Signals
    // ------------------------------------------------------------------------
    parameter ADDR_WIDTH        = 32;
    parameter DATA_WIDTH        = 32;
    parameter WORDS_PER_BLOCK   = 4;
    parameter NUM_LINES         = 8;
    parameter BYTE_OFFSET_WIDTH = 2;
    parameter WORD_OFFSET_WIDTH = 2;
    parameter INDEX_WIDTH       = 3; // log2(8) = 3
    parameter TAG_WIDTH         = 25; // 32 - 3 - 2 - 2 = 25
    parameter BLOCK_WIDTH       = 128;
    parameter CLK_PERIOD        = 10; // 100 MHz clock

    reg                   clk;
    reg                   rst_n;

    // CPU Bus
    reg                   cpu_req;
    reg                   cpu_write;
    reg  [ADDR_WIDTH-1:0] cpu_addr;
    reg  [DATA_WIDTH-1:0] cpu_write_data;
    wire [DATA_WIDTH-1:0] cpu_read_data;
    wire                  cpu_ready;

    // Status Signals
    wire                  status_hit;
    wire                  status_miss;
    wire                  status_dirty_evict;
    wire [3:0]            current_fsm_state;
    wire                  mem_req_active;
    wire                  mem_ready_active;

    // Verification Bookkeeping
    integer total_tests;
    integer passed_tests;
    integer failed_tests;

    // ------------------------------------------------------------------------
    // Device Under Test (DUT)
    // ------------------------------------------------------------------------
    top_module #(
        .ADDR_WIDTH        (ADDR_WIDTH),
        .DATA_WIDTH        (DATA_WIDTH),
        .WORDS_PER_BLOCK   (WORDS_PER_BLOCK),
        .NUM_LINES         (NUM_LINES),
        .BYTE_OFFSET_WIDTH (BYTE_OFFSET_WIDTH),
        .WORD_OFFSET_WIDTH (WORD_OFFSET_WIDTH),
        .INDEX_WIDTH       (INDEX_WIDTH),
        .TAG_WIDTH         (TAG_WIDTH),
        .BLOCK_WIDTH       (BLOCK_WIDTH),
        .MEM_BLOCKS        (1024),
        .MEM_LATENCY       (2)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .cpu_req            (cpu_req),
        .cpu_write          (cpu_write),
        .cpu_addr           (cpu_addr),
        .cpu_write_data     (cpu_write_data),
        .cpu_read_data      (cpu_read_data),
        .cpu_ready          (cpu_ready),
        .status_hit         (status_hit),
        .status_miss        (status_miss),
        .status_dirty_evict (status_dirty_evict),
        .current_fsm_state  (current_fsm_state),
        .mem_req_active     (mem_req_active),
        .mem_ready_active   (mem_ready_active)
    );

    // ------------------------------------------------------------------------
    // Clock Generation
    // ------------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // ------------------------------------------------------------------------
    // Watchdog Timer to Catch Deadlocks
    // ------------------------------------------------------------------------
    initial begin
        #100000; // 100,000 ns
        $display("\n========================================================");
        $display("ERROR: Watchdog timer expired! Simulation deadlocked.");
        $display("========================================================\n");
        $finish;
    end

    // ------------------------------------------------------------------------
    // Helper Tasks for CPU Operations
    // ------------------------------------------------------------------------
    task reset_system;
        begin
            rst_n          = 1'b0;
            cpu_req        = 1'b0;
            cpu_write      = 1'b0;
            cpu_addr       = 32'h0;
            cpu_write_data = 32'h0;
            #(CLK_PERIOD * 3);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            #(CLK_PERIOD);
        end
    endtask

    task cpu_read;
        input  [31:0] addr;
        output [31:0] rdata;
        output        hit_flag;
        output        evict_flag;
        begin
            @(negedge clk);
            cpu_req        = 1'b1;
            cpu_write      = 1'b0;
            cpu_addr       = addr;
            cpu_write_data = 32'h0;

            @(posedge clk);
            // Wait for handshake
            while (!cpu_ready) begin
                @(posedge clk);
            end

            // Capture outputs at ready (in STATE_COMPLETE)
            rdata      = cpu_read_data;
            hit_flag   = status_hit;
            evict_flag = status_dirty_evict;

            @(negedge clk);
            cpu_req = 1'b0;
            @(posedge clk);
        end
    endtask

    task cpu_write_task;
        input  [31:0] addr;
        input  [31:0] wdata;
        output        hit_flag;
        output        evict_flag;
        begin
            @(negedge clk);
            cpu_req        = 1'b1;
            cpu_write      = 1'b1;
            cpu_addr       = addr;
            cpu_write_data = wdata;

            @(posedge clk);
            // Wait for handshake
            while (!cpu_ready) begin
                @(posedge clk);
            end

            hit_flag   = status_hit;
            evict_flag = status_dirty_evict;

            @(negedge clk);
            cpu_req = 1'b0;
            @(posedge clk);
        end
    endtask

    task check_result;
        input [8*45:1] test_name;
        input [31:0]   actual;
        input [31:0]   expected;
        input          actual_hit;
        input          expected_hit;
        begin
            total_tests = total_tests + 1;
            if ((actual === expected) && (actual_hit === expected_hit)) begin
                $display("  [PASS] %0s | Data: 0x%08h (Exp: 0x%08h) | Hit: %0b",
                         test_name, actual, expected, actual_hit);
                passed_tests = passed_tests + 1;
            end else begin
                $display("  [FAIL] %0s | Data: 0x%08h (Exp: 0x%08h) | Hit: %0b (Exp: %0b)",
                         test_name, actual, expected, actual_hit, expected_hit);
                failed_tests = failed_tests + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // Main Verification Process
    // ------------------------------------------------------------------------
    reg [31:0] rdata;
    reg        hit;
    reg        evict;
    reg [31:0] mem_check_val;

    initial begin
        // Set up VCD waveform dumping
        $dumpfile("simulation/waveforms/cache_simulation.vcd");
        $dumpvars(0, tb_cache_controller);

        total_tests  = 0;
        passed_tests = 0;
        failed_tests = 0;

        $display("\n================================================================================");
        $display("   Write-Back Cache Controller — Comprehensive Verification Suite");
        $display("================================================================================\n");

        reset_system();

        // --------------------------------------------------------------------
        // TEST 1: Cold Read Miss
        // --------------------------------------------------------------------
        $display("--- Test 1: Cold Read Miss ---");
        // Address 0x0000_0090 -> Index 1 (addr[6:4]=1), Tag 1 (addr[31:7]=1), Word 0.
        // Memory block 9: Word 0 initial value = (9*16) + 0x1000_0000 = 0x1000_0090.
        cpu_read(32'h0000_0090, rdata, hit, evict);
        check_result("T1.1: Cold Read Miss (Addr 0x0000_0090)", rdata, 32'h1000_0090, hit, 1'b0);

        // --------------------------------------------------------------------
        // TEST 2: Read Hit After Refill
        // --------------------------------------------------------------------
        $display("\n--- Test 2: Read Hit After Refill ---");
        // Address 0x0000_0094 -> Same line (Index 1, Tag 1), Word 1.
        // Block is already resident in cache; must hit without accessing memory.
        cpu_read(32'h0000_0094, rdata, hit, evict);
        check_result("T2.1: Read Hit on Resident Block (Addr 0x0000_0094)", rdata, 32'h1000_0094, hit, 1'b1);

        // --------------------------------------------------------------------
        // TEST 3 & 4: Write Hit and Dirty-Bit Setting
        // --------------------------------------------------------------------
        $display("\n--- Tests 3 & 4: Write Hit & Dirty-Bit Verification ---");
        // Write 0xDEAD_BEEF to 0x0000_0090. Block is already in cache.
        cpu_write_task(32'h0000_0090, 32'hDEAD_BEEF, hit, evict);
        total_tests = total_tests + 1;
        if (hit === 1'b1 && dut.u_cache_mem.line_dirty === 1'b1) begin
            $display("  [PASS] T3.1: Write Hit Confirmed & Dirty Bit Set | Line 1 Dirty: %0b", dut.u_cache_mem.line_dirty);
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] T3.1: Write Hit Confirmed & Dirty Bit Set | Hit: %0b, Dirty: %0b", hit, dut.u_cache_mem.line_dirty);
            failed_tests = failed_tests + 1;
        end

        // Read back written word to ensure cache has updated data
        cpu_read(32'h0000_0090, rdata, hit, evict);
        check_result("T4.1: Read Hit of Modified Word", rdata, 32'hDEAD_BEEF, hit, 1'b1);

        // --------------------------------------------------------------------
        // TEST 5: Main Memory Unchanged Immediately After Write Hit
        // --------------------------------------------------------------------
        $display("\n--- Test 5: Main Memory Unchanged Verification (Write-Back Proof) ---");
        // In a write-back cache, main memory must NOT be updated immediately on write hit!
        mem_check_val = dut.u_main_mem.get_word(32'h0000_0090);
        total_tests = total_tests + 1;
        if (mem_check_val === 32'h1000_0090) begin
            $display("  [PASS] T5.1: Memory Unchanged | Mem[0x0090] = 0x%08h (Proves Write-Back Policy)", mem_check_val);
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] T5.1: Memory Unchanged | Mem[0x0090] = 0x%08h (Expected 0x1000_0090)", mem_check_val);
            failed_tests = failed_tests + 1;
        end

        // --------------------------------------------------------------------
        // TEST 6: Write Miss with Write Allocation
        // --------------------------------------------------------------------
        $display("\n--- Test 6: Write Miss with Write Allocation ---");
        // Address 0x0000_00A0 -> Index 2, Tag 1, Word 0. Currently cold line.
        // Write-allocate: fetch block from memory, update word 0 with 0xCAFE_BABE, mark line dirty.
        cpu_write_task(32'h0000_00A0, 32'hCAFE_BABE, hit, evict);
        total_tests = total_tests + 1;
        if (hit === 1'b0 && dut.u_cache_mem.line_dirty === 1'b1 && dut.u_cache_mem.line_valid === 1'b1) begin
            $display("  [PASS] T6.1: Write Miss & Allocate | Miss confirmed, Line 2 allocated, Dirty: 1");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] T6.1: Write Miss & Allocate | Hit: %0b, Dirty: %0b", hit, dut.u_cache_mem.line_dirty);
            failed_tests = failed_tests + 1;
        end

        // Read neighbor word in allocated block: 0x0000_00A4 (Word 1).
        // Must hit and return original data fetched from memory (0x1000_00A4).
        cpu_read(32'h0000_00A4, rdata, hit, evict);
        check_result("T6.2: Read Hit on Allocated Neighbor Word", rdata, 32'h1000_00A4, hit, 1'b1);

        // Read back written word: 0x0000_00A0.
        cpu_read(32'h0000_00A0, rdata, hit, evict);
        check_result("T6.3: Read Hit on Written Word", rdata, 32'hCAFE_BABE, hit, 1'b1);

        // --------------------------------------------------------------------
        // TESTS 7 & 8: Dirty Cache Line Eviction & Write-Back to Main Memory
        // --------------------------------------------------------------------
        $display("\n--- Tests 7 & 8: Dirty Eviction & Memory Write-Back Verification ---");
        // Line 1 currently holds Block A (Tag 1, Index 1) with modified word 0xDEAD_BEEF (dirty=1).
        // Address 0x0000_0110 -> Index 1, Tag 2, Word 0 (maps to the SAME line, causing a conflict miss!).
        // Controller must detect dirty line, write 0xDEAD_BEEF back to 0x0000_0090, then refill Block B.
        cpu_read(32'h0000_0110, rdata, hit, evict);
        total_tests = total_tests + 1;
        if (evict === 1'b1 && hit === 1'b0) begin
            $display("  [PASS] T7.1: Dirty Eviction Detected | Evict Pulse Asserted on Conflict");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] T7.1: Dirty Eviction Detected | Evict: %0b, Hit: %0b", evict, hit);
            failed_tests = failed_tests + 1;
        end

        // Verify that dirty data was actually written back to main memory address 0x0000_0090
        mem_check_val = dut.u_main_mem.get_word(32'h0000_0090);
        total_tests = total_tests + 1;
        if (mem_check_val === 32'hDEAD_BEEF) begin
            $display("  [PASS] T8.1: Main Memory Verified | Mem[0x0090] = 0x%08h (Matches Written-Back Data)", mem_check_val);
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] T8.1: Main Memory Verified | Mem[0x0090] = 0x%08h (Expected 0xDEAD_BEEF)", mem_check_val);
            failed_tests = failed_tests + 1;
        end

        // --------------------------------------------------------------------
        // TEST 9: Correct Memory Refill After Eviction
        // --------------------------------------------------------------------
        $display("\n--- Test 9: Memory Refill Verification ---");
        // Check returned read data for the new block (0x0000_0110)
        check_result("T9.1: Replacement Block Data Read", rdata, 32'h1000_0110, hit, 1'b0);

        // Verify that newly loaded line is clean
        total_tests = total_tests + 1;
        if (dut.u_cache_mem.line_dirty === 1'b0 && dut.u_cache_mem.line_valid === 1'b1) begin
            $display("  [PASS] T9.2: Refilled Line Status | Valid: 1, Dirty: 0 (Clean Refill)");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] T9.2: Refilled Line Status | Valid: %0b, Dirty: %0b", dut.u_cache_mem.line_valid, dut.u_cache_mem.line_dirty);
            failed_tests = failed_tests + 1;
        end

        // --------------------------------------------------------------------
        // TEST 10: Clean Eviction Without Write-Back
        // --------------------------------------------------------------------
        $display("\n--- Test 10: Clean Eviction Without Write-Back ---");
        // Currently Line 1 holds Block B (clean, dirty=0).
        // Issue read for Address 0x0000_0190 -> Index 1, Tag 3.
        // Since resident block is clean, eviction must bypass write-back!
        cpu_read(32'h0000_0190, rdata, hit, evict);
        total_tests = total_tests + 1;
        if (evict === 1'b0 && hit === 1'b0) begin
            $display("  [PASS] T10.1: Clean Eviction Verified | Write-Back Bypassed (Evict Flag: 0)");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] T10.1: Clean Eviction Verified | Evict Flag: %0b (Expected 0)", evict);
            failed_tests = failed_tests + 1;
        end
        check_result("T10.2: Clean Replacement Fetched Data", rdata, 32'h1000_0190, hit, 1'b0);

        // --------------------------------------------------------------------
        // TEST 11: Reading Previously Written-Back Data (End-to-End Coherency)
        // --------------------------------------------------------------------
        $display("\n--- Test 11: Reading Previously Written-Back Data ---");
        // Address 0x0000_0090 was evicted in Test 7 and written to main memory in Test 8.
        // It is currently NOT in cache. Reading it should fetch 0xDEAD_BEEF from memory!
        cpu_read(32'h0000_0090, rdata, hit, evict);
        check_result("T11.1: Read Evicted Block from Memory", rdata, 32'hDEAD_BEEF, hit, 1'b0);

        // --------------------------------------------------------------------
        // TEST 12: Multiple Consecutive (Back-to-Back) CPU Transactions
        // --------------------------------------------------------------------
        $display("\n--- Test 12: Multiple Consecutive Back-to-Back Transactions ---");
        // Issue 4 back-to-back requests on Line 3 (0x0000_0030) with 0 idle cycles
        @(negedge clk);
        cpu_req        = 1'b1;
        cpu_write      = 1'b0;
        cpu_addr       = 32'h0000_0030; // Line 3, Word 0
        cpu_write_data = 32'h0;

        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        check_result("T12.1: B2B Trans 1 (Read Miss 0x30)", cpu_read_data, 32'h1000_0030, 1'b0, 1'b0);

        // Immediately transition to next request on same cycle
        @(negedge clk);
        cpu_req        = 1'b1;
        cpu_write      = 1'b1;
        cpu_addr       = 32'h0000_0034; // Word 1
        cpu_write_data = 32'h5555_AAAA;

        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        total_tests = total_tests + 1;
        if (status_hit === 1'b1) begin
            $display("  [PASS] T12.2: B2B Trans 2 (Write Hit 0x34)");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] T12.2: B2B Trans 2 (Write Hit 0x34)");
            failed_tests = failed_tests + 1;
        end

        // Immediately transition to read back written word
        @(negedge clk);
        cpu_req        = 1'b1;
        cpu_write      = 1'b0;
        cpu_addr       = 32'h0000_0034;

        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        check_result("T12.3: B2B Trans 3 (Read Back Written)", cpu_read_data, 32'h5555_AAAA, status_hit, 1'b1);

        // Immediately transition to read Word 2
        @(negedge clk);
        cpu_req        = 1'b1;
        cpu_write      = 1'b0;
        cpu_addr       = 32'h0000_0038;

        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        check_result("T12.4: B2B Trans 4 (Read Neighbor Word 2)", cpu_read_data, 32'h1000_0038, status_hit, 1'b1);

        @(negedge clk);
        cpu_req = 1'b0;
        #(CLK_PERIOD * 5);

        // --------------------------------------------------------------------
        // SUMMARY
        // --------------------------------------------------------------------
        $display("\n================================================================================");
        $display("   TESTBENCH EXECUTION SUMMARY");
        $display("   Total Checks:  %0d", total_tests);
        $display("   Passed:        %0d", passed_tests);
        $display("   Failed:        %0d", failed_tests);
        if (failed_tests == 0) begin
            $display("   OVERALL RESULT: [PASS] All Write-Back Cache Controller scenarios passed!");
        end else begin
            $display("   OVERALL RESULT: [FAIL] Some checks failed!");
        end
        $display("================================================================================\n");

        $finish;
    end

endmodule
