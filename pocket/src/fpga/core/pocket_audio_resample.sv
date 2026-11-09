// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket: the machine's sound, 62.5 kHz, to the Pocket's 48 kHz
//
// The board's mix changes at the YM2151's rate, 4 MHz / 64 (here 40.0125 MHz / 640, 62.52 kHz),
// the ADPCM's slower, held between. sound_i2s takes a sample at 48 kHz. Reading the held mix there
// folds the hold's images at 62.5 kHz +- f down to 14.5 kHz -+ f, off the music's pitch: 34 dB
// under the music below 16 kHz in Bubble Bobble, 18 dB in Gradius's brighter voices
// (tools/pocket/audio_alias.py). A straight line between samples got Gradius to 27 dB; this,
// a 24-tap polyphase low-pass taken at the 48 kHz tick's own position, to 53 (69 in Bubble Bobble).
//
//   * a sample of the mix every 640 clocks, free-running, into a ring of 32: the chip's output
//     changes once in each 640 at a fixed place, so each of its samples is taken once;
//   * the phase, the clocks since that sample over 10: 0..63, 64 positions a sample;
//   * 48 kHz ticks from an accumulator, 32 / 26,675 of 40.0125 MHz, 48,000 Hz exactly, the rate
//     sound_i2s makes from clk_74a, so each tick's sample is sent once;
//   * at each tick, the 24 latest samples times the phase's 24 taps (tools/pocket/audio_poly.py:
//     Kaiser-windowed sinc cut at 20 kHz, flat to 15 kHz, -28 dB at 24 and below -56 from 26),
//     left and right together, one tap a clock: the output stands about 12 samples (187 us measured) late.
//
// The output is held between ticks, as sound_i2s wants it.

`default_nettype none

module pocket_audio_resample #(
  parameter TAPS = "core/pocket_audio_poly.hex"  // read from the project folder
) (
  input  wire               clk,             // clk40, 40.0125 MHz
  input  wire signed [15:0] in_l,
  input  wire signed [15:0] in_r,
  output reg  signed [15:0] out_l = 16'sd0,
  output reg  signed [15:0] out_r = 16'sd0
);

  // ------------------------------------------------------------ the 62.5 kHz side
  reg  [9:0] div = 10'd0;                    // 0..639
  reg  [3:0] sub = 4'd0;                     // 0..9
  reg  [5:0] ph  = 6'd0;                     // the phase
  reg  [4:0] wp  = 5'd0;                     // the latest sample's place
  (* ramstyle = "MLAB, no_rw_check" *) reg signed [15:0] ring_l [0:31];
  (* ramstyle = "MLAB, no_rw_check" *) reg signed [15:0] ring_r [0:31];

  integer i;
  initial for (i = 0; i < 32; i = i + 1) begin ring_l[i] = 16'sd0; ring_r[i] = 16'sd0; end

  always @(posedge clk) begin
    div <= (div == 10'd639) ? 10'd0 : div + 10'd1;
    if (div == 10'd639) begin
      ring_l[wp + 5'd1] <= in_l;
      ring_r[wp + 5'd1] <= in_r;
      wp  <= wp + 5'd1;
      sub <= 4'd0;
      ph  <= 6'd0;
    end else begin
      sub <= (sub == 4'd9) ? 4'd0 : sub + 4'd1;
      if (sub == 4'd9) ph <= ph + 6'd1;
    end
  end

  // ------------------------------------------------------------ the 48 kHz side
  reg  [14:0] acc48 = 15'd0;
  wire        tick = acc48 >= 15'd26643;     // 26,675 - 32
  always @(posedge clk)
    acc48 <= tick ? acc48 + 15'd32 - 15'd26675 : acc48 + 15'd32;

  // the taps: phase * 32 + tap, the oldest sample's first
  reg  signed [17:0] rom [0:2047];
  initial $readmemh(TAPS, rom);

  // one tap a clock: address, then the sample and tap, then their products, then the sums. The
  // window is the 24 samples up to wp at the tick; a sample taken during the run goes into the
  // place 31 behind, outside it.
  reg        run = 1'b0;
  reg  [4:0] j = 5'd0, base = 5'd0;
  reg  [5:0] ph_s = 6'd0;
  reg        v1 = 1'b0, v2 = 1'b0, e1 = 1'b0, e2 = 1'b0, e3 = 1'b0;
  reg  signed [15:0] x_l, x_r;
  reg  signed [17:0] c;
  reg  signed [33:0] p_l, p_r;
  reg  signed [39:0] s_l = 40'sd0, s_r = 40'sd0;

  wire signed [39:0] r_l = s_l + 40'sd65536;  // rounded at 2^17
  wire signed [39:0] r_r = s_r + 40'sd65536;
  wire signed [22:0] q_l = r_l[39:17];
  wire signed [22:0] q_r = r_r[39:17];

  always @(posedge clk) begin
    if (tick) begin
      run  <= 1'b1;
      j    <= 5'd0;
      base <= wp - 5'd23;
      ph_s <= ph;
    end else if (run) begin
      j <= j + 5'd1;
      if (j == 5'd23) run <= 1'b0;
    end

    x_l <= ring_l[base + j];
    x_r <= ring_r[base + j];
    c   <= rom[{ph_s, j}];
    v1  <= run;
    e1  <= run && j == 5'd23;

    p_l <= x_l * c;
    p_r <= x_r * c;
    v2  <= v1;
    e2  <= e1;

    if (tick) begin
      s_l <= 40'sd0;
      s_r <= 40'sd0;
    end else if (v2) begin
      s_l <= s_l + p_l;
      s_r <= s_r + p_r;
    end
    e3 <= e2;

    if (e3) begin
      out_l <= (q_l > 23'sd32767) ? 16'sd32767 : (q_l < -23'sd32768) ? -16'sd32768 : q_l[15:0];
      out_r <= (q_r > 23'sd32767) ? 16'sd32767 : (q_r < -23'sd32768) ? -16'sd32768 : q_r[15:0];
    end
  end

endmodule

`default_nettype wire
