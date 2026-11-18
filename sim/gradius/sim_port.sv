// SPDX-License-Identifier: GPL-3.0-or-later
// The simulation's top for this tree: the real core_top, from APF's bridge to the chips' pins, with
// the SDRAM and the two PSRAMs modelled. main.cpp plays APF and the clocks.
module sim_port (
  input  wire        clk_74a,
  input  wire        clk80,
  input  wire        clk40,
  input  wire        clk40_90,

  input  wire [31:0] bridge_addr,
  input  wire        bridge_rd,
  output wire [31:0] bridge_rd_data,
  input  wire        bridge_wr,
  input  wire [31:0] bridge_wr_data,

  input  wire [31:0] cont1_key,
  input  wire [31:0] cont2_key,

  output wire [23:0] video_rgb,
  output wire        video_de,
  output wire        video_hs,
  output wire        video_vs,
  output wire        video_skip,

  // what the bench reads, in the board's words
  output wire [23:0] t_abus,
  output wire [15:0] t_dbus,
  output wire [15:0] t_cpu_o,
  output wire        t_as, t_uds_n, t_lds_n, t_rw_n, t_ack,
  output wire [2:0]  t_fc,
  output wire        t_dma,
  output wire [23:1] t_eab,
  output wire        t_asn, t_rwn,
  output wire [15:0] snd_l, snd_r,
  output wire [15:0] ym_l, ym_r,          // the FM chip's own output and the ADPCM decoder's, ahead of the mix
  output wire [11:0] pcm_raw,
  output wire        aud_new,             // the resampler wrote a new 48 kHz sample on this clock
  output wire [15:0] flags,
  output wire [9:0]  t_pad,               // {keyboard set up, Auto's strobe seen, port A's strobe, rapid shot pressing, port A's six lines}
  output wire [31:0] t_lba,
  output wire [9:0]  t_fd,                // {program's eject (2), swap ready, its 5 s up, mounted (2), ejected (2), disk in (2)}
  output int unsigned sdram_viol, psram0_viol, psram1_viol,
  output wire [15:0] psram0_bcr, psram1_bcr,
  // graphics VRAM's fetch, the bench's own measure, each since the last t_clr (main.cpp: every frame):
  // the most clocks of 40 MHz a raster line (hcomp to hcomp) spent filling or clearing, that line's
  // length, and the CPU's longest wait
  input  wire        t_clr,
  output reg  [15:0] gv_busy_peak,
  output reg  [15:0] gv_busy_line,
  output reg  [7:0]  gv_wait_peak
);
  wire [12:0] dram_a;
  wire [1:0]  dram_ba, dram_dqm;
  wire [15:0] dram_dq;
  wire        dram_clk, dram_cke, dram_ras_n, dram_cas_n, dram_we_n;
  wire [15:0] sd_o;
  wire        sd_oe;
  assign dram_dq = sd_oe ? sd_o : 16'hzzzz;

  sdram_model u_sdram (
    .clk(dram_clk), .cke(dram_cke), .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n),
    .ba(dram_ba), .a(dram_a), .dqm(dram_dqm), .dq_i(dram_dq), .dq_o(sd_o), .dq_oe(sd_oe),
    .violations(sdram_viol), .reads_served(), .writes_served()
  );

  wire [21:16] c0_a, c1_a;
  wire [15:0]  c0_dq, c1_dq, c0_o, c1_o;
  wire         c0_oe, c1_oe, c0_clk, c1_clk;
  wire         c0_adv, c0_cre, c0_ce, c0_oen, c0_we, c0_ub, c0_lb;
  wire         c1_adv, c1_cre, c1_ce, c1_oen, c1_we, c1_ub, c1_lb;
  assign c0_dq = c0_oe ? c0_o : 16'hzzzz;
  assign c1_dq = c1_oe ? c1_o : 16'hzzzz;

  psram_model #(.LAT_R(`PSRAM_LAT_R), .LAT_W(`PSRAM_LAT_W)) u_cram0 (
    .clk(clk80), .a(c0_a), .dq_i(c0_dq), .dq_oe_i(1'b0), .dq_o(c0_o), .dq_oe_o(c0_oe), .cram_clk(c0_clk),
    .adv_n(c0_adv), .cre(c0_cre), .ce0_n(c0_ce), .oe_n(c0_oen), .we_n(c0_we), .ub_n(c0_ub), .lb_n(c0_lb),
    .violations(psram0_viol), .bcr(psram0_bcr)
  );
  psram_model #(.LAT_R(`PSRAM_LAT_R), .LAT_W(`PSRAM_LAT_W)) u_cram1 (
    .clk(clk80), .a(c1_a), .dq_i(c1_dq), .dq_oe_i(1'b0), .dq_o(c1_o), .dq_oe_o(c1_oe), .cram_clk(c1_clk),
    .adv_n(c1_adv), .cre(c1_cre), .ce0_n(c1_ce), .oe_n(c1_oen), .we_n(c1_we), .ub_n(c1_ub), .lb_n(c1_lb),
    .violations(psram1_viol), .bcr(psram1_bcr)
  );

  core_top u_core (
    .clk_74a(clk_74a), .clk_74b(clk_74a),
    .port_ir_rx(1'b1), .cram0_wait(1'b0), .cram1_wait(1'b0),
    .cram0_a(c0_a), .cram0_dq(c0_dq), .cram0_clk(c0_clk), .cram0_adv_n(c0_adv), .cram0_cre(c0_cre),
    .cram0_ce0_n(c0_ce), .cram0_ce1_n(), .cram0_oe_n(c0_oen), .cram0_we_n(c0_we), .cram0_ub_n(c0_ub), .cram0_lb_n(c0_lb),
    .cram1_a(c1_a), .cram1_dq(c1_dq), .cram1_clk(c1_clk), .cram1_adv_n(c1_adv), .cram1_cre(c1_cre),
    .cram1_ce0_n(c1_ce), .cram1_ce1_n(), .cram1_oe_n(c1_oen), .cram1_we_n(c1_we), .cram1_ub_n(c1_ub), .cram1_lb_n(c1_lb),
    .dram_a(dram_a), .dram_ba(dram_ba), .dram_dq(dram_dq), .dram_dqm(dram_dqm), .dram_clk(dram_clk), .dram_cke(dram_cke),
    .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n), .dram_we_n(dram_we_n),
    .vblank(1'b0), .dbg_rx(1'b1), .user2(1'b1),
    .video_rgb(video_rgb), .video_rgb_clock(), .video_rgb_clock_90(), .video_de(video_de), .video_skip(video_skip),
    .video_vs(video_vs), .video_hs(video_hs),
    .audio_mclk(), .audio_adc(1'b0), .audio_dac(), .audio_lrck(),
    .bridge_endian_little(), .bridge_addr(bridge_addr), .bridge_rd(bridge_rd), .bridge_rd_data(bridge_rd_data),
    .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
    .cont1_key(cont1_key), .cont2_key(cont2_key), .cont3_key(32'd0), .cont4_key(32'd0),
    .cont1_joy(32'd0), .cont2_joy(32'd0), .cont3_joy(32'd0), .cont4_joy(32'd0),
    .cont1_trig(16'd0), .cont2_trig(16'd0), .cont3_trig(16'd0), .cont4_trig(16'd0)
  );

  assign t_pad   = {u_core.kbd_ready, u_core.strobed, u_core.str_a, u_core.rapid_ok & u_core.k1[9] & ~u_core.rap1[1], u_core.joy_a};
  assign t_abus  = u_core.u_x68k.chip.abus;
  assign t_dbus  = u_core.u_x68k.chip.dbus;
  assign t_cpu_o = u_core.u_x68k.chip.mpu_od;
  assign t_as    = u_core.u_x68k.chip.b_as;
  assign t_uds_n = u_core.u_x68k.chip.b_udsn;
  assign t_lds_n = u_core.u_x68k.chip.b_ldsn;
  assign t_rw_n  = u_core.u_x68k.chip.b_rwn;
  assign t_ack   = u_core.u_x68k.chip.b_ack;
  assign t_fc    = u_core.u_x68k.chip.mpu_fc;
  assign t_dma   = u_core.u_x68k.chip.dma_bconte;
  assign t_asn   = u_core.u_x68k.chip.i_asn;
  assign t_rwn   = u_core.u_x68k.chip.i_rwn;
  assign t_eab   = u_core.u_x68k.chip.mpu_addr[23:1];
  assign snd_l   = u_core.aud_l;                   // what goes to the I2S: the mix at 48 kHz (pocket_audio_interp)
  assign snd_r   = u_core.aud_r;
  assign ym_l    = u_core.u_x68k.chip.opm_sndr;    // swapped back, as core_top swaps pSndL and pSndR
  assign ym_r    = u_core.u_x68k.chip.opm_sndl;
  assign pcm_raw = u_core.u_x68k.chip.pcm_snd;
  assign aud_new = u_core.u_resample.e3;
  assign flags   = u_core.diag_flags;
  assign t_lba   = u_core.mist_lba;
  assign t_fd    = {u_core.fd_eject_cmd, u_core.fd_swap_ok, u_core.fd_wait_on == u_core.FD_SWAP_ON, u_core.fd_mounted,
                    u_core.fd_ejected, u_core.u_x68k.chip.fdc_indisk};

  wire gv_hcomp = u_core.u_x68k.chip.gvram_psram_i.hcomp;
  wire gv_fill  = u_core.u_x68k.chip.gvram_psram_i.fill_active | u_core.u_x68k.chip.gvram_psram_i.clr_active;
  wire [7:0] gv_wait = u_core.u_x68k.chip.gvram_psram_i.cpu_wait;
  reg  gv_hcomp_q = 1'b0;
  reg  [15:0] gv_busy = 16'd0, gv_len = 16'd0;
  always @(posedge clk40) begin
    gv_hcomp_q <= gv_hcomp;
    if (gv_hcomp && !gv_hcomp_q) begin
      if (gv_busy > gv_busy_peak) begin gv_busy_peak <= gv_busy; gv_busy_line <= gv_len; end
      gv_busy <= {15'd0, gv_fill};
      gv_len  <= 16'd1;
    end else begin
      if (gv_fill && gv_busy != 16'hFFFF) gv_busy <= gv_busy + 16'd1;
      if (gv_len != 16'hFFFF) gv_len <= gv_len + 16'd1;
    end
    if (gv_wait > gv_wait_peak) gv_wait_peak <= gv_wait;
    if (t_clr) begin gv_busy_peak <= 16'd0; gv_busy_line <= 16'd0; gv_wait_peak <= 8'd0; end
  end
endmodule
