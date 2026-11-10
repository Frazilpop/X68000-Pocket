// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket: the board's scan line to the APF video bus, on one fixed clock
//
// THE CLOCK. The machine's dots come at 4.9 to 34.8 MHz as the program chooses, from a fractional
// enable on clk80. APF's video clock stays at 40.0125 MHz in every mode: DE is high across a line's
// active span, and SKIP is high on every clock of it that carries no new pixel, so the scaler latches
// one value a dot. Nothing to reprogram when a game changes mode, and no line store beyond the board's own.
//
// THE CROSSING. clk40 rises with every other edge of clk80, and two pixels are always at least two
// clocks of clk80 apart, so at most one lands between two edges of clk40. So a pixel is held on clk80
// with a toggle, and clk40 takes them together: the toggle having changed says there's a pixel.
// This is a synchronous path the fitter times, with no synchroniser.
//
// THE BUS (Analogue: Bus Communication, VIDEO). VS and HS are single-cycle pulses, an HS never within
// three clocks of a VS. DE rises and falls once a line, never in the same clock as HS or the clock
// next to it, and SKIP is only ever high with DE. The scaler takes its "set scaler slot" word on the
// first clock after DE falls: the slot in bits 15:13, function 0 in bits 2:0, taking effect the next
// frame. Everywhere else with DE low the bus is zero. (DE a clock a pixel, with gaps inside a line,
// is what the first build did: the Pocket showed a red field with fine vertical lines, 5 Nov.)
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
    input  wire         own_raster,     // the boot ROM not in yet: no syncs from the board, black
    input  wire         diag_on,
    input  wire         bars,
    input  wire         msg,            // "BOOT ROM NOT FOUND" in the middle
    input  wire [15:0]  flags,
    input  wire [255:0] cnt,

    output reg  [23:0]  video_rgb,
    output reg          video_de = 1'b0,
    output reg          video_hs,
    output reg          video_vs,
    output reg          video_skip = 1'b0
);

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

    // ------------------------------------------------------- the bars' raster
    // Until the boot ROM is in, the IPL hasn't set the CRTC, which gives no syncs at all. So the screen
    // (black, the message, or the bars and the overlay when it's on) runs on a raster of the scan-out's
    // own: 256 x 256 (slot 5), a pixel every 8 clocks, 320 a line (64 us), 262 lines.
    reg        own = 1'b1, own_q = 1'b1;
    reg  [2:0] o_div = 3'd0;
    reg  [8:0] o_x = 9'd0, o_y = 9'd0;
    always @(posedge clk40) begin
        own_q <= own_raster;
        own   <= own_q;
        o_div <= o_div + 3'd1;
        if (o_div == 3'd0) begin
            o_x <= (o_x == 9'd319) ? 9'd0 : o_x + 9'd1;
            if (o_x == 9'd319) o_y <= (o_y == 9'd261) ? 9'd0 : o_y + 9'd1;
        end
    end
    wire o_hb = (o_x < 9'd32) || (o_x >= 9'd288);
    wire o_vb = (o_y < 9'd3)  || (o_y >= 9'd259);

    wire        new_pix = own ? (o_div == 3'd1) : (s_tog ^ s_tog_d);
    wire        m_hb    = own ? o_hb : s_hb;
    wire        m_vb    = own ? o_vb : s_vb;
    wire        m_hs    = own ? (o_x >= 9'd4 && o_x < 9'd20) : s_hs;
    wire        m_vs    = own ? (o_y == 9'd0) : s_vs;
    wire        s_de    = ~(m_hb | m_vb);

    // ---------------------------------------------------------------- overlay
    wire [7:0] dr, dg, db;
    pocket_diag u_diag (
        .clk    (clk40),
        .ce_pix (new_pix),
        .hblank (m_hb),
        .vblank (m_vb),
        .r_in   (s_rgb[23:16]), .g_in (s_rgb[15:8]), .b_in (s_rgb[7:0]),
        .enable (diag_on),
        .bars   (bars),
        .blank  (own),
        .msg    (msg),
        .flags  (flags),
        .cnt    (cnt),
        .r_out  (dr), .g_out (dg), .b_out (db)
    );

    // ------------------------------------------------------------------- slot
    reg [9:0] x_cnt = 10'd0, y_cnt = 10'd0, w_last = 10'd0, h_last = 10'd0;
    reg       de_seen = 1'b0, line_de = 1'b0, vs_q = 1'b0, hs_q = 1'b0;
    reg [2:0] slot = 3'd3;
    always @(posedge clk40) begin
        vs_q <= m_vs;
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
        if (m_vs && !vs_q) begin
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
    // s_de is the level of the latest pixel, and changes only with one: DE rises on a line's first
    // pixel and falls on the first blank one after its last, SKIP fills the clocks between. DE may
    // only rise once an HS has gone out since it last fell, so a raster with no syncs (the CRTC before
    // the IPL has set it) gives no DE at all rather than one APF can't read.
    reg        s_hs_d = 1'b0, s_vs_d = 1'b0, hs_pend = 1'b0, line_ok = 1'b0;
    reg [1:0]  since_vs = 2'd3;
    wire       vs_rise = m_vs & ~s_vs_d;
    wire       de_next = s_de & (video_de | line_ok);
    always @(posedge clk40) begin
        s_hs_d <= m_hs;
        s_vs_d <= m_vs;

        video_vs <= vs_rise;
        if (vs_rise) since_vs <= 2'd0;
        else if (since_vs != 2'd3) since_vs <= since_vs + 2'd1;

        // HS out only with DE low in this clock and the one before it; DE no sooner than a clock after
        video_hs <= 1'b0;
        if ((m_hs & ~s_hs_d) || hs_pend) begin
            if (since_vs >= 2'd2 && !vs_rise && !de_next && !video_de) begin
                video_hs <= 1'b1;
                hs_pend  <= 1'b0;
            end else
                hs_pend  <= 1'b1;
        end
        if (video_hs)              line_ok <= 1'b1;
        else if (de_next)          line_ok <= 1'b0;

        video_de   <= de_next;
        video_skip <= de_next & ~new_pix;
        if (de_next)
            video_rgb <= black ? 24'd0 : {dr, dg, db};
        else if (video_de)
            video_rgb <= {8'd0, slot, 13'd0};          // DE has just fallen
        else
            video_rgb <= 24'd0;
    end

endmodule

`default_nettype wire
