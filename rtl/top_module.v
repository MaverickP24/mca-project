// ============================================================================
// Module Name:  top_module
// Project:      Write-Back Cache Controller — MCA Phase I
// Description:  Top-level integration module connecting:
//               - cache_controller (9-State FSM, request handling, write-back sequencing)
//               - cache_memory (Direct-mapped data, tag, valid, and dirty storage)
//               - main_memory (Behavioral 128-bit block memory with realistic latency)
// Language:     Verilog-2001 (Synthesizable structural design)
// ============================================================================

`timescale 1ns / 1ps

module top_module #(
    parameter ADDR_WIDTH        = 32,
    parameter DATA_WIDTH        = 32,
    parameter WORDS_PER_BLOCK   = 4,
    parameter NUM_LINES         = 8,
    parameter BYTE_OFFSET_WIDTH = 2,
    parameter WORD_OFFSET_WIDTH = 2,
    parameter INDEX_WIDTH       = 3, // log2(8) = 3
    parameter TAG_WIDTH         = ADDR_WIDTH - INDEX_WIDTH - WORD_OFFSET_WIDTH - BYTE_OFFSET_WIDTH, // 25 bits
    parameter BLOCK_WIDTH       = WORDS_PER_BLOCK * DATA_WIDTH, // 128 bits
    parameter MEM_BLOCKS        = 1024,
    parameter MEM_LATENCY       = 2
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // CPU Bus Interface
    input  wire                  cpu_req,
    input  wire                  cpu_write,
    input  wire [ADDR_WIDTH-1:0] cpu_addr,
    input  wire [DATA_WIDTH-1:0] cpu_write_data,
    output wire [DATA_WIDTH-1:0] cpu_read_data,
    output wire                  cpu_ready,

    // Observability / Status for Verification & Waveforms
    output wire                  status_hit,
    output wire                  status_miss,
    output wire                  status_dirty_evict,
    output wire [3:0]            current_fsm_state,
    output wire                  mem_req_active,
    output wire                  mem_ready_active
);

    // ------------------------------------------------------------------------
    // Interconnect Signals between Cache Controller and Cache Memory
    // ------------------------------------------------------------------------
    wire [INDEX_WIDTH-1:0]       lookup_index;
    wire [TAG_WIDTH-1:0]         lookup_tag;
    wire [WORD_OFFSET_WIDTH-1:0] lookup_offset;

    wire                         cache_hit;
    wire [DATA_WIDTH-1:0]        cache_hit_data;
    wire                         cache_line_valid;
    wire                         cache_line_dirty;
    wire [TAG_WIDTH-1:0]         cache_line_tag;
    wire [BLOCK_WIDTH-1:0]       cache_line_block;

    wire                         wr_word_en;
    wire [INDEX_WIDTH-1:0]       wr_word_index;
    wire [WORD_OFFSET_WIDTH-1:0] wr_word_offset;
    wire [DATA_WIDTH-1:0]        wr_word_data;
    wire                         wr_word_dirty;

    wire                         wr_block_en;
    wire [INDEX_WIDTH-1:0]       wr_block_index;
    wire [TAG_WIDTH-1:0]         wr_block_tag;
    wire [BLOCK_WIDTH-1:0]       wr_block_data;
    wire                         wr_block_dirty;
    wire                         wr_block_valid;

    // ------------------------------------------------------------------------
    // Interconnect Signals between Cache Controller and Main Memory
    // ------------------------------------------------------------------------
    wire                         mem_req;
    wire                         mem_write;
    wire [ADDR_WIDTH-1:0]        mem_addr;
    wire [BLOCK_WIDTH-1:0]       mem_wdata;
    wire [BLOCK_WIDTH-1:0]       mem_rdata;
    wire                         mem_ready;

    assign mem_req_active   = mem_req;
    assign mem_ready_active = mem_ready;

    // ------------------------------------------------------------------------
    // Cache Controller Instance
    // ------------------------------------------------------------------------
    cache_controller #(
        .ADDR_WIDTH        (ADDR_WIDTH),
        .DATA_WIDTH        (DATA_WIDTH),
        .WORDS_PER_BLOCK   (WORDS_PER_BLOCK),
        .NUM_LINES         (NUM_LINES),
        .BYTE_OFFSET_WIDTH (BYTE_OFFSET_WIDTH),
        .WORD_OFFSET_WIDTH (WORD_OFFSET_WIDTH),
        .INDEX_WIDTH       (INDEX_WIDTH),
        .TAG_WIDTH         (TAG_WIDTH),
        .BLOCK_WIDTH       (BLOCK_WIDTH)
    ) u_controller (
        .clk                (clk),
        .rst_n              (rst_n),

        // CPU
        .cpu_req            (cpu_req),
        .cpu_write          (cpu_write),
        .cpu_addr           (cpu_addr),
        .cpu_write_data     (cpu_write_data),
        .cpu_read_data      (cpu_read_data),
        .cpu_ready          (cpu_ready),

        // Cache Memory Lookup
        .lookup_index       (lookup_index),
        .lookup_tag         (lookup_tag),
        .lookup_offset      (lookup_offset),
        .cache_hit          (cache_hit),
        .cache_hit_data     (cache_hit_data),
        .cache_line_valid   (cache_line_valid),
        .cache_line_dirty   (cache_line_dirty),
        .cache_line_tag     (cache_line_tag),
        .cache_line_block   (cache_line_block),

        // Cache Memory Writes
        .wr_word_en         (wr_word_en),
        .wr_word_index      (wr_word_index),
        .wr_word_offset     (wr_word_offset),
        .wr_word_data       (wr_word_data),
        .wr_word_dirty      (wr_word_dirty),

        .wr_block_en        (wr_block_en),
        .wr_block_index     (wr_block_index),
        .wr_block_tag       (wr_block_tag),
        .wr_block_data      (wr_block_data),
        .wr_block_dirty     (wr_block_dirty),
        .wr_block_valid     (wr_block_valid),

        // Main Memory
        .mem_req            (mem_req),
        .mem_write          (mem_write),
        .mem_addr           (mem_addr),
        .mem_write_data     (mem_wdata),
        .mem_read_data      (mem_rdata),
        .mem_ready          (mem_ready),

        // Status
        .status_hit         (status_hit),
        .status_miss        (status_miss),
        .status_dirty_evict (status_dirty_evict),
        .current_fsm_state  (current_fsm_state)
    );

    // ------------------------------------------------------------------------
    // Cache Memory Storage Array Instance (Direct-Mapped)
    // ------------------------------------------------------------------------
    cache_memory #(
        .ADDR_WIDTH        (ADDR_WIDTH),
        .DATA_WIDTH        (DATA_WIDTH),
        .WORDS_PER_BLOCK   (WORDS_PER_BLOCK),
        .NUM_LINES         (NUM_LINES),
        .BYTE_OFFSET_WIDTH (BYTE_OFFSET_WIDTH),
        .WORD_OFFSET_WIDTH (WORD_OFFSET_WIDTH),
        .INDEX_WIDTH       (INDEX_WIDTH),
        .TAG_WIDTH         (TAG_WIDTH),
        .BLOCK_WIDTH       (BLOCK_WIDTH)
    ) u_cache_mem (
        .clk               (clk),
        .rst_n             (rst_n),

        // Lookup
        .lookup_index      (lookup_index),
        .lookup_tag        (lookup_tag),
        .lookup_offset     (lookup_offset),

        .hit               (cache_hit),
        .hit_data          (cache_hit_data),
        .line_valid        (cache_line_valid),
        .line_dirty        (cache_line_dirty),
        .line_tag          (cache_line_tag),
        .line_block_data   (cache_line_block),

        // Writes
        .wr_word_en        (wr_word_en),
        .wr_word_index     (wr_word_index),
        .wr_word_offset    (wr_word_offset),
        .wr_word_data      (wr_word_data),
        .wr_word_dirty     (wr_word_dirty),

        .wr_block_en       (wr_block_en),
        .wr_block_index    (wr_block_index),
        .wr_block_tag      (wr_block_tag),
        .wr_block_data     (wr_block_data),
        .wr_block_dirty    (wr_block_dirty),
        .wr_block_valid    (wr_block_valid)
    );

    // ------------------------------------------------------------------------
    // Main Memory Instance (Behavioral)
    // ------------------------------------------------------------------------
    main_memory #(
        .ADDR_WIDTH      (ADDR_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .WORDS_PER_BLOCK (WORDS_PER_BLOCK),
        .BLOCK_WIDTH     (BLOCK_WIDTH),
        .MEM_BLOCKS      (MEM_BLOCKS),
        .LATENCY_CYCLES  (MEM_LATENCY)
    ) u_main_mem (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_req        (mem_req),
        .mem_write      (mem_write),
        .mem_addr       (mem_addr),
        .mem_write_data (mem_wdata),
        .mem_read_data  (mem_rdata),
        .mem_ready      (mem_ready)
    );

endmodule
