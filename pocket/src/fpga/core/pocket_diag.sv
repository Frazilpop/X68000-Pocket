// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket — diagnostic overlay
//
// WHY THIS EXISTS. The first build on a real Pocket came up black, and a
// black screen says nothing: no video signal, a core still held in reset, a
// ROM that never finished loading, SDRAM returning garbage to the 68000 and
// a 68000 that crashed on its first fetch all look the same. This draws the
// shell's own state over the picture, in the shell, needing nothing from the
// board but its timing strobes, so it is visible whenever the Pocket is
// receiving video at all.
//
// It sits inside pocket_scanout and is combinational on the board's pixel: the
// strobes arrive aligned with r/g/b on ce_pix, and a registered overlay would be
// one pixel late. The x/y it needs are rebuilt from hblank/vblank, so it does not
// depend on the board exporting counters.
//
// WHAT IT DRAWS (coordinates in the visible window)
//
//   y 1..6     sixteen flag cells, 12 px wide on a 16 px pitch, flag[0] at
//              the left. GREEN = 1, RED = 0.
//   y 16..47   eight counters as "<j> <8 hex digits>" in 8x8 text, white on
//              black: counters 0-3 down the left column (x 0..79), 4-7 down
//              the right (x 160..239). Nibbles are printed most significant
//              first.
//
// `bars` replaces the board's picture with eight vertical colour bars so a
// live video path is unmistakable even when the board draws nothing; `blank`
// replaces it with black (the scan-out's own raster, before the boot ROM is
// in, when the board has no picture to give).
//
// `msg` puts two centred lines in the middle of a 256-wide picture, grey on
// black, whatever the overlay is doing. These are the only things a player is
// meant to read, and the whole list:
//
//   msg  lines                                  when
//   1    BOOT ROM NOT FOUND / BOOT.ROM          the boot ROM's read failed part way
//   2    NO DISK IMAGES / IN THE GAME FOLDER    the game has no disk in any slot
//
// (With no boot ROM file at all APF refuses the launch itself.)
//
// Glyphs (IBM CP437 8x8) for the hex digits and the letters the messages
// need, nothing more.

`default_nettype none

module pocket_diag (
    input  wire         clk,          // the scan-out's clock, with ce_pix
    input  wire         ce_pix,
    input  wire         hblank, vblank,
    input  wire [7:0]   r_in, g_in, b_in,

    input  wire         enable,       // draw flags and counters
    input  wire         bars,         // colour bars instead of the picture
    input  wire         blank,        // black instead of the picture
    input  wire [1:0]   msg,          // the message, 0 for none (above)
    input  wire [15:0]  flags,
    input  wire [255:0] cnt,          // counter j at [32*j +: 32]

    output wire [7:0]   r_out, g_out, b_out
);

    // --------------------------------------------------------- position
    // x and y of the pixel on the inputs during this ce_pix. x restarts in
    // every horizontal blank, y in vertical blank and steps at the end of
    // every active line.
    reg [9:0] x = 10'd0;
    reg [9:0] y = 10'd0;
    reg       hb_q = 1'b1;
    always @(posedge clk) if (ce_pix) begin
        hb_q <= hblank;
        x <= hblank ? 10'd0 : x + 10'd1;
        if (vblank)               y <= 10'd0;
        else if (hblank && !hb_q) y <= y + 10'd1;
    end

    // --------------------------------------------------------------- font
    function automatic [7:0] glyph(input [4:0] d, input [2:0] row);
        // 0-F the hex digits, then O T R M N U X _ . , 25 a space, then I S K G H L
        case ({d, row})
        8'h00: glyph = 8'h7C; 8'h01: glyph = 8'hC6; 8'h02: glyph = 8'hCE; 8'h03: glyph = 8'hDE;
        8'h04: glyph = 8'hF6; 8'h05: glyph = 8'hE6; 8'h06: glyph = 8'h7C; 8'h07: glyph = 8'h00;
        8'h08: glyph = 8'h30; 8'h09: glyph = 8'h70; 8'h0A: glyph = 8'h30; 8'h0B: glyph = 8'h30;
        8'h0C: glyph = 8'h30; 8'h0D: glyph = 8'h30; 8'h0E: glyph = 8'hFC; 8'h0F: glyph = 8'h00;
        8'h10: glyph = 8'h78; 8'h11: glyph = 8'hCC; 8'h12: glyph = 8'h0C; 8'h13: glyph = 8'h38;
        8'h14: glyph = 8'h60; 8'h15: glyph = 8'hCC; 8'h16: glyph = 8'hFC; 8'h17: glyph = 8'h00;
        8'h18: glyph = 8'h78; 8'h19: glyph = 8'hCC; 8'h1A: glyph = 8'h0C; 8'h1B: glyph = 8'h38;
        8'h1C: glyph = 8'h0C; 8'h1D: glyph = 8'hCC; 8'h1E: glyph = 8'h78; 8'h1F: glyph = 8'h00;
        8'h20: glyph = 8'h1C; 8'h21: glyph = 8'h3C; 8'h22: glyph = 8'h6C; 8'h23: glyph = 8'hCC;
        8'h24: glyph = 8'hFE; 8'h25: glyph = 8'h0C; 8'h26: glyph = 8'h1E; 8'h27: glyph = 8'h00;
        8'h28: glyph = 8'hFC; 8'h29: glyph = 8'hC0; 8'h2A: glyph = 8'hF8; 8'h2B: glyph = 8'h0C;
        8'h2C: glyph = 8'h0C; 8'h2D: glyph = 8'hCC; 8'h2E: glyph = 8'h78; 8'h2F: glyph = 8'h00;
        8'h30: glyph = 8'h38; 8'h31: glyph = 8'h60; 8'h32: glyph = 8'hC0; 8'h33: glyph = 8'hF8;
        8'h34: glyph = 8'hCC; 8'h35: glyph = 8'hCC; 8'h36: glyph = 8'h78; 8'h37: glyph = 8'h00;
        8'h38: glyph = 8'hFC; 8'h39: glyph = 8'hCC; 8'h3A: glyph = 8'h0C; 8'h3B: glyph = 8'h18;
        8'h3C: glyph = 8'h30; 8'h3D: glyph = 8'h30; 8'h3E: glyph = 8'h30; 8'h3F: glyph = 8'h00;
        8'h40: glyph = 8'h78; 8'h41: glyph = 8'hCC; 8'h42: glyph = 8'hCC; 8'h43: glyph = 8'h78;
        8'h44: glyph = 8'hCC; 8'h45: glyph = 8'hCC; 8'h46: glyph = 8'h78; 8'h47: glyph = 8'h00;
        8'h48: glyph = 8'h78; 8'h49: glyph = 8'hCC; 8'h4A: glyph = 8'hCC; 8'h4B: glyph = 8'h7C;
        8'h4C: glyph = 8'h0C; 8'h4D: glyph = 8'h18; 8'h4E: glyph = 8'h70; 8'h4F: glyph = 8'h00;
        8'h50: glyph = 8'h30; 8'h51: glyph = 8'h78; 8'h52: glyph = 8'hCC; 8'h53: glyph = 8'hCC;
        8'h54: glyph = 8'hFC; 8'h55: glyph = 8'hCC; 8'h56: glyph = 8'hCC; 8'h57: glyph = 8'h00;
        8'h58: glyph = 8'hFC; 8'h59: glyph = 8'h66; 8'h5A: glyph = 8'h66; 8'h5B: glyph = 8'h7C;
        8'h5C: glyph = 8'h66; 8'h5D: glyph = 8'h66; 8'h5E: glyph = 8'hFC; 8'h5F: glyph = 8'h00;
        8'h60: glyph = 8'h3C; 8'h61: glyph = 8'h66; 8'h62: glyph = 8'hC0; 8'h63: glyph = 8'hC0;
        8'h64: glyph = 8'hC0; 8'h65: glyph = 8'h66; 8'h66: glyph = 8'h3C; 8'h67: glyph = 8'h00;
        8'h68: glyph = 8'hF8; 8'h69: glyph = 8'h6C; 8'h6A: glyph = 8'h66; 8'h6B: glyph = 8'h66;
        8'h6C: glyph = 8'h66; 8'h6D: glyph = 8'h6C; 8'h6E: glyph = 8'hF8; 8'h6F: glyph = 8'h00;
        8'h70: glyph = 8'hFE; 8'h71: glyph = 8'h62; 8'h72: glyph = 8'h68; 8'h73: glyph = 8'h78;
        8'h74: glyph = 8'h68; 8'h75: glyph = 8'h62; 8'h76: glyph = 8'hFE; 8'h77: glyph = 8'h00;
        8'h78: glyph = 8'hFE; 8'h79: glyph = 8'h62; 8'h7A: glyph = 8'h68; 8'h7B: glyph = 8'h78;
        8'h7C: glyph = 8'h68; 8'h7D: glyph = 8'h60; 8'h7E: glyph = 8'hF0; 8'h7F: glyph = 8'h00;
        8'h80: glyph = 8'h38; 8'h81: glyph = 8'h6C; 8'h82: glyph = 8'hC6; 8'h83: glyph = 8'hC6;
        8'h84: glyph = 8'hC6; 8'h85: glyph = 8'h6C; 8'h86: glyph = 8'h38; 8'h87: glyph = 8'h00;
        8'h88: glyph = 8'hFC; 8'h89: glyph = 8'hB4; 8'h8A: glyph = 8'h30; 8'h8B: glyph = 8'h30;
        8'h8C: glyph = 8'h30; 8'h8D: glyph = 8'h30; 8'h8E: glyph = 8'h78; 8'h8F: glyph = 8'h00;
        8'h90: glyph = 8'hFC; 8'h91: glyph = 8'h66; 8'h92: glyph = 8'h66; 8'h93: glyph = 8'h7C;
        8'h94: glyph = 8'h6C; 8'h95: glyph = 8'h66; 8'h96: glyph = 8'hE6; 8'h97: glyph = 8'h00;
        8'h98: glyph = 8'hC6; 8'h99: glyph = 8'hEE; 8'h9A: glyph = 8'hFE; 8'h9B: glyph = 8'hFE;
        8'h9C: glyph = 8'hD6; 8'h9D: glyph = 8'hC6; 8'h9E: glyph = 8'hC6; 8'h9F: glyph = 8'h00;
        8'hA0: glyph = 8'hC6; 8'hA1: glyph = 8'hE6; 8'hA2: glyph = 8'hF6; 8'hA3: glyph = 8'hDE;
        8'hA4: glyph = 8'hCE; 8'hA5: glyph = 8'hC6; 8'hA6: glyph = 8'hC6; 8'hA7: glyph = 8'h00;
        8'hA8: glyph = 8'hCC; 8'hA9: glyph = 8'hCC; 8'hAA: glyph = 8'hCC; 8'hAB: glyph = 8'hCC;
        8'hAC: glyph = 8'hCC; 8'hAD: glyph = 8'hCC; 8'hAE: glyph = 8'hFC; 8'hAF: glyph = 8'h00;
        8'hB0: glyph = 8'hC6; 8'hB1: glyph = 8'hC6; 8'hB2: glyph = 8'h6C; 8'hB3: glyph = 8'h38;
        8'hB4: glyph = 8'h38; 8'hB5: glyph = 8'h6C; 8'hB6: glyph = 8'hC6; 8'hB7: glyph = 8'h00;
        8'hB8: glyph = 8'h00; 8'hB9: glyph = 8'h00; 8'hBA: glyph = 8'h00; 8'hBB: glyph = 8'h00;
        8'hBC: glyph = 8'h00; 8'hBD: glyph = 8'h00; 8'hBE: glyph = 8'h00; 8'hBF: glyph = 8'hFF;
        8'hC0: glyph = 8'h00; 8'hC1: glyph = 8'h00; 8'hC2: glyph = 8'h00; 8'hC3: glyph = 8'h00;
        8'hC4: glyph = 8'h00; 8'hC5: glyph = 8'h30; 8'hC6: glyph = 8'h30; 8'hC7: glyph = 8'h00;
        8'hD0: glyph = 8'h78; 8'hD1: glyph = 8'h30; 8'hD2: glyph = 8'h30; 8'hD3: glyph = 8'h30;
        8'hD4: glyph = 8'h30; 8'hD5: glyph = 8'h30; 8'hD6: glyph = 8'h78; 8'hD7: glyph = 8'h00;
        8'hD8: glyph = 8'h78; 8'hD9: glyph = 8'hCC; 8'hDA: glyph = 8'hE0; 8'hDB: glyph = 8'h70;
        8'hDC: glyph = 8'h1C; 8'hDD: glyph = 8'hCC; 8'hDE: glyph = 8'h78; 8'hDF: glyph = 8'h00;
        8'hE0: glyph = 8'hE6; 8'hE1: glyph = 8'h66; 8'hE2: glyph = 8'h6C; 8'hE3: glyph = 8'h78;
        8'hE4: glyph = 8'h6C; 8'hE5: glyph = 8'h66; 8'hE6: glyph = 8'hE6; 8'hE7: glyph = 8'h00;
        8'hE8: glyph = 8'h3C; 8'hE9: glyph = 8'h66; 8'hEA: glyph = 8'hC0; 8'hEB: glyph = 8'hC0;
        8'hEC: glyph = 8'hCE; 8'hED: glyph = 8'h66; 8'hEE: glyph = 8'h3E; 8'hEF: glyph = 8'h00;
        8'hF0: glyph = 8'hCC; 8'hF1: glyph = 8'hCC; 8'hF2: glyph = 8'hCC; 8'hF3: glyph = 8'hFC;
        8'hF4: glyph = 8'hCC; 8'hF5: glyph = 8'hCC; 8'hF6: glyph = 8'hCC; 8'hF7: glyph = 8'h00;
        8'hF8: glyph = 8'hF0; 8'hF9: glyph = 8'h60; 8'hFA: glyph = 8'h60; 8'hFB: glyph = 8'h60;
        8'hFC: glyph = 8'h62; 8'hFD: glyph = 8'h66; 8'hFE: glyph = 8'hFE; 8'hFF: glyph = 8'h00;
        default: glyph = 8'h00;
        endcase
    endfunction

    // ---------------------------------------------------------- flags row
    wire        in_flags = enable && (y >= 10'd1) && (y < 10'd7) &&
                           (x[9:4] < 6'd16) && (x[3:0] < 4'd12);
    wire        flag_on  = flags[x[7:4]];

    // ------------------------------------------------------- counter rows
    wire        col      = (x >= 10'd160);
    wire [9:0]  xr       = col ? x - 10'd160 : x;            // 0..159, and on in a wider picture
    wire        in_text  = enable && (y >= 10'd16) && (y < 10'd48) && (xr < 10'd80);
    wire [1:0]  row_k    = y[4:3] - 2'd2;                     // (y-16)>>3
    wire [2:0]  ctr      = {col, row_k};                      // counter index j
    wire [3:0]  ch       = xr[6:3];                           // character 0..9
    wire [2:0]  ccol     = xr[2:0];
    wire [31:0] val      = cnt[32*ctr +: 32];
    wire [2:0]  nib      = 3'd7 - (ch[2:0] - 3'd2);           // digit ch-2, MS first
    wire [3:0]  digit    = (ch == 4'd0) ? {1'b0, ctr} : val[4*nib +: 4];
    wire        blank_ch = (ch == 4'd1);
    wire [7:0]  g_row    = glyph({1'b0, digit}, y[2:0]);
    wire        text_on  = !blank_ch && g_row[3'd7 - ccol];

    // ------------------------------------------------------- the message
    // Line 0 at y 112..119, line 1 at y 128..135, each centred: on whole character rows, so y[2:0] is
    // the glyph's row. The text is a string, eight bits a character from the left.
    localparam [4:0] C_O = 5'h10, C_T = 5'h11, C_R = 5'h12, C_M = 5'h13, C_N = 5'h14,
                     C_U = 5'h15, C_X = 5'h16, C_US = 5'h17, C_DOT = 5'h18, C_SP = 5'h19,
                     C_I = 5'h1A, C_S = 5'h1B, C_K = 5'h1C, C_G = 5'h1D, C_H = 5'h1E, C_L = 5'h1F;
    localparam integer ML = 18;                                 // the longest line
    localparam [8*ML-1:0] M1_0 = "BOOT ROM NOT FOUND", M1_1 = "     BOOT.ROM     ",
                          M2_0 = "  NO DISK IMAGES  ", M2_1 = "IN THE GAME FOLDER";
    function automatic [4:0] font_of(input [7:0] c);
        case (c)
            "0": font_of = 5'h0; "1": font_of = 5'h1; "2": font_of = 5'h2; "3": font_of = 5'h3;
            "4": font_of = 5'h4; "5": font_of = 5'h5; "6": font_of = 5'h6; "7": font_of = 5'h7;
            "8": font_of = 5'h8; "9": font_of = 5'h9; "A": font_of = 5'hA; "B": font_of = 5'hB;
            "C": font_of = 5'hC; "D": font_of = 5'hD; "E": font_of = 5'hE; "F": font_of = 5'hF;
            "O": font_of = C_O;  "T": font_of = C_T;  "R": font_of = C_R;  "M": font_of = C_M;
            "N": font_of = C_N;  "U": font_of = C_U;  "X": font_of = C_X;  "_": font_of = C_US;
            ".": font_of = C_DOT; "I": font_of = C_I; "S": font_of = C_S;  "K": font_of = C_K;
            "G": font_of = C_G;  "H": font_of = C_H;  "L": font_of = C_L;
            default: font_of = C_SP;
        endcase
    endfunction
    function automatic [7:0] msg_char(input [1:0] m, input ln, input [4:0] i);
        reg [8*ML-1:0] t;
        t = (m == 2'd1) ? (ln ? M1_1 : M1_0) : (ln ? M2_1 : M2_0);
        msg_char = (i < ML) ? t[8*(ML-1-i) +: 8] : " ";
    endfunction

    wire        m_ln     = (y >= 10'd128);
    wire        m_y      = m_ln ? (y < 10'd136) : (y >= 10'd112 && y < 10'd120);
    wire [9:0]  m_x      = x - 10'd56;                          // 18 characters from x 56 to 200
    wire        m_in     = (msg != 2'd0) && m_y && (x >= 10'd56 && x < 10'd200);
    wire [7:0]  m_row    = glyph(font_of(msg_char(msg, m_ln, m_x[7:3])), y[2:0]);
    wire        m_on     = m_in && m_row[3'd7 - m_x[2:0]];

    // ---------------------------------------------------------- bars
    // White, yellow, cyan, green, magenta, red, blue, dark grey: 32 px each.
    reg [23:0] bar;
    always @(*) begin
        case (x[9:5])
        5'd0: bar = 24'hFFFFFF; 5'd1: bar = 24'hFFFF00;
        5'd2: bar = 24'h00FFFF; 5'd3: bar = 24'h00FF00;
        5'd4: bar = 24'hFF00FF; 5'd5: bar = 24'hFF0000;
        5'd6: bar = 24'h0000FF; default: bar = 24'h404040;
        endcase
    end

    // ---------------------------------------------------------- output
    wire [23:0] base = bars ? bar : (blank || msg != 2'd0) ? 24'h000000 : {r_in, g_in, b_in};
    wire [23:0] pix  = in_flags ? (flag_on ? 24'h008000 : 24'h800000)
                     : in_text  ? (text_on ? 24'h707070 : 24'h000000)
                     : m_on     ? 24'hC0C0C0
                     : base;
    assign {r_out, g_out, b_out} = pix;

endmodule

`default_nettype wire
