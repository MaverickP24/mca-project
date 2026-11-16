// ============================================================================
// Module Name:  tb_cache_controller
// Project:      Write-Back Cache Controller — MCA Phase I
// Description:  Self-checking testbench verifying all 8 core scenarios:
//               1. Read miss followed by read hit.
//               2. Write hit and dirty-bit verification.
//               3. Write miss with write allocation.
//               4. Dirty cache line eviction.
//               5. Verification that dirty data reaches main memory.
//               6. Clean cache line eviction without write-back.
//               7. LRU replacement correctness.
//               8. Multiple consecutive back-to-back CPU transactions.
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
    parameter NUM_SETS          = 4;
    parameter NUM_WAYS          = 2;
    parameter BYTE_OFFSET_WIDTH = 2;
    parameter WORD_OFFSET_WIDTH = 2;
    parameter INDEX_WIDTH       = 2;
    parameter TAG_WIDTH         = 26;
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
        .NUM_SETS          (NUM_SETS),
        .NUM_WAYS          (NUM_WAYS),
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
        input [8*40:1] test_name;
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
        $display("   MCA Phase I — Write-Back Cache Controller Verification Suite");
        $display("================================================================================\n");

        reset_system();

        // --------------------------------------------------------------------
        // SCENARIO 1: Read Miss Followed by Read Hit
        // --------------------------------------------------------------------
        $display("--- Scenario 1: Read Miss Followed by Read Hit ---");
        // Address 0x0000_0040 -> Set 0, Tag 1, Word 0. Initial memory value: 0x1000_0040.
        cpu_read(32'h0000_0040, rdata, hit, evict);
        check_result("S1.1: Cold Read Miss (Addr 0x0000_0040)", rdata, 32'h1000_0040, hit, 1'b0);

        // Address 0x0000_0044 -> Same block (Set 0, Tag 1), Word 1. Should be a hit!
        cpu_read(32'h0000_0044, rdata, hit, evict);
        check_result("S1.2: Read Hit (Addr 0x0000_0044)", rdata, 32'h1000_0044, hit, 1'b1);

        // --------------------------------------------------------------------
        // SCENARIO 2: Write Hit and Dirty-Bit Verification
        // --------------------------------------------------------------------
        $display("\n--- Scenario 2: Write Hit and Dirty-Bit Verification ---");
        // Write to cached address 0x0000_0040. Block already cached, so should be Write Hit!
        cpu_write_task(32'h0000_0040, 32'hDEAD_BEEF, hit, evict);
        total_tests = total_tests + 1;
        if (hit === 1'b1 && dut.u_cache_mem.way0_dirty === 1'b1) begin
            $display("  [PASS] S2.1: Write Hit & Dirty Bit Set | Hit: 1, Way0 Dirty: %0b", dut.u_cache_mem.way0_dirty);
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] S2.1: Write Hit & Dirty Bit Set | Hit: %0b, Way0 Dirty: %0b", hit, dut.u_cache_mem.way0_dirty);
            failed_tests = failed_tests + 1;
        end

        // Read back written word to ensure cache has updated data
        cpu_read(32'h0000_0040, rdata, hit, evict);
        check_result("S2.2: Read Hit of Modified Word", rdata, 32'hDEAD_BEEF, hit, 1'b1);

        // --------------------------------------------------------------------
        // SCENARIO 3: Write Miss with Write Allocation
        // --------------------------------------------------------------------
        $display("\n--- Scenario 3: Write Miss with Write Allocation ---");
        // Address 0x0000_0080 -> Set 0, Tag 2, Word 0. Currently not in cache.
        // Write allocate should fetch block from memory, update word 0 with 0xCAFE_BABE, and mark line dirty.
        cpu_write_task(32'h0000_0080, 32'hCAFE_BABE, hit, evict);
        total_tests = total_tests + 1;
        if (hit === 1'b0 && dut.u_cache_mem.way1_dirty === 1'b1 && dut.u_cache_mem.way1_valid === 1'b1) begin
            $display("  [PASS] S3.1: Write Miss & Allocate | Miss confirmed, Way1 allocated, Dirty: 1");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] S3.1: Write Miss & Allocate | Hit: %0b, Way1 Dirty: %0b", hit, dut.u_cache_mem.way1_dirty);
            failed_tests = failed_tests + 1;
        end

        // Read other word in the newly allocated block: 0x0000_0084 (Word 1)
        // Should hit and return original data fetched from memory (0x1000_0084)
        cpu_read(32'h0000_0084, rdata, hit, evict);
        check_result("S3.2: Read Hit on Allocated Neighbor Word", rdata, 32'h1000_0084, hit, 1'b1);

        // Read back modified word: 0x0000_0080
        cpu_read(32'h0000_0080, rdata, hit, evict);
        check_result("S3.3: Read Hit on Written Word", rdata, 32'hCAFE_BABE, hit, 1'b1);

        // --------------------------------------------------------------------
        // SCENARIOS 4 & 5: Dirty Eviction & Memory Verification
        // --------------------------------------------------------------------
        $display("\n--- Scenarios 4 & 5: Dirty Eviction & Memory Write-Back Verification ---");
        // Currently in Set 0:
        // Way 0: Tag 1 (Addr 0x0000_0040), dirty=1, word0=0xDEAD_BEEF.
        // Way 1: Tag 2 (Addr 0x0000_0080), dirty=1, word0=0xCAFE_BABE (accessed more recently).
        // LRU for Set 0 points to Way 0!
        // Memory at 0x0000_0040 BEFORE eviction still contains initial value 0x1000_0040:
        mem_check_val = dut.u_main_mem.get_word(32'h0000_0040);
        total_tests = total_tests + 1;
        if (mem_check_val === 32'h1000_0040) begin
            $display("  [PASS] S4.0: Pre-Eviction Memory Check | Mem[0x0040] = 0x%08h (Unmodified)", mem_check_val);
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] S4.0: Pre-Eviction Memory Check | Mem[0x0040] = 0x%08h", mem_check_val);
            failed_tests = failed_tests + 1;
        end

        // Introduce Address 0x0000_00C0 -> Set 0, Tag 3.
        // Must evict Way 0 (Tag 1), which is dirty! Controller must write 0xDEAD_BEEF back to memory!
        cpu_read(32'h0000_00C0, rdata, hit, evict);
        total_tests = total_tests + 1;
        if (evict === 1'b1 && hit === 1'b0) begin
            $display("  [PASS] S4.1: Dirty Eviction Triggered | Evict Pulse Detected");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] S4.1: Dirty Eviction Triggered | Evict: %0b, Hit: %0b", evict, hit);
            failed_tests = failed_tests + 1;
        end

        // Check new block read returned data
        check_result("S4.2: New Block Read (Addr 0x0000_00C0)", rdata, 32'h1000_00C0, hit, 1'b0);

        // Verification Scenario 5: Check that dirty data actually reached main memory!
        mem_check_val = dut.u_main_mem.get_word(32'h0000_0040);
        total_tests = total_tests + 1;
        if (mem_check_val === 32'hDEAD_BEEF) begin
            $display("  [PASS] S5.1: Main Memory Verified | Mem[0x0040] = 0x%08h (Matches Dirty Cache)", mem_check_val);
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] S5.1: Main Memory Verified | Mem[0x0040] = 0x%08h (Exp: 0xDEAD_BEEF)", mem_check_val);
            failed_tests = failed_tests + 1;
        end

        // --------------------------------------------------------------------
        // SCENARIO 6: Clean Cache Line Eviction without Write-Back
        // --------------------------------------------------------------------
        $display("\n--- Scenario 6: Clean Cache Line Eviction without Write-Back ---");
        // Test Set 1:
        // Read 0x0000_0050 (Set 1, Tag 1) -> Clean block in Way 0
        cpu_read(32'h0000_0050, rdata, hit, evict);
        check_result("S6.1: Cold Read Set 1 (Way 0)", rdata, 32'h1000_0050, hit, 1'b0);

        // Read 0x0000_0090 (Set 1, Tag 2) -> Clean block in Way 1
        cpu_read(32'h0000_0090, rdata, hit, evict);
        check_result("S6.2: Cold Read Set 1 (Way 1)", rdata, 32'h1000_0090, hit, 1'b0);

        // Way 0 is LRU in Set 1. Now read 0x0000_00D0 (Set 1, Tag 3).
        // Since Way 0 is clean (dirty=0), eviction must NOT trigger write-back!
        cpu_read(32'h0000_00D0, rdata, hit, evict);
        total_tests = total_tests + 1;
        if (evict === 1'b0 && hit === 1'b0) begin
            $display("  [PASS] S6.3: Clean Eviction Verified | No Write-Back (Evict Flag: 0)");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] S6.3: Clean Eviction Verified | Evict Flag: %0b (Exp: 0)", evict);
            failed_tests = failed_tests + 1;
        end
        check_result("S6.4: Fetched Replacement Data", rdata, 32'h1000_00D0, hit, 1'b0);

        // --------------------------------------------------------------------
        // SCENARIO 7: LRU Replacement Correctness
        // --------------------------------------------------------------------
        $display("\n--- Scenario 7: LRU Replacement Policy Verification ---");
        // In Set 2:
        // Access Block X: 0x0000_0060 (Tag 1, Set 2). Fills Way 0.
        cpu_read(32'h0000_0060, rdata, hit, evict);
        // Access Block Y: 0x0000_00A0 (Tag 2, Set 2). Fills Way 1.
        cpu_read(32'h0000_00A0, rdata, hit, evict);

        // Both ways filled. Way 0 was accessed first, Way 1 second.
        // Touch Block X again! This should promote Way 0 to MRU, making Way 1 the LRU!
        cpu_read(32'h0000_0060, rdata, hit, evict);
        check_result("S7.1: Touch Block X (MRU Update)", rdata, 32'h1000_0060, hit, 1'b1);

        // Now access Block Z: 0x0000_00E0 (Tag 3, Set 2).
        // Victim MUST be Way 1 (Block Y), NOT Way 0 (Block X)!
        cpu_read(32'h0000_00E0, rdata, hit, evict);
        check_result("S7.2: Replace LRU Victim (Block Z loaded)", rdata, 32'h1000_00E0, hit, 1'b0);

        // Verify Block X is still present (Hit!)
        cpu_read(32'h0000_0060, rdata, hit, evict);
        check_result("S7.3: Block X Still Present (Hit)", rdata, 32'h1000_0060, hit, 1'b1);

        // Verify Block Y was evicted (Miss!)
        cpu_read(32'h0000_00A0, rdata, hit, evict);
        check_result("S7.4: Block Y Was Evicted (Miss)", rdata, 32'h1000_00A0, hit, 1'b0);

        // --------------------------------------------------------------------
        // SCENARIO 8: Multiple Consecutive (Back-to-Back) Transactions
        // --------------------------------------------------------------------
        $display("\n--- Scenario 8: Multiple Consecutive Back-to-Back Transactions ---");
        // Issue 4 back-to-back requests on Set 3 with 0 idle cycles between ready and next req
        @(negedge clk);
        cpu_req        = 1'b1;
        cpu_write      = 1'b0;
        cpu_addr       = 32'h0000_0070; // Set 3, Tag 1, Word 0
        cpu_write_data = 32'h0;

        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        check_result("S8.1: B2B Trans 1 (Read 0x70)", cpu_read_data, 32'h1000_0070, 1'b0, 1'b0);

        // Immediately transition to next request on same cycle
        @(negedge clk);
        cpu_req        = 1'b1;
        cpu_write      = 1'b1;
        cpu_addr       = 32'h0000_0074; // Word 1
        cpu_write_data = 32'h5555_AAAA;

        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        total_tests = total_tests + 1;
        if (status_hit === 1'b1) begin
            $display("  [PASS] S8.2: B2B Trans 2 (Write 0x74 Hit)");
            passed_tests = passed_tests + 1;
        end else begin
            $display("  [FAIL] S8.2: B2B Trans 2 (Write 0x74)");
            failed_tests = failed_tests + 1;
        end

        // Immediately transition to read back
        @(negedge clk);
        cpu_req        = 1'b1;
        cpu_write      = 1'b0;
        cpu_addr       = 32'h0000_0074;

        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        check_result("S8.3: B2B Trans 3 (Read Back Written)", cpu_read_data, 32'h5555_AAAA, status_hit, 1'b1);

        // Immediately transition to read Word 2
        @(negedge clk);
        cpu_req        = 1'b1;
        cpu_write      = 1'b0;
        cpu_addr       = 32'h0000_0078;

        @(posedge clk);
        while (!cpu_ready) @(posedge clk);
        check_result("S8.4: B2B Trans 4 (Read Neighbor Word 2)", cpu_read_data, 32'h1000_0078, status_hit, 1'b1);

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
            $display("   OVERALL RESULT: [PASS] All testbench scenarios completed successfully!");
        end else begin
            $display("   OVERALL RESULT: [FAIL] Some checks failed!");
        end
        $display("================================================================================\n");

        $finish;
    end

endmodule
