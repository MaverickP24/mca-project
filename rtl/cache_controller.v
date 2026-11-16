// ============================================================================
// Module Name:  cache_controller
// Project:      Write-Back Cache Controller — MCA Phase I
// Description:  Main Finite State Machine (FSM) controller.
//               Coordinates CPU request decoding, tag comparison, hit/miss detection,
//               dirty victim eviction to main memory, block refills, cache allocation,
//               and CPU handshake.
// Language:     Verilog-2001 (Synthesizable)
// ============================================================================

`timescale 1ns / 1ps

module cache_controller #(
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

    // CPU Interface
    input  wire                         cpu_req,
    input  wire                         cpu_write,
    input  wire [ADDR_WIDTH-1:0]        cpu_addr,
    input  wire [DATA_WIDTH-1:0]        cpu_write_data,
    output reg  [DATA_WIDTH-1:0]        cpu_read_data,
    output reg                          cpu_ready,

    // Cache Memory Interface (Lookup)
    output wire [INDEX_WIDTH-1:0]       lookup_index,
    output wire [TAG_WIDTH-1:0]         lookup_tag,
    output wire [WORD_OFFSET_WIDTH-1:0] lookup_offset,
    input  wire                         cache_hit,
    input  wire                         cache_hit_way,
    input  wire [DATA_WIDTH-1:0]        cache_hit_data,
    input  wire                         cache_victim_way,
    input  wire                         cache_victim_valid,
    input  wire                         cache_victim_dirty,
    input  wire [TAG_WIDTH-1:0]         cache_victim_tag,
    input  wire [BLOCK_WIDTH-1:0]       cache_victim_block,

    // Cache Memory Interface (Updates)
    output reg                          wr_word_en,
    output wire [INDEX_WIDTH-1:0]       wr_word_index,
    output reg                          wr_word_way,
    output wire [WORD_OFFSET_WIDTH-1:0] wr_word_offset,
    output reg  [DATA_WIDTH-1:0]        wr_word_data,
    output reg                          wr_word_dirty,

    output reg                          wr_block_en,
    output wire [INDEX_WIDTH-1:0]       wr_block_index,
    output reg                          wr_block_way,
    output wire [TAG_WIDTH-1:0]         wr_block_tag,
    output reg  [BLOCK_WIDTH-1:0]       wr_block_data,
    output reg                          wr_block_dirty,
    output reg                          wr_block_valid,

    output reg                          update_lru_en,
    output wire [INDEX_WIDTH-1:0]       update_lru_index,
    output reg                          accessed_way,

    // Main Memory Interface
    output reg                          mem_req,
    output reg                          mem_write,
    output reg  [ADDR_WIDTH-1:0]        mem_addr,
    output reg  [BLOCK_WIDTH-1:0]       mem_write_data,
    input  wire [BLOCK_WIDTH-1:0]       mem_read_data,
    input  wire                         mem_ready,

    // Observability / Status Signals
    output wire                         status_hit,
    output wire                         status_miss,
    output wire                         status_dirty_evict,
    output wire [3:0]                   current_fsm_state
);

    // ------------------------------------------------------------------------
    // FSM State Encoding
    // ------------------------------------------------------------------------
    localparam [3:0]
        STATE_IDLE         = 4'd0,
        STATE_LOOKUP       = 4'd1,
        STATE_READ_HIT     = 4'd2,
        STATE_WRITE_HIT    = 4'd3,
        STATE_EVICT_CHECK  = 4'd4,
        STATE_WRITE_BACK   = 4'd5,
        STATE_MEMORY_READ  = 4'd6,
        STATE_CACHE_UPDATE = 4'd7,
        STATE_COMPLETE     = 4'd8;

    reg [3:0] state, next_state;
    assign current_fsm_state = state;

    // ------------------------------------------------------------------------
    // Registered CPU Request Buffers
    // ------------------------------------------------------------------------
    reg [ADDR_WIDTH-1:0] req_addr;
    reg [DATA_WIDTH-1:0] req_wdata;
    reg                  req_write;

    // Address decomposition of latched request
    // [31:6] = Tag (26 bits), [5:4] = Index (2 bits), [3:2] = Word Offset (2 bits), [1:0] = Byte Offset (2 bits)
    wire [TAG_WIDTH-1:0]         req_tag    = req_addr[31:6];
    wire [INDEX_WIDTH-1:0]       req_index  = req_addr[5:4];
    wire [WORD_OFFSET_WIDTH-1:0] req_offset = req_addr[3:2];

    // Assign lookup signals to cache_memory
    assign lookup_index  = req_index;
    assign lookup_tag    = req_tag;
    assign lookup_offset = req_offset;

    assign wr_word_index    = req_index;
    assign wr_word_offset   = req_offset;
    assign wr_block_index   = req_index;
    assign wr_block_tag     = req_tag;
    assign update_lru_index = req_index;

    // ------------------------------------------------------------------------
    // Internal Latches for Victim and Refill Data
    // ------------------------------------------------------------------------
    reg                   victim_way_reg;
    reg                   victim_dirty_reg;
    reg [TAG_WIDTH-1:0]   victim_tag_reg;
    reg [BLOCK_WIDTH-1:0] victim_block_reg;
    reg [BLOCK_WIDTH-1:0] refill_block_reg;

    reg hit_flag;
    reg miss_flag;
    reg dirty_evict_flag;

    assign status_hit         = (state == STATE_READ_HIT  || state == STATE_WRITE_HIT || (state == STATE_COMPLETE && hit_flag));
    assign status_miss        = (state == STATE_EVICT_CHECK || state == STATE_WRITE_BACK || state == STATE_MEMORY_READ || state == STATE_CACHE_UPDATE || (state == STATE_COMPLETE && miss_flag));
    assign status_dirty_evict = (state == STATE_WRITE_BACK || (state == STATE_COMPLETE && dirty_evict_flag));

    // ------------------------------------------------------------------------
    // Synchronous State Register and Data Path Registers
    // ------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= STATE_IDLE;
            req_addr         <= {ADDR_WIDTH{1'b0}};
            req_wdata        <= {DATA_WIDTH{1'b0}};
            req_write        <= 1'b0;
            victim_way_reg   <= 1'b0;
            victim_dirty_reg <= 1'b0;
            victim_tag_reg   <= {TAG_WIDTH{1'b0}};
            victim_block_reg <= {BLOCK_WIDTH{1'b0}};
            refill_block_reg <= {BLOCK_WIDTH{1'b0}};
            hit_flag         <= 1'b0;
            miss_flag        <= 1'b0;
            dirty_evict_flag <= 1'b0;
            cpu_read_data    <= {DATA_WIDTH{1'b0}};
        end else begin
            state <= next_state;

            case (state)
                STATE_IDLE: begin
                    dirty_evict_flag <= 1'b0;
                    if (cpu_req) begin
                        req_addr  <= cpu_addr;
                        req_wdata <= cpu_write_data;
                        req_write <= cpu_write;
                        hit_flag  <= 1'b0;
                        miss_flag <= 1'b0;
                    end
                end

                STATE_LOOKUP: begin
                    if (cache_hit) begin
                        hit_flag  <= 1'b1;
                        miss_flag <= 1'b0;
                    end else begin
                        hit_flag  <= 1'b0;
                        miss_flag <= 1'b1;
                    end
                end

                STATE_READ_HIT: begin
                    cpu_read_data <= cache_hit_data;
                end

                STATE_WRITE_HIT: begin
                    // Word write handled in combinatorial/register controls below
                end

                STATE_EVICT_CHECK: begin
                    victim_way_reg   <= cache_victim_way;
                    victim_dirty_reg <= cache_victim_valid && cache_victim_dirty;
                    victim_tag_reg   <= cache_victim_tag;
                    victim_block_reg <= cache_victim_block;
                    if (cache_victim_valid && cache_victim_dirty) begin
                        dirty_evict_flag <= 1'b1;
                    end else begin
                        dirty_evict_flag <= 1'b0;
                    end
                end

                STATE_WRITE_BACK: begin
                    // Waiting for main memory write to complete
                end

                STATE_MEMORY_READ: begin
                    if (mem_ready) begin
                        refill_block_reg <= mem_read_data;
                    end
                end

                STATE_CACHE_UPDATE: begin
                    if (!req_write) begin
                        // Select word from refill block for read
                        case (req_offset)
                            2'b00: cpu_read_data <= refill_block_reg[31:0];
                            2'b01: cpu_read_data <= refill_block_reg[63:32];
                            2'b10: cpu_read_data <= refill_block_reg[95:64];
                            2'b11: cpu_read_data <= refill_block_reg[127:96];
                        endcase
                    end
                end

                STATE_COMPLETE: begin
                    // Transaction complete
                end

                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // Next State Logic (Combinational)
    // ------------------------------------------------------------------------
    always @(*) begin
        next_state = state;

        case (state)
            STATE_IDLE: begin
                if (cpu_req)
                    next_state = STATE_LOOKUP;
                else
                    next_state = STATE_IDLE;
            end

            STATE_LOOKUP: begin
                if (cache_hit) begin
                    if (req_write)
                        next_state = STATE_WRITE_HIT;
                    else
                        next_state = STATE_READ_HIT;
                end else begin
                    next_state = STATE_EVICT_CHECK;
                end
            end

            STATE_READ_HIT: begin
                next_state = STATE_COMPLETE;
            end

            STATE_WRITE_HIT: begin
                next_state = STATE_COMPLETE;
            end

            STATE_EVICT_CHECK: begin
                // Check if victim line is valid and dirty
                if (cache_victim_valid && cache_victim_dirty)
                    next_state = STATE_WRITE_BACK;
                else
                    next_state = STATE_MEMORY_READ;
            end

            STATE_WRITE_BACK: begin
                if (mem_ready)
                    next_state = STATE_MEMORY_READ;
                else
                    next_state = STATE_WRITE_BACK;
            end

            STATE_MEMORY_READ: begin
                if (mem_ready)
                    next_state = STATE_CACHE_UPDATE;
                else
                    next_state = STATE_MEMORY_READ;
            end

            STATE_CACHE_UPDATE: begin
                next_state = STATE_COMPLETE;
            end

            STATE_COMPLETE: begin
                next_state = STATE_IDLE;
            end

            default: next_state = STATE_IDLE;
        endcase
    end

    // ------------------------------------------------------------------------
    // Output Generation Logic (Combinational)
    // ------------------------------------------------------------------------
    always @(*) begin
        // Default values to avoid latches
        cpu_ready      = 1'b0;
        wr_word_en     = 1'b0;
        wr_word_way    = 1'b0;
        wr_word_data   = req_wdata;
        wr_word_dirty  = 1'b1;

        wr_block_en    = 1'b0;
        wr_block_way   = victim_way_reg;
        wr_block_data  = refill_block_reg;
        wr_block_dirty = 1'b0;
        wr_block_valid = 1'b1;

        update_lru_en  = 1'b0;
        accessed_way   = 1'b0;

        mem_req        = 1'b0;
        mem_write      = 1'b0;
        mem_addr       = {ADDR_WIDTH{1'b0}};
        mem_write_data = {BLOCK_WIDTH{1'b0}};

        case (state)
            STATE_READ_HIT: begin
                // Update LRU on read hit
                update_lru_en = 1'b1;
                accessed_way  = cache_hit_way;
            end

            STATE_WRITE_HIT: begin
                // Update word in cache line and set dirty bit
                wr_word_en    = 1'b1;
                wr_word_way   = cache_hit_way;
                wr_word_data  = req_wdata;
                wr_word_dirty = 1'b1;

                // Update LRU on write hit
                update_lru_en = 1'b1;
                accessed_way  = cache_hit_way;
            end

            STATE_WRITE_BACK: begin
                // Drive write-back request to main memory
                mem_req        = 1'b1;
                mem_write      = 1'b1;
                // Victim block address: {victim_tag, req_index, 4'b0000}
                mem_addr       = {victim_tag_reg, req_index, 4'b0000};
                mem_write_data = victim_block_reg;
            end

            STATE_MEMORY_READ: begin
                // Drive read request for required block to main memory
                mem_req   = 1'b1;
                mem_write = 1'b0;
                mem_addr  = {req_tag, req_index, 4'b0000};
            end

            STATE_CACHE_UPDATE: begin
                wr_block_en    = 1'b1;
                wr_block_way   = victim_way_reg;
                wr_block_valid = 1'b1;

                if (!req_write) begin
                    // Read Miss Refill
                    wr_block_data  = refill_block_reg;
                    wr_block_dirty = 1'b0; // Clean on fresh refill
                end else begin
                    // Write Miss: Write-Allocate (merge new word into refill block)
                    wr_block_dirty = 1'b1; // Mark dirty since word is modified
                    case (req_offset)
                        2'b00: wr_block_data = {refill_block_reg[127:32], req_wdata};
                        2'b01: wr_block_data = {refill_block_reg[127:64], req_wdata, refill_block_reg[31:0]};
                        2'b10: wr_block_data = {refill_block_reg[127:96], req_wdata, refill_block_reg[63:0]};
                        2'b11: wr_block_data = {req_wdata, refill_block_reg[95:0]};
                    endcase
                end

                // Update LRU for refilled way
                update_lru_en = 1'b1;
                accessed_way  = victim_way_reg;
            end

            STATE_COMPLETE: begin
                cpu_ready = 1'b1;
            end

            default: ;
        endcase
    end

endmodule
