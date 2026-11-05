// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket: the boot ROM and the floppies, on demand from the card
//
// Both are APF `deferload` slots: not loaded, read by the core with target commands (0x0180 read,
// 0x0184 write, any length from any offset) through one window of block RAM on the bridge at
// 0x40000000, 4 KB. There is no copy of a disk in SDRAM and no CPU on the data path, and a game's
// writes reach the file on the card as they would a floppy.
//
// THE BOOT ROM comes first, in 4 KB chunks, each poured a byte at a time through upstream's ldr_ port
// as that takes them, which is far slower than APF would push them: this is why it's pulled and not
// loaded. ldr_done lets the machine go.
//
// A SECTOR. The FDC asks with mist_rd or mist_wr for its drive and upstream's handshake: rd falls on
// ack, its data goes over while ack is high, ack falling ends it. A read pulls 512 bytes into the
// window, then raises ack and pours them into the FDC's buffer; a write raises ack and takes 512 bytes
// out of that buffer, then pushes them to the card. Upstream's `mist_lba` counts in 512-byte
// sectors from the start of the file, header included.
//
// APF's commands. A command rises on target_read or target_write and is finished when done rises;
// done falls as a command begins, so it's watched low and then high. `err` holds the result only
// once done is up. ack is not looked at: it can come and go between two samples.
//
// Bridge reads return the word a strobe before, as APF's own command bridge: the address is latched
// on the strobe and the word held until the next. Without that a target write would rotate every
// sector by a word (the lesson of Mille Miglia's save file).
//
// This runs on clk (40 MHz), the FDC's clock; the window's other side, on clk_74a, is the bridge's.

`default_nettype none

module pocket_disk (
    input  wire        clk_74a,
    input  wire        bridge_wr,
    input  wire        bridge_rd,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,
    output wire [31:0] bridge_rd_word,

    input  wire        clk,
    input  wire        rst,
    input  wire        go,              // APF's slots done and the memories ready, synchronised

    // the command to APF: held, and read by its bridge on the rising edge of read or write
    output reg         t_read,
    output reg         t_write,
    output reg  [15:0] t_id,
    output reg  [31:0] t_offset,
    output reg  [31:0] t_length,
    input  wire        t_done,          // synchronised
    input  wire [2:0]  t_err,

    // the drives: which slot each holds
    input  wire [15:0] drive0_id,
    input  wire [15:0] drive1_id,
    input  wire [20:0] drive0_size,     // the files' lengths: a sector may run past the end
    input  wire [20:0] drive1_size,

    // the boot ROM's way in
    output reg  [19:0] ldr_addr,
    output reg         ldr_aen,
    output reg  [7:0]  ldr_wdat,
    output reg         ldr_wr,
    input  wire        ldr_ack,
    output reg         ldr_done,

    // the FDC
    input  wire [31:0] mist_lba,
    input  wire [1:0]  mist_rd,
    input  wire [1:0]  mist_wr,
    output reg  [1:0]  mist_ack,
    output reg  [8:0]  mist_buffaddr,
    output reg  [7:0]  mist_buffdout,
    input  wire [7:0]  mist_buffdin,
    output reg         mist_buffwr,

    output wire        busy,            // a sector in hand: not the moment to stop the machine
    output reg         err,             // sticky: a command came back with an error
    output reg  [15:0] sector_peak,     // the longest sector, in 4096 clocks: 102 us
    input  wire        diag_clr
);

    // ----------------------------------------------------------------- window
    wire       win_hit = bridge_addr[31:28] == 4'h4;
    reg  [9:0] rd_a = 10'd0;
    always @(posedge clk_74a) if (bridge_rd && win_hit) rd_a <= bridge_addr[11:2];

    wire [9:0]  a_addr = bridge_wr ? bridge_addr[11:2] : rd_a;
    wire        a_we   = bridge_wr && win_hit;
    wire [31:0] a_q;

    reg  [11:0] b_addr;
    reg         b_we;
    reg  [7:0]  b_din;
    wire [7:0]  b_q [0:3];

    // Bridge bytes are big-endian: byte 4k of the file is [31:24].
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : lanes
        bram_block_dp #(.DATA(8), .ADDR(10)) u_lane (
            .a_clk(clk_74a), .a_wr(a_we), .a_addr(a_addr),
            .a_din(bridge_wr_data[8*(3-g) +: 8]), .a_dout(a_q[8*(3-g) +: 8]),
            .b_clk(clk), .b_wr(b_we && b_addr[1:0] == 2'(g)), .b_addr(b_addr[11:2]),
            .b_din(b_din), .b_dout(b_q[g])
        );
    end endgenerate
    assign bridge_rd_word = a_q;

    reg [1:0] b_lane;
    always @(posedge clk) b_lane <= b_addr[1:0];
    wire [7:0] b_byte = b_q[b_lane];

    // ---------------------------------------------------------------- machine
    localparam [3:0] S_WAIT = 4'd0, S_ROM_CMD = 4'd1, S_ROM_LOW = 4'd2, S_ROM_HIGH = 4'd3,
                     S_ROM_ADDR = 4'd4, S_ROM_DATA = 4'd5, S_ROM_ACK = 4'd6, S_ROM_NAK = 4'd7,
                     S_IDLE = 4'd8, S_RD_LOW = 4'd9, S_RD_HIGH = 4'd10, S_RD_COPY = 4'd11,
                     S_RD_END = 4'd12, S_WR_COPY = 4'd13, S_WR_LOW = 4'd14, S_WR_HIGH = 4'd15;
    reg [3:0]  st;
    reg        unit, wr_none;
    reg [8:0]  chunk;
    reg [12:0] n;
    reg [11:0] tick;
    reg [15:0] sector_t;

    localparam [8:0] ROM_CHUNKS = 9'd256;      // 1 MB

    // A DIM has a 256-byte header ahead of whole sectors and upstream counts in 512 bytes from the file's
    // start, so a disk's last sector is half past its end. Only what's there is asked for.
    wire        req_unit = (mist_rd != 2'b00) ? mist_rd[1] : mist_wr[1];
    wire [21:0] req_off  = {mist_lba[12:0], 9'd0};
    wire [21:0] req_size = {1'b0, req_unit ? drive1_size : drive0_size};
    wire        req_none = req_off >= req_size;
    wire [21:0] req_left = req_size - req_off;
    wire [31:0] req_len  = (req_left < 22'd512) ? {10'd0, req_left} : 32'd512;

    assign busy = (st != S_IDLE) && ldr_done;

    always @(posedge clk) begin
        mist_buffwr <= 1'b0;
        b_we        <= 1'b0;

        // the time a sector takes, the card's and the bus's together
        if (diag_clr) sector_peak <= 16'd0;
        if (st == S_IDLE) begin
            tick     <= 12'd0;
            sector_t <= 16'd0;
        end else begin
            tick <= tick + 12'd1;
            if (&tick) sector_t <= sector_t + 16'd1;
            if (ldr_done && sector_t > sector_peak) sector_peak <= sector_t;
        end
        if (t_done && t_err != 3'd0) err <= 1'b1;
        if (diag_clr) err <= 1'b0;

        if (rst) begin
            st       <= S_WAIT;
            t_read   <= 1'b0;
            t_write  <= 1'b0;
            ldr_aen  <= 1'b0;
            ldr_wr   <= 1'b0;
            ldr_done <= 1'b0;
            mist_ack <= 2'b00;
            chunk    <= 9'd0;
            err      <= 1'b0;
        end else case (st)
            S_WAIT: if (go) begin
                ldr_aen <= 1'b1;
                st      <= S_ROM_CMD;
            end

            // ------------------------------------------------------- boot ROM
            S_ROM_CMD: begin
                if (chunk == ROM_CHUNKS) begin
                    ldr_aen  <= 1'b0;
                    ldr_done <= 1'b1;
                    st       <= S_IDLE;
                end else begin
                    t_id     <= 16'd1;
                    t_offset <= {11'd0, chunk, 12'd0};
                    t_length <= 32'd4096;
                    t_read   <= 1'b1;
                    st       <= S_ROM_LOW;
                end
            end
            S_ROM_LOW: if (!t_done) st <= S_ROM_HIGH;
            S_ROM_HIGH: if (t_done) begin
                t_read <= 1'b0;
                n      <= 13'd0;
                st     <= S_ROM_ADDR;
            end
            S_ROM_ADDR: begin
                b_addr <= n[11:0];
                st     <= S_ROM_DATA;
            end
            S_ROM_DATA: begin                   // the RAM's clock, then its byte
                st <= S_ROM_ACK;
            end
            S_ROM_ACK: begin
                if (!ldr_wr) begin
                    ldr_addr <= {chunk[7:0], n[11:0]};
                    ldr_wdat <= b_byte;
                    ldr_wr   <= 1'b1;
                end else if (ldr_ack) begin
                    ldr_wr <= 1'b0;
                    st     <= S_ROM_NAK;
                end
            end
            S_ROM_NAK: if (!ldr_ack) begin
                if (n[11:0] == 12'hFFF) begin
                    chunk <= chunk + 9'd1;
                    st    <= S_ROM_CMD;
                end else begin
                    n  <= n + 13'd1;
                    st <= S_ROM_ADDR;
                end
            end

            // -------------------------------------------------------- sectors
            S_IDLE: begin
                if (mist_rd != 2'b00) begin
                    unit     <= mist_rd[1];
                    t_id     <= mist_rd[1] ? drive1_id : drive0_id;
                    t_offset <= {mist_lba[22:0], 9'd0};
                    t_length <= req_len;
                    if (req_none) begin              // nothing there: the window's bytes as they are
                        mist_ack[mist_rd[1]] <= 1'b1;
                        n  <= 13'd0;
                        st <= S_RD_COPY;
                    end else begin
                        t_read <= 1'b1;
                        st     <= S_RD_LOW;
                    end
                end else if (mist_wr != 2'b00) begin
                    unit           <= mist_wr[1];
                    t_id           <= mist_wr[1] ? drive1_id : drive0_id;
                    t_offset       <= {mist_lba[22:0], 9'd0};
                    t_length       <= req_len;
                    wr_none        <= req_none;
                    mist_ack[mist_wr[1]] <= 1'b1;
                    n              <= 13'd0;
                    mist_buffaddr  <= 9'd0;
                    st             <= S_WR_COPY;
                end
            end

            S_RD_LOW: if (!t_done) st <= S_RD_HIGH;
            S_RD_HIGH: if (t_done) begin
                t_read         <= 1'b0;
                mist_ack[unit] <= 1'b1;
                n              <= 13'd0;
                st             <= S_RD_COPY;
            end
            // four clocks a byte: the address, the RAM's clock, then its byte over to the FDC
            S_RD_COPY: begin
                n <= n + 13'd1;
                if (n[1:0] == 2'd0) b_addr <= {3'd0, n[10:2]};
                if (n[1:0] == 2'd2) begin
                    mist_buffaddr <= n[10:2];
                    mist_buffdout <= b_byte;
                    mist_buffwr   <= 1'b1;
                end
                if (n == 13'd2047) st <= S_RD_END;
            end
            S_RD_END: begin
                mist_ack[unit] <= 1'b0;
                st             <= S_IDLE;
            end

            // the FDC's buffer answers a clock after its address; its byte goes into the window
            S_WR_COPY: begin
                n <= n + 13'd1;
                if (n[1:0] == 2'd0) mist_buffaddr <= n[10:2];
                if (n[1:0] == 2'd2) begin
                    b_addr <= {3'd0, n[10:2]};
                    b_din  <= mist_buffdin;
                    b_we   <= 1'b1;
                end
                if (n == 13'd2047) begin
                    mist_ack[unit] <= 1'b0;
                    if (wr_none) st <= S_IDLE;
                    else begin
                        t_write <= 1'b1;
                        st      <= S_WR_LOW;
                    end
                end
            end
            S_WR_LOW: if (!t_done) st <= S_WR_HIGH;
            S_WR_HIGH: if (t_done) begin
                t_write <= 1'b0;
                st      <= S_IDLE;
            end

            default: st <= S_IDLE;
        endcase
    end

endmodule

`default_nettype wire
