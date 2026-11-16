// ============================================================================
// Module Name:  top_module
// Project:      Write-Back Cache Controller — MCA Phase I
// Description:  Top-level integration module connecting:
//               - cache_controller (FSM, request handling, eviction logic)
//               - cache_memory (2-way set-associative data/tag/valid/dirty/LRU storage)
//               - main_memory (behavioral 128-bit block memory with realistic latency)
// Language:     Verilog-2001 (Synthesizable structural design)
// ============================================================================

`timescale 1ns / 1ps

module top_module #(
    parameter ADDR_WIDTH        = 32,
    parameter DATA_WIDTH        = 32,
    parameter WORDS_PER_BLOCK   = 4,
    parameter NUM_SETS          = 4,
    parameter NUM_WAYS          = 2,
    parameter BYTE_OFFSET_WIDTH = 2,
    parameter WORD_OFFSET_WIDTH = 2,
    parameter INDEX_WIDTH       = 2,
    parameter TAG_WIDTH         = ADDR_WIDTH - INDEX_WIDTH - WORD_OFFSET_WIDTH - BYTE_OFFSET_WIDTH, // 26 bits
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
    wire                         cache_hit_way;
    wire [DATA_WIDTH-1:0]        cache_hit_data;
    wire                         cache_victim_way;
    wire                         cache_victim_valid;
    wire                         cache_victim_dirty;
    wire [TAG_WIDTH-1:0]         cache_victim_tag;
    wire [BLOCK_WIDTH-1:0]       cache_victim_block;

    wire                         way0_v;
    wire                         way1_v;
    wire                         way0_d;
    wire                         way1_d;
    wire [TAG_WIDTH-1:0]         way0_t;
    wire [TAG_WIDTH-1:0]         way1_t;

    wire                         wr_word_en;
    wire [INDEX_WIDTH-1:0]       wr_word_index;
    wire                         wr_word_way;
    wire [WORD_OFFSET_WIDTH-1:0] wr_word_offset;
    wire [DATA_WIDTH-1:0]        wr_word_data;
    wire                         wr_word_dirty;

    wire                         wr_block_en;
    wire [INDEX_WIDTH-1:0]       wr_block_index;
    wire                         wr_block_way;
    wire [TAG_WIDTH-1:0]         wr_block_tag;
    wire [BLOCK_WIDTH-1:0]       wr_block_data;
    wire                         wr_block_dirty;
    wire                         wr_block_valid;

    wire                         update_lru_en;
    wire [INDEX_WIDTH-1:0]       update_lru_index;
    wire                         accessed_way;

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
        .NUM_SETS          (NUM_SETS),
        .NUM_WAYS          (NUM_WAYS),
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
        .cache_hit_way      (cache_hit_way),
        .cache_hit_data     (cache_hit_data),
        .cache_victim_way   (cache_victim_way),
        .cache_victim_valid (cache_victim_valid),
        .cache_victim_dirty (cache_victim_dirty),
        .cache_victim_tag   (cache_victim_tag),
        .cache_victim_block (cache_victim_block),

        // Cache Memory Writes
        .wr_word_en         (wr_word_en),
        .wr_word_index      (wr_word_index),
        .wr_word_way        (wr_word_way),
        .wr_word_offset     (wr_word_offset),
        .wr_word_data       (wr_word_data),
        .wr_word_dirty      (wr_word_dirty),

        .wr_block_en        (wr_block_en),
        .wr_block_index     (wr_block_index),
        .wr_block_way       (wr_block_way),
        .wr_block_tag       (wr_block_tag),
        .wr_block_data      (wr_block_data),
        .wr_block_dirty     (wr_block_dirty),
        .wr_block_valid     (wr_block_valid),

        .update_lru_en      (update_lru_en),
        .update_lru_index   (update_lru_index),
        .accessed_way       (accessed_way),

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
    // Cache Memory Storage Array Instance
    // ------------------------------------------------------------------------
    cache_memory #(
        .ADDR_WIDTH        (ADDR_WIDTH),
        .DATA_WIDTH        (DATA_WIDTH),
        .WORDS_PER_BLOCK   (WORDS_PER_BLOCK),
        .NUM_SETS          (NUM_SETS),
        .NUM_WAYS          (NUM_WAYS),
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
        .hit_way           (cache_hit_way),
        .hit_data          (cache_hit_data),
        .victim_way        (cache_victim_way),
        .victim_valid      (cache_victim_valid),
        .victim_dirty      (cache_victim_dirty),
        .victim_tag        (cache_victim_tag),
        .victim_block_data (cache_victim_block),

        .way0_valid        (way0_v),
        .way1_valid        (way1_v),
        .way0_dirty        (way0_d),
        .way1_dirty        (way1_d),
        .way0_tag          (way0_t),
        .way1_tag          (way1_t),

        // Writes
        .wr_word_en        (wr_word_en),
        .wr_word_index     (wr_word_index),
        .wr_word_way       (wr_word_way),
        .wr_word_offset    (wr_word_offset),
        .wr_word_data      (wr_word_data),
        .wr_word_dirty     (wr_word_dirty),

        .wr_block_en       (wr_block_en),
        .wr_block_index    (wr_block_index),
        .wr_block_way      (wr_block_way),
        .wr_block_tag      (wr_block_tag),
        .wr_block_data     (wr_block_data),
        .wr_block_dirty    (wr_block_dirty),
        .wr_block_valid    (wr_block_valid),

        .update_lru_en     (update_lru_en),
        .update_lru_index  (update_lru_index),
        .accessed_way      (accessed_way)
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

