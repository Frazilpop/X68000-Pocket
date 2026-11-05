// SPDX-License-Identifier: GPL-3.0-or-later
// The simulation's top for upstream's own tree, the reference: X68K_top as X68000.sv wires it, with
// its clock enables, its clock table by mode and its mount pulses, the SDRAM and the DDR3 modelled.
// The HPS isn't here: main.cpp pours the boot ROM in and answers the disk port.
module sim_upstream (
  input  wire        clk80,
  input  wire        clk40,
  input  wire        clk_scan,
  input  wire        rstn,
  input  wire        plllock,

  input  wire [19:0] ldr_addr,
  input  wire [7:0]  ldr_wdat,
  input  wire        ldr_aen,
  input  wire        ldr_wr,
  output wire        ldr_ack,
  input  wire        ldr_done,

  output wire [31:0] mist_lba,
  output wire [7:0]  mist_rd,
  output wire [7:0]  mist_wr,
  input  wire [7:0]  mist_ack,
  input  wire [8:0]  mist_buffaddr,
  input  wire [7:0]  mist_buffdout,
  output wire [7:0]  mist_buffdin,
  input  wire        mist_buffwr,
  input  wire [1:0]  fd_eject,
  input  wire [1:0]  fd_mounted,
  input  wire [20:0] fd_size,

  input  wire [5:0]  joy_a,
  input  wire [64:0] sysrtc,

  output wire [7:0]  v_r, v_g, v_b,
  output wire        v_ce, v_hs, v_vs, v_hb, v_vb,
  output wire [3:0]  scan_mode_o,
  output reg         scan_ready,

  output wire [23:0] t_abus,
  output wire [15:0] t_dbus,
  output wire [15:0] t_cpu_o,
  output wire        t_as, t_uds_n, t_lds_n, t_rw_n, t_ack,
  output wire [2:0]  t_fc,
  output wire        t_dma,
  output wire [23:1] t_eab,
  output wire        t_asn, t_rwn,
  output wire [15:0] snd_l, snd_r,
  output int unsigned sdram_viol
);
  // clock enables, X68000.sv's
  wire  snd_clockmode;
  reg   sys_ce = 0, mpu_cep = 0, mpu_cen = 0, snd_ce = 0;
  reg   [1:0] opm_ce = 0;
  reg   [4:0] div_opm = 0;
  reg   [1:0] div_sys = 0;
  reg   [3:0] div_snd = 0, div_snd2 = 0;
  always @(posedge clk40) begin
    div_sys  <= div_sys + 2'd1;
    div_snd  <= (div_snd == 4'd4)  ? 4'd0 : div_snd + 4'd1;
    div_snd2 <= (div_snd2 == 4'd9) ? 4'd0 : div_snd2 + 4'd1;
    div_opm  <= (div_opm == 5'd19) ? 5'd0 : div_opm + 5'd1;
    opm_ce[0] <= div_snd2 == 4'd9;
    opm_ce[1] <= div_opm == 5'd19;
    sys_ce    <= &div_sys;
    mpu_cep   <=  div_sys[1] & div_sys[0];
    mpu_cen   <= ~div_sys[1] & div_sys[0];
    snd_ce    <= snd_clockmode ? (div_snd2 == 4'd9) : (div_snd == 4'd4);
  end

  // the video PLL's state, as x68k_video_clock has it: main.cpp sets the clock from scan_mode
  wire [3:0] rt_mode;
  reg  [3:0] scan_mode = 0, mode_q = 0;
  reg  [7:0] quiet = 0;
  always @(posedge clk40) begin
    mode_q <= rt_mode;
    if (mode_q != rt_mode) begin quiet <= 0; scan_ready <= 1'b0; end
    else if (quiet != 8'hFF) quiet <= quiet + 8'd1;
    else begin scan_mode <= mode_q; scan_ready <= 1'b1; end
  end
  assign scan_mode_o = scan_mode;

  wire [12:0] sd_a;
  wire [1:0]  sd_ba;
  wire [15:0] sd_dq, sd_o;
  wire        sd_oe, sd_cke, sd_ras, sd_cas, sd_we, sd_cs, sd_u, sd_l;
  assign sd_dq = sd_oe ? sd_o : 16'hzzzz;
  sdram_model u_sdram (
    .clk(~clk80), .cke(sd_cke), .ras_n(sd_ras), .cas_n(sd_cas), .we_n(sd_we), .ba(sd_ba), .a(sd_a),
    .dqm({sd_u, sd_l}), .dq_i(sd_dq), .dq_o(sd_o), .dq_oe(sd_oe),
    .violations(sdram_viol), .reads_served(), .writes_served()
  );

  // DDR3 as MiSTer's framework gives it: a word a clock once its latency is over, never busy
  wire        dd_clk, dd_rd, dd_we;
  wire [7:0]  dd_burst, dd_be;
  wire [28:0] dd_addr;
  wire [63:0] dd_din;
  reg  [63:0] dd_dout = 0;
  reg         dd_ready = 0;
  reg  [63:0] dd_mem [0:(1 << 18) - 1];
  reg  [28:0] rd_a = 0;
  reg  [7:0]  rd_left = 0;
  reg  [3:0]  rd_wait = 0;
  always @(posedge dd_clk) begin
    dd_ready <= 1'b0;
    if (dd_we) begin
      for (int i = 0; i < 8; i++) if (dd_be[i]) dd_mem[dd_addr[17:0]][i*8 +: 8] <= dd_din[i*8 +: 8];
    end
    if (dd_rd) begin rd_a <= dd_addr; rd_left <= dd_burst; rd_wait <= 4'd6; end
    else if (rd_left != 0) begin
      if (rd_wait != 0) rd_wait <= rd_wait - 4'd1;
      else begin
        dd_dout  <= dd_mem[rd_a[17:0]];
        dd_ready <= 1'b1;
        rd_a     <= rd_a + 1'b1;
        rd_left  <= rd_left - 8'd1;
      end
    end
  end

  X68K_top u_x68k (
    .ramclk(clk80), .sysclk(clk40), .vidclk(clk80), .scanclk(clk_scan), .scan_ready(scan_ready), .scan_mode(scan_mode),
    .scan_reset_out(), .fdcclk(clk40), .sndclk(clk40),
    .sys_ce(sys_ce), .mpu_cep(mpu_cep), .mpu_cen(mpu_cen), .snd_ce(snd_ce), .opm_ce(opm_ce), .cm_out(snd_clockmode),
    .plllock(plllock), .sysrtc(sysrtc),
    .pMemCke(sd_cke), .pMemCs_n(sd_cs), .pMemRas_n(sd_ras), .pMemCas_n(sd_cas), .pMemWe_n(sd_we),
    .pMemUdq(sd_u), .pMemLdq(sd_l), .pMemBa1(sd_ba[1]), .pMemBa0(sd_ba[0]), .pMemAdr(sd_a), .pMemDat(sd_dq),
    .DDRAM_CLK(dd_clk), .DDRAM_BURSTCNT(dd_burst), .DDRAM_ADDR(dd_addr), .DDRAM_DIN(dd_din), .DDRAM_BE(dd_be),
    .DDRAM_RD(dd_rd), .DDRAM_WE(dd_we), .DDRAM_DOUT(dd_dout), .DDRAM_DOUT_READY(dd_ready), .DDRAM_BUSY(1'b0),
    .ldr_addr(ldr_addr), .ldr_wdat(ldr_wdat), .ldr_aen(ldr_aen), .ldr_wr(ldr_wr), .ldr_ack(ldr_ack), .ldr_done(ldr_done),
    .vid_hz(1'b0),
    .pPs2Clkin(1'b1), .pPs2Clkout(), .pPs2Datin(1'b1), .pPs2Datout(),
    .pPmsClkin(1'b1), .pPmsClkout(), .pPmsDatin(1'b1), .pPmsDatout(),
    .disk_mode(1'b1),
    .mist_mounted({6'd0, fd_mounted}), .mist_readonly(8'd0), .mist_imgsize({43'd0, fd_size}),
    .mist_lba(mist_lba), .mist_rd(mist_rd), .mist_wr(mist_wr), .mist_ack(mist_ack),
    .mist_buffaddr(mist_buffaddr), .mist_buffdout(mist_buffdout), .mist_buffdin(mist_buffdin), .mist_buffwr(mist_buffwr),
    .pStrA(), .pJoySelA(), .pJoyA(joy_a), .pStrB(), .pJoySelB(), .pJoyB(6'h3F),
    .pFDSYNC(2'b00), .pFDEJECT(fd_eject), .pFDMOTOR(), .pFDACTIVE(), .pFDEJECTED(),
    .pLed(), .pDip(4'b0000), .pPsw(2'b11), .pfdwait(2'b00), .pSramld(1'b0), .pSramst(1'b0), .pkbdtype(3'd0),
    .pMidi_in(1'b1), .pMidi_out(),
    .pVideoR(v_r), .pVideoG(v_g), .pVideoB(v_b), .pVideoHS(v_hs), .pVideoVS(v_vs), .pVideoHB(v_hb), .pVideoVB(v_vb),
    .pVideoEN(), .pVideoClk(v_ce), .pVideoF1(), .pVideo31k(), .pPixCe(1'b0), .pPixExt(1'b0), .pVideoMode(rt_mode), .pVideoDyn(),
    .pSndL(snd_r), .pSndR(snd_l), .pSndYML(), .pSndYMR(), .pSndPCML(), .pSndPCMR(),
    .rstn(rstn), .vid_mode(2'b01), .dHMode(2'b00), .dVMode(1'b0), .opm_sel(1'b0), .pMidi_en(1'b0), .mix_fix(1'b1),
    .sxsi_inject(1'b0), .vis_mem(4'd0)
  );

  assign t_abus  = u_x68k.chip.abus;
  assign t_dbus  = u_x68k.chip.dbus;
  assign t_cpu_o = u_x68k.chip.mpu_od;
  assign t_as    = u_x68k.chip.b_as;
  assign t_uds_n = u_x68k.chip.b_udsn;
  assign t_lds_n = u_x68k.chip.b_ldsn;
  assign t_rw_n  = u_x68k.chip.b_rwn;
  assign t_ack   = u_x68k.chip.b_ack;
  assign t_fc    = u_x68k.chip.mpu_fc;
  assign t_dma   = u_x68k.chip.dma_bconte;
  assign t_asn   = u_x68k.chip.i_asn;
  assign t_rwn   = u_x68k.chip.i_rwn;
  assign t_eab   = u_x68k.chip.mpu_addr[23:1];
endmodule

// Upstream's tvram_ddr names this VHDL block RAM from Verilog; the same, for Verilator.
module CACHEMEMWN #(parameter awidth = 6, parameter ramtype = "") (
  input  wire [15:0] data,
  input  wire [awidth-1:0] rdaddress,
  input  wire rdclock,
  input  wire [awidth-1:0] wraddress,
  input  wire wrclock,
  input  wire wren,
  output reg  [15:0] q
);
  reg [15:0] m [0:(1 << awidth) - 1];
  always @(posedge wrclock) if (wren) m[wraddress] <= data;
  always @(posedge rdclock) q <= m[rdaddress];
endmodule
