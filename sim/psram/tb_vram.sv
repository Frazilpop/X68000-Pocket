// SPDX-License-Identifier: GPL-3.0-or-later
// The two VRAM ports on their chips' models, with every other input from the C++ bench.
`default_nettype none
module tb_vram #(parameter int LAT_R = 4, parameter int LAT_W = 4) (
  input  wire        clk80,
  input  wire        clk40,
  input  wire        rstn,
  input  wire        hcomp,
  // graphics
  input  wire [17:0] g_addr, input wire g_rd, output wire [15:0] g_q,
  input  wire [9:0]  g_caddr, input wire [3:0] g_clear,
  input  wire [17:0] gc_addr, input wire [15:0] gc_wdat, output wire [15:0] gc_rdat,
  input  wire [1:0]  gc_wr, input wire gc_rd, input wire [1:0] gc_rmw, input wire [15:0] gc_mask,
  output wire        gc_ack,
  output wire        g_ready, g_fail, g_late,
  output wire [6:0]  g_lat,
  // text
  input  wire [15:0] t_addr, input wire t_rd, output wire [15:0] t_q0, t_q1, t_q2, t_q3,
  input  wire [17:0] tc_addr, input wire [15:0] tc_wdat, output wire [15:0] tc_rdat,
  input  wire [1:0]  tc_wr, input wire tc_rd, input wire [1:0] tc_rmw, input wire [15:0] tc_mask,
  output wire        tc_ack,
  input  wire [10:0] cpy_src, cpy_dst, input wire [3:0] cpy_plane, input wire cpy_req, output wire cpy_ack,
  output wire        t_ready, t_fail,
  output wire [6:0]  t_lat,
  output int unsigned violations
);
  wire [21:16] ga, ta;
  wire [15:0] gdo, tdo, gmo, tmo;
  wire goe, toe, gmoe, tmoe, grun, trun;
  wire gadv, gcre, gce, goen, gwe, gub, glb;
  wire tadv, tcre, tce, toen, twe, tub, tlb;
  wire [15:0] gdi = gmoe ? gmo : gdo;
  wire [15:0] tdi = tmoe ? tmo : tdo;
  wire [15:0] unused_q [0:6];

  gvram_psram u_g (
    .clk(clk40), .rstn(rstn), .hcomp(hcomp),
    .g00_addr(g_addr), .g00_rd(g_rd), .g00_rdat(g_q),
    .g01_addr(18'd0), .g01_rd(1'b0), .g01_rdat(unused_q[0]),
    .g02_addr(18'd0), .g02_rd(1'b0), .g02_rdat(unused_q[1]),
    .g03_addr(18'd0), .g03_rd(1'b0), .g03_rdat(unused_q[2]),
    .g10_addr(18'd0), .g10_rd(1'b0), .g10_rdat(unused_q[3]),
    .g11_addr(18'd0), .g11_rd(1'b0), .g11_rdat(unused_q[4]),
    .g12_addr(18'd0), .g12_rd(1'b0), .g12_rdat(unused_q[5]),
    .g13_addr(18'd0), .g13_rd(1'b0), .g13_rdat(unused_q[6]),
    .g0_caddr(g_caddr), .g0_clear(g_clear[0]), .g1_caddr(g_caddr), .g1_clear(g_clear[1]),
    .g2_caddr(g_caddr), .g2_clear(g_clear[2]), .g3_caddr(g_caddr), .g3_clear(g_clear[3]),
    .cpu_addr(gc_addr), .cpu_wdat(gc_wdat), .cpu_rdat(gc_rdat), .cpu_wr(gc_wr), .cpu_rd(gc_rd),
    .cpu_rmw(gc_rmw), .cpu_rmwmask(gc_mask), .cpu_ack(gc_ack),
    .diag_clr(1'b0), .late(g_late), .cpu_wait_peak(),
    .ready(g_ready), .cal_fail(g_fail), .rd_lat(g_lat[2:0]), .rd_ph(g_lat[3]), .wr_lat(g_lat[6:4]),
    .cram_run(grun), .cram_a(ga), .cram_dq_o(gdo), .cram_dq_oe(goe), .cram_dq_i(gdi),
    .cram_adv_n(gadv), .cram_cre(gcre), .cram_ce0_n(gce), .cram_oe_n(goen), .cram_we_n(gwe),
    .cram_ub_n(gub), .cram_lb_n(glb));

  wire [15:0] t1q [0:3];
  tvram_psram u_t (
    .clk(clk40), .rstn(rstn),
    .cpu_addr(tc_addr), .cpu_wdat(tc_wdat), .cpu_rd(tc_rd), .cpu_wr(tc_wr), .cpu_rmw(tc_rmw),
    .cpu_rmwmask(tc_mask), .cpu_rdat(tc_rdat), .cpu_ack(tc_ack),
    .cpy_src(cpy_src), .cpy_dst(cpy_dst), .cpy_plane(cpy_plane), .cpy_req(cpy_req), .cpy_ack(cpy_ack),
    .t0_addr(t_addr), .t0_rd(t_rd), .t0_rdat0(t_q0), .t0_rdat1(t_q1), .t0_rdat2(t_q2), .t0_rdat3(t_q3),
    .t1_addr(16'd0), .t1_rd(1'b0), .t1_rdat0(t1q[0]), .t1_rdat1(t1q[1]), .t1_rdat2(t1q[2]), .t1_rdat3(t1q[3]),
    .ready(t_ready), .cal_fail(t_fail), .rd_lat(t_lat[2:0]), .rd_ph(t_lat[3]), .wr_lat(t_lat[6:4]),
    .cram_run(trun), .cram_a(ta), .cram_dq_o(tdo), .cram_dq_oe(toe), .cram_dq_i(tdi),
    .cram_adv_n(tadv), .cram_cre(tcre), .cram_ce0_n(tce), .cram_oe_n(toen), .cram_we_n(twe),
    .cram_ub_n(tub), .cram_lb_n(tlb));

  int unsigned vg, vt;
  assign violations = vg + vt;
  /* verilator lint_off UNUSEDSIGNAL */
  wire [15:0] bcr0, bcr1;
  /* verilator lint_on UNUSEDSIGNAL */
  psram_model #(.LAT_R(LAT_R), .LAT_W(LAT_W)) m_g (
    .clk(clk80), .a(ga), .dq_i(gdo), .dq_oe_i(goe), .dq_o(gmo), .dq_oe_o(gmoe),
    .cram_clk(grun && !clk40), .adv_n(gadv), .cre(gcre), .ce0_n(gce), .oe_n(goen), .we_n(gwe),
    .ub_n(gub), .lb_n(glb), .violations(vg), .bcr(bcr0));
  psram_model #(.LAT_R(LAT_R), .LAT_W(LAT_W)) m_t (
    .clk(clk80), .a(ta), .dq_i(tdo), .dq_oe_i(toe), .dq_o(tmo), .dq_oe_o(tmoe),
    .cram_clk(trun && !clk40), .adv_n(tadv), .cre(tcre), .ce0_n(tce), .oe_n(toen), .we_n(twe),
    .ub_n(tub), .lb_n(tlb), .violations(vt), .bcr(bcr1));
endmodule
`default_nettype wire
