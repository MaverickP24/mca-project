// ============================================================================
// Module Name:  main_memory
// Project:      Write-Back Cache Controller — MCA Phase I
// Description:  Behavioral Main Memory model for simulation.
//               Supports block-level read and write transactions (128-bit blocks).
//               Implements deterministic multi-cycle latency to model real SDRAM/SRAM.
//               Pre-initialized with deterministic, address-derived patterns.
// Language:     Verilog-2001
// ============================================================================

`timescale 1ns / 1ps

module main_memory #(
    parameter ADDR_WIDTH      = 32,
    parameter DATA_WIDTH      = 32,
    parameter WORDS_PER_BLOCK = 4,
    parameter BLOCK_WIDTH     = WORDS_PER_BLOCK * DATA_WIDTH, // 128 bits
    parameter MEM_BLOCKS      = 1024,                          // 1024 blocks (16 KB)
    parameter LATENCY_CYCLES  = 2                             // Configurable read/write latency
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // Memory Bus Interface
    input  wire                   mem_req,        // Transaction request
    input  wire                   mem_write,      // 1 = Write block, 0 = Read block
    input  wire [ADDR_WIDTH-1:0]  mem_addr,       // 32-bit byte address (block-aligned)
    input  wire [BLOCK_WIDTH-1:0] mem_write_data, // 128-bit data to write
    output reg  [BLOCK_WIDTH-1:0] mem_read_data,  // 128-bit data read
    output reg                    mem_ready       // Handshake ready pulse
);

    // Block storage array: 1024 blocks x 128 bits
    reg [BLOCK_WIDTH-1:0] storage [0:MEM_BLOCKS-1];

    // Latency counter
    reg [3:0] latency_cnt;
    reg       busy;

    // Index into storage (block address)
    // Block address is bits [13:4] for 1024 blocks (10 bits)
    wire [9:0] block_idx = mem_addr[13:4];

    // ------------------------------------------------------------------------
    // Deterministic Initialization
    // ------------------------------------------------------------------------
    integer i;
    reg [31:0] init_w0, init_w1, init_w2, init_w3;
    initial begin
        for (i = 0; i < MEM_BLOCKS; i = i + 1) begin
            // Each block has 4 words initialized to deterministic values:
            init_w0 = (i * 16) + 32'h1000_0000;
            init_w1 = (i * 16) + 32'h1000_0004;
            init_w2 = (i * 16) + 32'h1000_0008;
            init_w3 = (i * 16) + 32'h1000_000C;
            storage[i] = {init_w3, init_w2, init_w1, init_w0};
        end
    end

    // ------------------------------------------------------------------------
    // Memory Access State Machine & Latency Modeling
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_ready     <= 1'b0;
            mem_read_data <= {BLOCK_WIDTH{1'b0}};
            latency_cnt   <= 4'd0;
            busy          <= 1'b0;
        end else begin
            mem_ready <= 1'b0; // Default: 1-cycle strobe

            if (!busy) begin
                if (mem_req) begin
                    busy        <= 1'b1;
                    latency_cnt <= LATENCY_CYCLES;
                end
            end else begin
                if (latency_cnt > 4'd1) begin
                    latency_cnt <= latency_cnt - 4'd1;
                end else begin
                    // Latency satisfied, perform access and assert ready
                    busy      <= 1'b0;
                    mem_ready <= 1'b1;

                    if (mem_write) begin
                        // Memory write-back
                        storage[block_idx] <= mem_write_data;
                    end else begin
                        // Memory read block
                        mem_read_data <= storage[block_idx];
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Backdoor Testbench Helper Function
    // Allows testbench to inspect memory contents to verify dirty evictions
    // ------------------------------------------------------------------------
    function [31:0] get_word;
        input [ADDR_WIDTH-1:0] byte_addr;
        reg [9:0] b_idx;
        reg [1:0] w_idx;
        reg [127:0] blk;
        begin
            b_idx = byte_addr[13:4];
            w_idx = byte_addr[3:2];
            blk = storage[b_idx];
            case (w_idx)
                2'b00: get_word = blk[31:0];
                2'b01: get_word = blk[63:32];
                2'b10: get_word = blk[95:64];
                2'b11: get_word = blk[127:96];
            endcase
        end
    endfunction

endmodule
