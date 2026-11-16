// ============================================================================
// Module Name:  cache_memory
// Project:      Write-Back Cache Controller — MCA Phase I
// Description:  Storage array for 2-way set-associative cache.
//               Contains data arrays (4 words per block, 32 bits per word),
//               tag arrays, valid bits, dirty bits, and 1-bit per-set LRU state.
// Organization: 4 sets, 2 ways/set, 4 words/block, 32-bit word width.
// Language:     Verilog-2001 (Synthesizable)
// ============================================================================

`timescale 1ns / 1ps

module cache_memory #(
    parameter ADDR_WIDTH        = 32,
    parameter DATA_WIDTH        = 32,
    parameter WORDS_PER_BLOCK   = 4,
    parameter NUM_SETS          = 4,
    parameter NUM_WAYS          = 2,
    parameter BYTE_OFFSET_WIDTH = 2,
    parameter WORD_OFFSET_WIDTH = 2,
    parameter INDEX_WIDTH       = 2,
    parameter TAG_WIDTH         = ADDR_WIDTH - INDEX_WIDTH - WORD_OFFSET_WIDTH - BYTE_OFFSET_WIDTH, // 26 bits
    parameter BLOCK_WIDTH       = WORDS_PER_BLOCK * DATA_WIDTH // 128 bits
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Lookup Port (asynchronous / registered through controller)
    input  wire [INDEX_WIDTH-1:0]       lookup_index,
    input  wire [TAG_WIDTH-1:0]         lookup_tag,
    input  wire [WORD_OFFSET_WIDTH-1:0] lookup_offset,

    // Status and Data Outputs for Lookup
    output wire                         hit,
    output wire                         hit_way,
    output wire [DATA_WIDTH-1:0]        hit_data,
    output wire                         victim_way,
    output wire                         victim_valid,
    output wire                         victim_dirty,
    output wire [TAG_WIDTH-1:0]         victim_tag,
    output wire [BLOCK_WIDTH-1:0]       victim_block_data,

    // Way 0/1 detailed status (for debug / inspection)
    output wire                         way0_valid,
    output wire                         way1_valid,
    output wire                         way0_dirty,
    output wire                         way1_dirty,
    output wire [TAG_WIDTH-1:0]         way0_tag,
    output wire [TAG_WIDTH-1:0]         way1_tag,

    // Modification Ports
    // 1. Single Word Write (for Write Hit)
    input  wire                         wr_word_en,
    input  wire [INDEX_WIDTH-1:0]       wr_word_index,
    input  wire                         wr_word_way,
    input  wire [WORD_OFFSET_WIDTH-1:0] wr_word_offset,
    input  wire [DATA_WIDTH-1:0]        wr_word_data,
    input  wire                         wr_word_dirty, // normally 1'b1 on write

    // 2. Full Block Write (for Cache Refill / Allocation)
    input  wire                         wr_block_en,
    input  wire [INDEX_WIDTH-1:0]       wr_block_index,
    input  wire                         wr_block_way,
    input  wire [TAG_WIDTH-1:0]         wr_block_tag,
    input  wire [BLOCK_WIDTH-1:0]       wr_block_data,
    input  wire                         wr_block_dirty,
    input  wire                         wr_block_valid,

    // 3. LRU Update
    input  wire                         update_lru_en,
    input  wire [INDEX_WIDTH-1:0]       update_lru_index,
    input  wire                         accessed_way
);

    // ------------------------------------------------------------------------
    // Storage Elements
    // ------------------------------------------------------------------------
    // Valid bits: [NUM_SETS-1:0][NUM_WAYS-1:0]
    reg valid_array [0:NUM_SETS-1][0:NUM_WAYS-1];

    // Dirty bits: [NUM_SETS-1:0][NUM_WAYS-1:0]
    reg dirty_array [0:NUM_SETS-1][0:NUM_WAYS-1];

    // Tag array: [NUM_SETS-1:0][NUM_WAYS-1:0]
    reg [TAG_WIDTH-1:0] tag_array [0:NUM_SETS-1][0:NUM_WAYS-1];

    // Data array: [NUM_SETS-1:0][NUM_WAYS-1][WORDS_PER_BLOCK-1:0]
    reg [DATA_WIDTH-1:0] data_array [0:NUM_SETS-1][0:NUM_WAYS-1][0:WORDS_PER_BLOCK-1];

    // LRU bits: 1 bit per set.
    // 0 = Way 0 is LRU (victim), Way 1 is MRU.
    // 1 = Way 1 is LRU (victim), Way 0 is MRU.
    reg lru_array [0:NUM_SETS-1];

    // ------------------------------------------------------------------------
    // Read / Hit Logic
    // ------------------------------------------------------------------------
    wire way0_v = valid_array[lookup_index][0];
    wire way1_v = valid_array[lookup_index][1];

    wire [TAG_WIDTH-1:0] way0_t = tag_array[lookup_index][0];
    wire [TAG_WIDTH-1:0] way1_t = tag_array[lookup_index][1];

    wire way0_d = dirty_array[lookup_index][0];
    wire way1_d = dirty_array[lookup_index][1];

    wire way0_hit_int = way0_v && (way0_t == lookup_tag);
    wire way1_hit_int = way1_v && (way1_t == lookup_tag);

    assign hit     = way0_hit_int | way1_hit_int;
    assign hit_way = way1_hit_int ? 1'b1 : 1'b0;

    // Word data from each way
    wire [DATA_WIDTH-1:0] way0_word = data_array[lookup_index][0][lookup_offset];
    wire [DATA_WIDTH-1:0] way1_word = data_array[lookup_index][1][lookup_offset];

    assign hit_data = (hit_way == 1'b1) ? way1_word : way0_word;

    // Way status outputs
    assign way0_valid = way0_v;
    assign way1_valid = way1_v;
    assign way0_dirty = way0_d;
    assign way1_dirty = way1_d;
    assign way0_tag   = way0_t;
    assign way1_tag   = way1_t;

    // ------------------------------------------------------------------------
    // Victim Selection Logic (Replacement Policy)
    // Preference: Empty (invalid) line first to avoid thrashing/unnecessary evictions;
    // If both ways are valid, choose based on LRU bit.
    // ------------------------------------------------------------------------
    wire lru_victim = lru_array[lookup_index]; // 0 -> Way 0, 1 -> Way 1

    wire chosen_victim_way = (!way0_v) ? 1'b0 :
                             (!way1_v) ? 1'b1 :
                             lru_victim;

    assign victim_way   = chosen_victim_way;
    assign victim_valid = (chosen_victim_way == 1'b1) ? way1_v : way0_v;
    assign victim_dirty = (chosen_victim_way == 1'b1) ? way1_d : way0_d;
    assign victim_tag   = (chosen_victim_way == 1'b1) ? way1_t : way0_t;

    // Flatten full 128-bit block for victim (words 0..3)
    assign victim_block_data = {
        data_array[lookup_index][chosen_victim_way][3],
        data_array[lookup_index][chosen_victim_way][2],
        data_array[lookup_index][chosen_victim_way][1],
        data_array[lookup_index][chosen_victim_way][0]
    };

    // ------------------------------------------------------------------------
    // Synchronous Update Logic
    // ------------------------------------------------------------------------
    integer s, w, wd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset state
            for (s = 0; s < NUM_SETS; s = s + 1) begin
                lru_array[s] <= 1'b0;
                for (w = 0; w < NUM_WAYS; w = w + 1) begin
                    valid_array[s][w] <= 1'b0;
                    dirty_array[s][w] <= 1'b0;
                    tag_array[s][w]   <= {TAG_WIDTH{1'b0}};
                    for (wd = 0; wd < WORDS_PER_BLOCK; wd = wd + 1) begin
                        data_array[s][w][wd] <= {DATA_WIDTH{1'b0}};
                    end
                end
            end
        end else begin
            // 1. Single Word Write (e.g. Write Hit)
            if (wr_word_en) begin
                data_array[wr_word_index][wr_word_way][wr_word_offset] <= wr_word_data;
                dirty_array[wr_word_index][wr_word_way]                <= wr_word_dirty;
            end

            // 2. Full Block Write (e.g. Refill on Miss / Write-Allocate)
            if (wr_block_en) begin
                tag_array[wr_block_index][wr_block_way]   <= wr_block_tag;
                valid_array[wr_block_index][wr_block_way] <= wr_block_valid;
                dirty_array[wr_block_index][wr_block_way] <= wr_block_dirty;
                // Unpack 128-bit block into 4 words
                data_array[wr_block_index][wr_block_way][0] <= wr_block_data[31:0];
                data_array[wr_block_index][wr_block_way][1] <= wr_block_data[63:32];
                data_array[wr_block_index][wr_block_way][2] <= wr_block_data[95:64];
                data_array[wr_block_index][wr_block_way][3] <= wr_block_data[127:96];
            end

            // 3. LRU Update
            // When a way is accessed (read or write), the OTHER way becomes LRU.
            if (update_lru_en) begin
                lru_array[update_lru_index] <= ~accessed_way;
            end
        end
    end

endmodule

