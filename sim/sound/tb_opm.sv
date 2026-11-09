// SPDX-License-Identifier: GPL-3.0-or-later
// Both FM chips the board can carry, jt51 and IKAOPM, side by side on one clock and one bus, as
// X68K_top wires them: the bench's clock is the board's 40 MHz, the chip's 4 MHz an enable every
// 10 clocks and jt51's half-rate enable every 20 (opm_ce in core_top). opm_bench.cpp writes
// registers into both at the times MAME logged and keeps each chip's samples.
`default_nettype none
module tb_opm (
  input  wire        clk,
  input  wire        rst,
  input  wire        cs_n,
  input  wire        wr_n,
  input  wire        a0,
  input  wire [7:0]  din,
  output wire        jt_busy, ika_busy,   // each chip's busy flag, which the game polls before a write
  output wire        jt_sample,
  output wire signed [15:0] jt_l, jt_r, jt_xl, jt_xr,
  output wire        ika_sample,
  output wire signed [15:0] ika_l, ika_r, ika_xl, ika_xr
);
  reg [3:0] div10 = 0;
  reg [4:0] div20 = 0;
  reg cen = 0, cen_p1 = 0;
  always @(posedge clk) begin
    div10  <= div10 == 4'd9  ? 4'd0 : div10 + 4'd1;
    div20  <= div20 == 5'd19 ? 5'd0 : div20 + 5'd1;
    cen    <= div10 == 4'd9;
    cen_p1 <= div20 == 5'd19;
  end

  wire [7:0] jt_dout;
  assign jt_busy = jt_dout[7];
  jt51 u_jt (
    .rst(rst), .clk(clk), .cen(cen), .cen_p1(cen_p1), .cs_n(cs_n), .wr_n(wr_n), .a0(a0), .din(din),
    .dout(jt_dout), .ct1(), .ct2(), .irq_n(), .sample(jt_sample), .left(jt_l), .right(jt_r), .xleft(jt_xl), .xright(jt_xr)
  );

  IKAOPM #(.FULLY_SYNCHRONOUS(1), .FAST_RESET(1), .USE_BRAM(0)) u_ika (
    .i_EMUCLK(clk), .i_phiM_PCEN_n(~cen), .i_IC_n(~rst), .i_CS_n(cs_n), .i_RD_n(1'b1), .i_WR_n(wr_n), .i_A0(a0),
    .i_D(din), .o_D(), .o_D_OE(), .o_CT1(), .o_CT2(), .o_IRQ_n(), .o_SH1(), .o_SH2(), .o_SO(),
    .o_EMU_R_SAMPLE(), .o_EMU_L_SAMPLE(ika_sample), .o_EMU_R_EX(ika_xr), .o_EMU_L_EX(ika_xl),
    .o_EMU_R(ika_r), .o_EMU_L(ika_l), .o_phi1(), .o_EMU_BUSY_FLAG(ika_busy)
  );
endmodule
`default_nettype wire
