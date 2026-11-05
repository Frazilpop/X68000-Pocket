// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket: the machine's 16 KB of battery SRAM as an APF nonvolatile slot
//
// APF writes the file in at boot and reads it back out at shutdown, a 32-bit word on the bridge at
// a time, on clk_74a. The SRAM's second port is on this same clock (sramram_dc), a byte at a time, and
// APF allows many clocks between words, so each word is moved in eight clocks with no crossing and
// no copy of the memory.
//
// APF READS ONE WORD AHEAD. A read returns the bus value as it stands, then strobes bridge_rd to
// start the read of its address, whose word APF takes from the next read. So the address is
// taken on the strobe and its word held until the next (the lesson of Mille Miglia's save file).
//
// Bridge bytes are big-endian: file byte 4k is [31:24]. File byte k is the port's byte k, as upstream's
// sramcont has it on its way to the SD card.

`default_nettype none

module pocket_sram_slot (
    input  wire        clk_74a,
    input  wire        bridge_wr,
    input  wire        bridge_rd,
    input  wire [31:0] bridge_addr,
    input  wire [31:0] bridge_wr_data,
    output reg  [31:0] bridge_rd_word,

    output wire [13:0] nv_addr,
    output reg  [7:0]  nv_wdat,
    output reg         nv_wr,
    input  wire [7:0]  nv_rdat
);
    wire hit = bridge_addr[31:28] == 4'h2 && bridge_addr[27:14] == 14'd0;

    reg  [11:0] word = 12'd0;
    reg  [31:0] w_hold;
    reg  [3:0]  w_step = 4'd0;
    reg  [3:0]  r_step = 4'd0;
    reg  [1:0]  lane = 2'd0;

    assign nv_addr = {word, lane};

    always @(posedge clk_74a) begin
        nv_wr <= 1'b0;

        if (bridge_wr && hit) begin
            word   <= bridge_addr[13:2];
            w_hold <= bridge_wr_data;
            w_step <= 4'd1;
            lane   <= 2'd0;
        end else if (w_step != 4'd0) begin
            // a byte's address and data, its write, on to the next
            w_step <= w_step + 4'd1;
            if (!w_step[0]) lane <= lane + 2'd1;
            else begin
                nv_wdat <= w_hold[31:24];
                w_hold  <= {w_hold[23:0], 8'd0};
                nv_wr   <= 1'b1;
            end
            if (w_step == 4'd8) w_step <= 4'd0;
        end

        if (bridge_rd && hit) begin
            word   <= bridge_addr[13:2];
            lane   <= 2'd0;
            r_step <= 4'd1;
        end else if (r_step != 4'd0) begin
            // the address, a clock for the RAM, its byte
            r_step <= r_step + 4'd1;
            if (r_step[0] == 1'b0) begin
                bridge_rd_word <= {bridge_rd_word[23:0], nv_rdat};
                lane           <= lane + 2'd1;
            end
            if (r_step == 4'd8) r_step <= 4'd0;
        end
    end
endmodule

`default_nettype wire
