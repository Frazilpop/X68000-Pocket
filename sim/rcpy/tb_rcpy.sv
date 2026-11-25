// SPDX-License-Identifier: GPL-3.0-or-later
// The raster copy's two halves together: rastercopy (the board's VHDL, through GHDL) asking, and
// tvram_psram on its chip's model answering, with the C++ bench playing the program and the renderer.
`default_nettype none
module tb_rcpy #(parameter int LAT_R = 4, parameter int LAT_W = 4) (
  input  wire        clk80,
  input  wire        clk40,
  input  wire        rstn,
  input  wire        ce,
  input  wire        start,
  input  wire        stop,
  input  wire [15:0] t_addr,
  input  wire        t_rd,
  output wire        busy,
  output wire        t_ready,
  output wire        ack,
  output wire        cpy,
  output int unsigned violations
);
  wire [16:0] srcaddr, dstaddr;
  wire [3:0]  cplane;
  rastercopy u_rc (
    .src(8'h10), .dst(8'h20), .plane(4'hF), .start(start), .stop(stop), .busy(busy),
    .t_base(17'd0), .srcaddr(srcaddr), .dstaddr(dstaddr), .cplane(cplane), .cpy(cpy), .ack(ack),
    .clk(clk40), .ce(ce), .rstn(rstn));

  wire [21:16] ta;
  wire [15:0] tdo, tmo, cpu_rdat;
  wire toe, tmoe, trun, tadv, tcre, tce, toen, twe, tub, tlb, cpu_ack, cal_fail, rd_ph;
  wire [2:0] rd_lat, wr_lat;
  wire [15:0] q [0:7];
  tvram_psram u_t (
    .clk(clk40), .rstn(rstn),
    .cpu_addr(18'd0), .cpu_wdat(16'd0), .cpu_rd(1'b0), .cpu_wr(2'b00), .cpu_rmw(2'b00), .cpu_rmwmask(16'd0),
    .cpu_rdat(cpu_rdat), .cpu_ack(cpu_ack),
    .cpy_src(srcaddr[10:0]), .cpy_dst(dstaddr[10:0]), .cpy_plane(cplane), .cpy_req(cpy), .cpy_ack(ack),
    .t0_addr(t_addr), .t0_rd(t_rd), .t0_rdat0(q[0]), .t0_rdat1(q[1]), .t0_rdat2(q[2]), .t0_rdat3(q[3]),
    .t1_addr(16'd0), .t1_rd(1'b0), .t1_rdat0(q[4]), .t1_rdat1(q[5]), .t1_rdat2(q[6]), .t1_rdat3(q[7]),
    .ready(t_ready), .cal_fail(cal_fail), .rd_lat(rd_lat), .rd_ph(rd_ph), .wr_lat(wr_lat),
    .cram_run(trun), .cram_a(ta), .cram_dq_o(tdo), .cram_dq_oe(toe), .cram_dq_i(tmoe ? tmo : tdo),
    .cram_adv_n(tadv), .cram_cre(tcre), .cram_ce0_n(tce), .cram_oe_n(toen), .cram_we_n(twe),
    .cram_ub_n(tub), .cram_lb_n(tlb));

  /* verilator lint_off UNUSEDSIGNAL */
  wire [15:0] bcr;
  /* verilator lint_on UNUSEDSIGNAL */
  psram_model #(.LAT_R(LAT_R), .LAT_W(LAT_W)) m_t (
    .clk(clk80), .a(ta), .dq_i(tdo), .dq_oe_i(toe), .dq_o(tmo), .dq_oe_o(tmoe),
    .cram_clk(trun && !clk40), .adv_n(tadv), .cre(tcre), .ce0_n(tce), .oe_n(toen), .we_n(twe),
    .ub_n(tub), .lb_n(tlb), .violations(violations), .bcr(bcr));
endmodule
`default_nettype wire
