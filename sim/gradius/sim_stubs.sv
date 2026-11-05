// SPDX-License-Identifier: GPL-3.0-or-later
// For the simulation: the shell's vendor cells. The clocks come from the C++ side, through ports of
// the top module; the PLL says locked after a while.
module pocket_pll_core (
  input  wire refclk,
  output wire clk80, clk40, clk_sdram_ps, clk40_90,
  output wire locked
);
  assign clk80        = sim_port.clk80;
  assign clk40        = sim_port.clk40;
  assign clk_sdram_ps = ~sim_port.clk80;
  assign clk40_90     = sim_port.clk40_90;
  reg [7:0] n = 0;
  always @(posedge refclk) if (n != 8'hFF) n <= n + 8'd1;
  assign locked = n == 8'hFF;
endmodule

// A DDIO output: datain_h while the clock is high, datain_l while it's low.
module pin_ddio_clk (input wire datain_h, datain_l, outclock, output wire dataout);
  assign dataout = outclock ? datain_h : datain_l;
endmodule

// The four-entry dcfifo in pocket-utils' sync_fifo, as that uses it.
module dcfifo #(
  parameter intended_device_family = "", lpm_numwords = 4, lpm_showahead = "OFF", lpm_type = "dcfifo",
  parameter lpm_width = 8, lpm_widthu = 2, overflow_checking = "ON", rdsync_delaypipe = 5, read_aclr_synch = "",
  parameter underflow_checking = "ON", use_eab = "ON", wrsync_delaypipe = 5, write_aclr_synch = ""
) (
  input  wire aclr, wrclk, rdclk, wrreq, rdreq,
  input  wire [lpm_width-1:0] data,
  output reg  [lpm_width-1:0] q,
  output wire rdempty, wrfull, rdfull, wrempty,
  output wire [lpm_widthu-1:0] rdusedw, wrusedw,
  input  wire eccstatus
);
  reg [lpm_width-1:0] m [0:lpm_numwords-1];
  reg [lpm_widthu:0] wp = 0, rp = 0, wp_s1 = 0, wp_s = 0;
  always @(posedge wrclk) if (wrreq) begin m[wp[lpm_widthu-1:0]] <= data; wp <= wp + 1'b1; end
  always @(posedge rdclk) begin
    wp_s1 <= wp; wp_s <= wp_s1;
    if (rdreq && rp != wp_s) begin q <= m[rp[lpm_widthu-1:0]]; rp <= rp + 1'b1; end
  end
  assign rdempty = rp == wp_s;
  assign wrfull = 1'b0; assign rdfull = 1'b0; assign wrempty = 1'b0;
  assign rdusedw = '0; assign wrusedw = '0;
endmodule
