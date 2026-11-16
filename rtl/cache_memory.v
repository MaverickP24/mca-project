// ============================================================================
// Module Name:  cache_memory
// Project:      Write-Back Cache Controller — MCA Phase I
// Description:  Direct-mapped cache storage array.
//               Stores cache lines comprising valid bit, dirty bit, tag register,
//               and 4-word (128-bit) data block.
// Organization: Direct-mapped (8 lines, 4 words/line, 32-bit word width).
// Language:     Verilog-2001 (Synthesizable)
// ============================================================================

`timescale 1ns / 1ps

module cache_memory #(
    parameter ADDR_WIDTH        = 32,
    parameter DATA_WIDTH        = 32,
    parameter WORDS_PER_BLOCK   = 4,
    parameter NUM_LINES         = 8,
    parameter BYTE_OFFSET_WIDTH = 2,
    parameter WORD_OFFSET_WIDTH = 2,
    parameter INDEX_WIDTH       = 3, // log2(8) = 3
    parameter TAG_WIDTH         = ADDR_WIDTH - INDEX_WIDTH - WORD_OFFSET_WIDTH - BYTE_OFFSET_WIDTH, // 25 bits
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
    output wire [DATA_WIDTH-1:0]        hit_data,
    output wire                         line_valid,
    output wire                         line_dirty,
    output wire [TAG_WIDTH-1:0]         line_tag,
    output wire [BLOCK_WIDTH-1:0]       line_block_data,

    // Modification Ports
    // 1. Single Word Write (for Write Hit)
    input  wire                         wr_word_en,
    input  wire [INDEX_WIDTH-1:0]       wr_word_index,
    input  wire [WORD_OFFSET_WIDTH-1:0] wr_word_offset,
    input  wire [DATA_WIDTH-1:0]        wr_word_data,
    input  wire                         wr_word_dirty,

    // 2. Full Block Write (for Cache Refill / Allocation)
    input  wire                         wr_block_en,
    input  wire [INDEX_WIDTH-1:0]       wr_block_index,
    input  wire [TAG_WIDTH-1:0]         wr_block_tag,
    input  wire [BLOCK_WIDTH-1:0]       wr_block_data,
    input  wire                         wr_block_dirty,
    input  wire                         wr_block_valid
);

    // ------------------------------------------------------------------------
    // Storage Elements
    // ------------------------------------------------------------------------
    // Valid bits: [NUM_LINES-1:0]
    reg valid_array [0:NUM_LINES-1];

    // Dirty bits: [NUM_LINES-1:0]
    reg dirty_array [0:NUM_LINES-1];

    // Tag array: [NUM_LINES-1:0]
    reg [TAG_WIDTH-1:0] tag_array [0:NUM_LINES-1];

    // Data array: [NUM_LINES-1:0][WORDS_PER_BLOCK-1:0]
    reg [DATA_WIDTH-1:0] data_array [0:NUM_LINES-1][0:WORDS_PER_BLOCK-1];

    // ------------------------------------------------------------------------
    // Read / Hit Logic
    // ------------------------------------------------------------------------
    wire curr_v = valid_array[lookup_index];
    wire curr_d = dirty_array[lookup_index];
    wire [TAG_WIDTH-1:0] curr_t = tag_array[lookup_index];

    // Hit occurs when resident line at index is valid and stored tag matches
    assign hit        = curr_v && (curr_t == lookup_tag);
    assign hit_data   = data_array[lookup_index][lookup_offset];

    // Line metadata and full block outputs (for eviction and inspection)
    assign line_valid = curr_v;
    assign line_dirty = curr_d;
    assign line_tag   = curr_t;

    // Flatten full 128-bit block (Word 3 to Word 0)
    assign line_block_data = {
        data_array[lookup_index][3],
        data_array[lookup_index][2],
        data_array[lookup_index][1],
        data_array[lookup_index][0]
    };

    // ------------------------------------------------------------------------
    // Synchronous Update Logic
    // ------------------------------------------------------------------------
    integer i, wd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_LINES; i = i + 1) begin
                valid_array[i] <= 1'b0;
                dirty_array[i] <= 1'b0;
                tag_array[i]   <= {TAG_WIDTH{1'b0}};
                for (wd = 0; wd < WORDS_PER_BLOCK; wd = wd + 1) begin
                    data_array[i][wd] <= {DATA_WIDTH{1'b0}};
                end
            end
        end else begin
            // 1. Single Word Write (e.g. Write Hit)
            if (wr_word_en) begin
                data_array[wr_word_index][wr_word_offset] <= wr_word_data;
                dirty_array[wr_word_index]                <= wr_word_dirty;
            end

            // 2. Full Block Write (e.g. Refill on Miss / Write-Allocate)
            if (wr_block_en) begin
                tag_array[wr_block_index]   <= wr_block_tag;
                valid_array[wr_block_index] <= wr_block_valid;
                dirty_array[wr_block_index] <= wr_block_dirty;
                // Unpack 128-bit block into 4 words
                data_array[wr_block_index][0] <= wr_block_data[31:0];
                data_array[wr_block_index][1] <= wr_block_data[63:32];
                data_array[wr_block_index][2] <= wr_block_data[95:64];
                data_array[wr_block_index][3] <= wr_block_data[127:96];
            end
        end
    end

endmodule
