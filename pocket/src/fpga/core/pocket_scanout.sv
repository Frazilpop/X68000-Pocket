// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket: the board's scan line to the APF video bus, on one fixed clock
//
// THE CLOCK. The machine's dots come at 4.9 to 34.8 MHz as the program chooses, from a fractional
// enable on clk80. APF's video clock stays at 40.0125 MHz in every mode, and a pixel is a single
// video clock with DE high: between pixels DE is low, which the scaler ignores. Nothing to reprogram
// when a game changes mode, and no line store beyond the board's own.
//
// THE CROSSING. clk40 rises with every other edge of clk80, and two pixels are always at least two
// clocks of clk80 apart, so at most one lands between two edges of clk40. So a pixel is held on clk80
// with a toggle, and clk40 takes them together: the toggle having changed says there's a pixel.
// This is a synchronous path the fitter times, with no synchroniser.
//
// THE BUS (Analogue: Bus Communication, VIDEO). VS and HS are single-cycle pulses, an HS never within
// three clocks of a VS. RGB is zero with DE low, but for the "set scaler slot" word on the first clock
// after the last pixel of a line: the slot in bits 15:13, function 0 in bits 2:0. It takes effect
// the next frame.
//
// THE SLOT is found from the raster: the pixels in the last line and the lines in the last frame,
// each to the next of the sizes video.json lists. So a mode nobody listed still gets a picture.

`default_nettype none

module pocket_scanout (
    input  wire         clk80,
    input  wire         ce,             // a pixel on r, g, b, for one clock of clk80
    input  wire         hs, vs,         // levels
    input  wire         hb, vb,
    input  wire [7:0]   r, g, b,

    input  wire         clk40,
    input  wire         black,          // the picture black, the syncs running
    input  wire         diag_on,
    input  wire         bars,
    input  wire [15:0]  flags,
    input  wire [255:0] cnt,

    output reg  [23:0]  video_rgb,
    output reg          video_de,
    output reg          video_hs,
    output reg          video_vs,
    output wire         video_skip
);
    assign video_skip = 1'b0;

    // ------------------------------------------------------------------ clk80
    reg [23:0] h_rgb;
    reg        h_hs, h_vs, h_hb, h_vb, h_tog = 1'b0;
    always @(posedge clk80) if (ce) begin
        h_rgb <= {r, g, b};
        h_hs  <= hs;
        h_vs  <= vs;
        h_hb  <= hb;
        h_vb  <= vb;
        h_tog <= ~h_tog;
    end

    // ------------------------------------------------------------------ clk40
    reg [23:0] s_rgb;
    reg        s_hs, s_vs, s_hb, s_vb, s_tog = 1'b0, s_tog_d = 1'b0;
    always @(posedge clk40) begin
        s_rgb   <= h_rgb;
        s_hs    <= h_hs;
        s_vs    <= h_vs;
        s_hb    <= h_hb;
        s_vb    <= h_vb;
        s_tog   <= h_tog;
        s_tog_d <= s_tog;
    end
    wire new_pix = s_tog ^ s_tog_d;
    wire s_de    = ~(s_hb | s_vb);

    // ---------------------------------------------------------------- overlay
    wire [7:0] dr, dg, db;
    pocket_diag u_diag (
        .clk    (clk40),
        .ce_pix (new_pix),
        .hblank (s_hb),
        .vblank (s_vb),
        .r_in   (s_rgb[23:16]), .g_in (s_rgb[15:8]), .b_in (s_rgb[7:0]),
        .enable (diag_on),
        .bars   (bars),
        .flags  (flags),
        .cnt    (cnt),
        .r_out  (dr), .g_out (dg), .b_out (db)
    );

    // ------------------------------------------------------------------- slot
    reg [9:0] x_cnt = 10'd0, y_cnt = 10'd0, w_last = 10'd0, h_last = 10'd0;
    reg       de_seen = 1'b0, line_de = 1'b0, vs_q = 1'b0, hs_q = 1'b0;
    reg [2:0] slot = 3'd3;
    always @(posedge clk40) begin
        vs_q <= s_vs;
        if (new_pix && s_de) begin
            x_cnt   <= x_cnt + 10'd1;
            de_seen <= 1'b1;
        end
        if (de_seen && new_pix && !s_de) begin      // the line's last pixel has gone
            w_last  <= x_cnt;
            x_cnt   <= 10'd0;
            de_seen <= 1'b0;
            y_cnt   <= y_cnt + 10'd1;
        end
        if (s_vs && !vs_q) begin
            h_last <= y_cnt;
            y_cnt  <= 10'd0;
            slot   <= (h_last > 10'd300) ?
                      ((w_last <= 10'd256) ? 3'd0 : (w_last <= 10'd384) ? 3'd2 :
                       (w_last <= 10'd512) ? 3'd4 : 3'd3) :
                      ((w_last <= 10'd256) ? 3'd5 : (w_last <= 10'd384) ? 3'd6 :
                       (w_last <= 10'd512) ? 3'd1 : 3'd7);
        end
    end

    // -------------------------------------------------------------------- bus
    reg        s_hs_d = 1'b0, s_vs_d = 1'b0, line_on = 1'b0, hs_pend = 1'b0;
    reg [1:0]  since_vs = 2'd3;
    wire       vs_rise = s_vs & ~s_vs_d;
    always @(posedge clk40) begin
        s_hs_d <= s_hs;
        s_vs_d <= s_vs;

        video_vs <= vs_rise;
        if (vs_rise) since_vs <= 2'd0;
        else if (since_vs != 2'd3) since_vs <= since_vs + 2'd1;

        video_hs <= 1'b0;
        if ((s_hs & ~s_hs_d) || hs_pend) begin
            if (since_vs >= 2'd2 && !vs_rise) begin
                video_hs <= 1'b1;
                hs_pend  <= 1'b0;
            end else
                hs_pend  <= 1'b1;
        end

        video_de  <= 1'b0;
        video_rgb <= 24'd0;
        if (new_pix) begin
            if (s_de) begin
                video_de  <= 1'b1;
                video_rgb <= black ? 24'd0 : {dr, dg, db};
                line_on   <= 1'b1;
            end else if (line_on) begin
                video_rgb <= {8'd0, slot, 13'd0};
                line_on   <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
