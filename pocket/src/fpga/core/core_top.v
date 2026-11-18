// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket: the core top level
//
// Instantiated by Analogue's apf_top. Everything Pocket-specific is here and in the pocket_* modules
// beside it; X68K_top, the machine, is upstream's tree cut by generics, with its video memories on
// the PSRAMs (rtl/pocket_mem).
//
// CLOCKS (pocket_plls.v has the derivation)
//
//   clk_74a        74.25 MHz    APF bridge, pad bus, I2S, the save slot; the PLL's reference
//   clk80          80.025 MHz   SDRAM and its cache, sprite engine, scan-out
//   clk40          40.0125 MHz  the rest of the machine, the renderer, the VRAMs, APF's video bus
//   clk_sdram_ps   80.025 MHz   180 degrees, forwarded to dram_clk
//
// clk80 and clk40 rise together. Upstream renders a line a dot a clock at 80 MHz and that has no
// business closing on this chip, so the renderer runs at 40: 1024 dots take 25.6 us, inside the
// shortest line. The sprite engine stays at 80, as a line's two BG layers and 32 sprites need 1,632
// clocks of it. The only way to the rest of the shell is through synchronisers or dual-clock RAM.
//
// BRIDGE MAP
//
//   0x20000000-   save file, the machine's 16 KB of SRAM     pocket_sram_slot
//   0x40000000-   the 4 KB window disks and boot ROM use     pocket_disk
//   0xF1000000-   Core Settings (interact.json)              below
//   0xF8000000-   APF command bridge                         core_bridge_cmd
//
// DATA SLOTS (dist/Cores/frazilpop.X68000/data.json), in table order:
//
//   [0] id 0       the instance JSON
//   [1] id 1       x68000_boot.rom, read by pocket_disk
//   [2] id 2       <set>.sav, nonvolatile, 16 KB
//   [3..9] id 10-  the set's disks, read and written on demand by pocket_disk

`default_nettype none

module core_top (

//
// physical connections
//

///////////////////////////////////////////////////
// clock inputs 74.25mhz. not phase aligned, so treat these domains as asynchronous

input   wire            clk_74a, // mainclk1
input   wire            clk_74b, // mainclk1

///////////////////////////////////////////////////
// cartridge interface
// switches between 3.3v and 5v mechanically
// output enable for multibit translators controlled by pic32

// GBA AD[15:8]
inout   wire    [7:0]   cart_tran_bank2,
output  wire            cart_tran_bank2_dir,

// GBA AD[7:0]
inout   wire    [7:0]   cart_tran_bank3,
output  wire            cart_tran_bank3_dir,

// GBA A[23:16]
inout   wire    [7:0]   cart_tran_bank1,
output  wire            cart_tran_bank1_dir,

// GBA [7] PHI#
// GBA [6] WR#
// GBA [5] RD#
// GBA [4] CS1#/CS#
//     [3:0] unwired
inout   wire    [7:4]   cart_tran_bank0,
output  wire            cart_tran_bank0_dir,

// GBA CS2#/RES#
inout   wire            cart_tran_pin30,
output  wire            cart_tran_pin30_dir,
// when GBC cart is inserted, this signal when low or weak will pull GBC /RES low with a special circuit
// the goal is that when unconfigured, the FPGA weak pullups won't interfere.
// thus, if GBC cart is inserted, FPGA must drive this high in order to let the level translators
// and general IO drive this pin.
output  wire            cart_pin30_pwroff_reset,

// GBA IRQ/DRQ
inout   wire            cart_tran_pin31,
output  wire            cart_tran_pin31_dir,

// infrared
input   wire            port_ir_rx,
output  wire            port_ir_tx,
output  wire            port_ir_rx_disable,

// GBA link port
inout   wire            port_tran_si,
output  wire            port_tran_si_dir,
inout   wire            port_tran_so,
output  wire            port_tran_so_dir,
inout   wire            port_tran_sck,
output  wire            port_tran_sck_dir,
inout   wire            port_tran_sd,
output  wire            port_tran_sd_dir,

///////////////////////////////////////////////////
// cellular psram 0 and 1, two chips (64mbit x2 dual die per chip)

output  wire    [21:16] cram0_a,
inout   wire    [15:0]  cram0_dq,
input   wire            cram0_wait,
output  wire            cram0_clk,
output  wire            cram0_adv_n,
output  wire            cram0_cre,
output  wire            cram0_ce0_n,
output  wire            cram0_ce1_n,
output  wire            cram0_oe_n,
output  wire            cram0_we_n,
output  wire            cram0_ub_n,
output  wire            cram0_lb_n,

output  wire    [21:16] cram1_a,
inout   wire    [15:0]  cram1_dq,
input   wire            cram1_wait,
output  wire            cram1_clk,
output  wire            cram1_adv_n,
output  wire            cram1_cre,
output  wire            cram1_ce0_n,
output  wire            cram1_ce1_n,
output  wire            cram1_oe_n,
output  wire            cram1_we_n,
output  wire            cram1_ub_n,
output  wire            cram1_lb_n,

///////////////////////////////////////////////////
// sdram, 512mbit 16bit

output  wire    [12:0]  dram_a,
output  wire    [1:0]   dram_ba,
inout   wire    [15:0]  dram_dq,
output  wire    [1:0]   dram_dqm,
output  wire            dram_clk,
output  wire            dram_cke,
output  wire            dram_ras_n,
output  wire            dram_cas_n,
output  wire            dram_we_n,

///////////////////////////////////////////////////
// sram, 1mbit 16bit

output  wire    [16:0]  sram_a,
inout   wire    [15:0]  sram_dq,
output  wire            sram_oe_n,
output  wire            sram_we_n,
output  wire            sram_ub_n,
output  wire            sram_lb_n,

///////////////////////////////////////////////////
// vblank driven by dock for sync in a certain mode

input   wire            vblank,

///////////////////////////////////////////////////
// i/o to 6515D breakout usb uart

output  wire            dbg_tx,
input   wire            dbg_rx,

///////////////////////////////////////////////////
// i/o pads near jtag connector user can solder to

output  wire            user1,
input   wire            user2,

///////////////////////////////////////////////////
// RFU internal i2c bus

inout   wire            aux_sda,
output  wire            aux_scl,

///////////////////////////////////////////////////
// RFU, do not use
output  wire            vpll_feed,


//
// logical connections
//

///////////////////////////////////////////////////
// video, audio output to scaler
output  wire    [23:0]  video_rgb,
output  wire            video_rgb_clock,
output  wire            video_rgb_clock_90,
output  wire            video_de,
output  wire            video_skip,
output  wire            video_vs,
output  wire            video_hs,

output  wire            audio_mclk,
input   wire            audio_adc,
output  wire            audio_dac,
output  wire            audio_lrck,

///////////////////////////////////////////////////
// bridge bus connection
// synchronous to clk_74a
output  wire            bridge_endian_little,
input   wire    [31:0]  bridge_addr,
input   wire            bridge_rd,
output  reg     [31:0]  bridge_rd_data,
input   wire            bridge_wr,
input   wire    [31:0]  bridge_wr_data,

///////////////////////////////////////////////////
// controller data
//
// key bitmap:
//   [0]    dpad_up
//   [1]    dpad_down
//   [2]    dpad_left
//   [3]    dpad_right
//   [4]    face_a
//   [5]    face_b
//   [6]    face_x
//   [7]    face_y
//   [8]    trig_l1
//   [9]    trig_r1
//   [10]   trig_l2
//   [11]   trig_r2
//   [12]   trig_l3
//   [13]   trig_r3
//   [14]   face_select
//   [15]   face_start
//   [31:28] type
input   wire    [31:0]  cont1_key,
input   wire    [31:0]  cont2_key,
input   wire    [31:0]  cont3_key,
input   wire    [31:0]  cont4_key,
input   wire    [31:0]  cont1_joy,
input   wire    [31:0]  cont2_joy,
input   wire    [31:0]  cont3_joy,
input   wire    [31:0]  cont4_joy,
input   wire    [15:0]  cont1_trig,
input   wire    [15:0]  cont2_trig,
input   wire    [15:0]  cont3_trig,
input   wire    [15:0]  cont4_trig

);

// ============================================================ unused pins
// As Analogue's template leaves them.

assign port_ir_tx = 0;
assign port_ir_rx_disable = 1;
assign bridge_endian_little = 0;

assign cart_tran_bank3 = 8'hzz;
assign cart_tran_bank3_dir = 1'b0;
assign cart_tran_bank2 = 8'hzz;
assign cart_tran_bank2_dir = 1'b0;
assign cart_tran_bank1 = 8'hzz;
assign cart_tran_bank1_dir = 1'b0;
assign cart_tran_bank0 = 4'hf;
assign cart_tran_bank0_dir = 1'b1;
assign cart_tran_pin30 = 1'b0;
assign cart_tran_pin30_dir = 1'bz;
assign cart_pin30_pwroff_reset = 1'b0;
assign cart_tran_pin31 = 1'bz;
assign cart_tran_pin31_dir = 1'b0;

assign port_tran_so = 1'bz;
assign port_tran_so_dir = 1'b0;
assign port_tran_si = 1'bz;
assign port_tran_si_dir = 1'b0;
assign port_tran_sck = 1'bz;
assign port_tran_sck_dir = 1'b0;
assign port_tran_sd = 1'bz;
assign port_tran_sd_dir = 1'b0;

assign dbg_tx = 1'bZ;
assign user1 = 1'bZ;
assign aux_scl = 1'bZ;
assign vpll_feed = 1'bZ;

assign sram_a    = 17'd0;
assign sram_dq   = 16'hzzzz;
assign sram_oe_n = 1'b1;
assign sram_we_n = 1'b1;
assign sram_ub_n = 1'b1;
assign sram_lb_n = 1'b1;

assign cram0_ce1_n = 1'b1;
assign cram1_ce1_n = 1'b1;

// ================================================================= clocks
wire clk80, clk40, clk_sdram_ps, clk40_90;
wire pll_locked;

pocket_pll_core u_pll_core (
    .refclk       ( clk_74a ),
    .clk80        ( clk80 ),
    .clk40        ( clk40 ),
    .clk_sdram_ps ( clk_sdram_ps ),
    .clk40_90     ( clk40_90 ),
    .locked       ( pll_locked )
);

// ================================================================= resets
wire pll_locked_74, pll_locked_40;
synch_3 s_lock74 (.i(pll_locked), .o(pll_locked_74), .clk(clk_74a), .rise(), .fall());
synch_3 s_lock40 (.i(pll_locked), .o(pll_locked_40), .clk(clk40),   .rise(), .fall());

wire reset_n;                               // clk_74a, from core_bridge_cmd
wire reset_n_40;
synch_3 s_rstn40 (.i(reset_n), .o(reset_n_40), .clk(clk40), .rise(), .fall());

// ================================================================== bridge
//
// Reads are muxed and registered: APF buffers bridge reads and allows the data until the next read
// strobe, which is many cycles of clk_74a.
//
// Core Settings, each zero by default so a first boot needs nothing from APF, but drive 1:
//
//   0xF100000C        write: reset the machine (1 ms)
//   0xF1000014 [0]    diagnostic overlay
//   0xF1000020 [2:0]  Drive 0: 0-6 the set's files 1-7, 7 none; not kept between launches, so every
//                     game starts from its first file
//   0xF1000024 [2:0]  Drive 1: the same, file 2 unless told
//   0xF1000028 [2:0]  Pad type: 0 Auto, 1 two buttons, 2 Mega Drive 3, 3 Capcom 6, 4 Magical 6
//   0xF100002C [1:0]  Keys on X, Y: 0 SPACE and RETURN, 1 the 1 and 2 keys, 2 Y and N

wire [31:0] cmd_bridge_rd_data;
wire [31:0] nv_bridge_rd;
wire [31:0] win_bridge_rd;

wire        osnotify_inmenu;                //   APF's menu open (core_bridge_cmd, clk_74a)
reg         diag_74  = 1'b0;
reg  [2:0]  drv0_74  = 3'd0;
reg  [2:0]  drv1_74  = 3'd1;
reg  [2:0]  pad_74   = 3'd0;
reg  [1:0]  keys_74  = 2'd0;
reg  [16:0] hrst_cnt = 17'd0;               //   1 ms at 74.25 MHz = 74,250
wire        hrst_74  = (hrst_cnt != 17'd0);

always @(posedge clk_74a) begin
    if (hrst_cnt != 17'd0) hrst_cnt <= hrst_cnt - 17'd1;
    if (bridge_wr) begin
        case (bridge_addr)
        32'hF100000C: hrst_cnt <= 17'd74250;
        32'hF1000014: diag_74  <= bridge_wr_data[0];
        32'hF1000020: drv0_74  <= bridge_wr_data[2:0];
        32'hF1000024: drv1_74  <= bridge_wr_data[2:0];
        32'hF1000028: pad_74   <= bridge_wr_data[2:0];
        32'hF100002C: keys_74  <= bridge_wr_data[1:0];
        default: ;
        endcase
    end
end

always @(posedge clk_74a) begin
    casez (bridge_addr)
    32'h2???????: bridge_rd_data <= nv_bridge_rd;
    32'h4???????: bridge_rd_data <= win_bridge_rd;
    32'hF1000014: bridge_rd_data <= {31'd0, diag_74};
    32'hF1000020: bridge_rd_data <= {29'd0, drv0_74};
    32'hF1000024: bridge_rd_data <= {29'd0, drv1_74};
    32'hF1000028: bridge_rd_data <= {29'd0, pad_74};
    32'hF100002C: bridge_rd_data <= {30'd0, keys_74};
    32'hF8??????: bridge_rd_data <= cmd_bridge_rd_data;
    default:      bridge_rd_data <= 32'd0;
    endcase
end

// ---- the APF command bridge, as the template wires it
wire            status_boot_done  = pll_locked_74;
wire            status_setup_done = pll_locked_74;
wire            status_running    = reset_n;

wire            dataslot_requestread;
wire    [15:0]  dataslot_requestread_id;
wire            dataslot_requestread_ack = 1;
wire            dataslot_requestread_ok  = 1;

wire            dataslot_requestwrite;
wire    [15:0]  dataslot_requestwrite_id;
wire    [31:0]  dataslot_requestwrite_size;
wire            dataslot_requestwrite_ack = 1;
wire            dataslot_requestwrite_ok  = 1;

wire            dataslot_update;
wire    [15:0]  dataslot_update_id;
wire    [31:0]  dataslot_update_size;

wire            dataslot_allcomplete;

wire     [31:0] rtc_epoch_seconds;
wire     [31:0] rtc_date_bcd;
wire     [31:0] rtc_time_bcd;
wire            rtc_valid;

wire            savestate_supported   = 1'b0;
wire    [31:0]  savestate_addr        = 32'd0;
wire    [31:0]  savestate_size        = 32'd0;
wire    [31:0]  savestate_maxloadsize = 32'd0;

wire            savestate_start;
wire            savestate_start_ack   = 1'b0;
wire            savestate_start_busy  = 1'b0;
wire            savestate_start_ok    = 1'b0;
wire            savestate_start_err   = 1'b0;

wire            savestate_load;
wire            savestate_load_ack    = 1'b0;
wire            savestate_load_busy   = 1'b0;
wire            savestate_load_ok     = 1'b0;
wire            savestate_load_err    = 1'b0;

wire            t_read, t_write;            //   clk40, held; pocket_disk
wire    [15:0]  t_id;
wire    [31:0]  t_offset, t_length;
wire            target_dataslot_read, target_dataslot_write;
synch_3 s_tread  (.i(t_read),  .o(target_dataslot_read),  .clk(clk_74a), .rise(), .fall());
synch_3 s_twrite (.i(t_write), .o(target_dataslot_write), .clk(clk_74a), .rise(), .fall());

wire            target_dataslot_ack;
wire            target_dataslot_done;
wire    [2:0]   target_dataslot_err;

// THE TABLE. APF keeps each slot's size in it, disks and all, deferload or not. Eight things share
// its one port, in turn: the sizes of the set's seven files are read out, which says whether a file
// is there at all; and the save slot's own size is written, as when no .sav exists yet that entry
// is zero and APF would write nothing back at shutdown. mf_datatable registers its output as well
// as its address, so a word is there three clocks after the address is set.
reg     [9:0]   datatable_addr = 10'd5;
reg             datatable_wren = 1'b0;
reg     [31:0]  datatable_data = 32'd16384;
wire    [31:0]  datatable_q;
reg     [4:0]   dt_step = 5'd0;
(* ramstyle = "logic" *) reg [20:0] dsize_74 [0:6];   // registers: read from clk40 as they stand
integer         dsi;
initial for (dsi = 0; dsi < 7; dsi = dsi + 1) dsize_74[dsi] = 21'd0;

always @(posedge clk_74a) begin
    dt_step <= dt_step + 5'd1;
    datatable_wren <= 1'b0;
    if (dt_step[1:0] == 2'd0) begin
        if (dt_step[4:2] != 3'd7) datatable_addr <= {5'd0, 4'd3 + {1'b0, dt_step[4:2]}, 1'b1};
        else begin
            datatable_addr <= 10'd5;
            datatable_wren <= 1'b1;
        end
    end
    if (dt_step[1:0] == 2'd3 && dt_step[4:2] != 3'd7) dsize_74[dt_step[4:2]] <= datatable_q[20:0];
end

wire    [3:0]   target_wd_state;            // core_bridge_cmd's watchdog on target commands, for the overlay
wire    [7:0]   target_wd_count;
core_bridge_cmd icb (

    .clk                ( clk_74a ),
    .reset_n            ( reset_n ),

    .bridge_endian_little   ( bridge_endian_little ),
    .bridge_addr            ( bridge_addr ),
    .bridge_rd              ( bridge_rd ),
    .bridge_rd_data         ( cmd_bridge_rd_data ),
    .bridge_wr              ( bridge_wr ),
    .bridge_wr_data         ( bridge_wr_data ),

    .status_boot_done       ( status_boot_done ),
    .status_setup_done      ( status_setup_done ),
    .status_running         ( status_running ),

    .dataslot_requestread       ( dataslot_requestread ),
    .dataslot_requestread_id    ( dataslot_requestread_id ),
    .dataslot_requestread_ack   ( dataslot_requestread_ack ),
    .dataslot_requestread_ok    ( dataslot_requestread_ok ),

    .dataslot_requestwrite      ( dataslot_requestwrite ),
    .dataslot_requestwrite_id   ( dataslot_requestwrite_id ),
    .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
    .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack ),
    .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok ),

    .dataslot_update            ( dataslot_update ),
    .dataslot_update_id         ( dataslot_update_id ),
    .dataslot_update_size       ( dataslot_update_size ),

    .dataslot_allcomplete   ( dataslot_allcomplete ),

    .rtc_epoch_seconds      ( rtc_epoch_seconds ),
    .rtc_date_bcd           ( rtc_date_bcd ),
    .rtc_time_bcd           ( rtc_time_bcd ),
    .rtc_valid              ( rtc_valid ),

    .savestate_supported    ( savestate_supported ),
    .savestate_addr         ( savestate_addr ),
    .savestate_size         ( savestate_size ),
    .savestate_maxloadsize  ( savestate_maxloadsize ),

    .savestate_start        ( savestate_start ),
    .savestate_start_ack    ( savestate_start_ack ),
    .savestate_start_busy   ( savestate_start_busy ),
    .savestate_start_ok     ( savestate_start_ok ),
    .savestate_start_err    ( savestate_start_err ),

    .savestate_load         ( savestate_load ),
    .savestate_load_ack     ( savestate_load_ack ),
    .savestate_load_busy    ( savestate_load_busy ),
    .savestate_load_ok      ( savestate_load_ok ),
    .savestate_load_err     ( savestate_load_err ),

    .osnotify_inmenu        ( osnotify_inmenu ),

    .target_dataslot_read       ( target_dataslot_read ),
    .target_dataslot_write      ( target_dataslot_write ),
    .target_dataslot_getfile    ( 1'b0 ),
    .target_dataslot_openfile   ( 1'b0 ),

    .target_dataslot_ack        ( target_dataslot_ack ),
    .target_dataslot_done       ( target_dataslot_done ),
    .target_dataslot_err        ( target_dataslot_err ),

    .target_dataslot_id         ( t_id ),
    .target_dataslot_slotoffset ( t_offset ),
    .target_dataslot_bridgeaddr ( 32'h40000000 ),
    .target_dataslot_length     ( t_length ),

    .target_buffer_param_struct ( 32'd0 ),
    .target_buffer_resp_struct  ( 32'd0 ),

    .datatable_addr         ( datatable_addr ),
    .datatable_wren         ( datatable_wren ),
    .datatable_data         ( datatable_data ),
    .datatable_q            ( datatable_q ),

    .target_wd_state        ( target_wd_state ),
    .target_wd_count        ( target_wd_count )

);

// ======================================================== settings -> clk40
wire        host_rst, diag_opt, inmenu;
wire [2:0]  pad_type;
wire [1:0]  key_set;
wire [2:0]  drv0, drv1;
pocket_sync_bus #(.W(14), .INIT(14'd1 << 3)) s_cfg40 (
    .clk (clk40),
    .d   ({hrst_74, diag_74, osnotify_inmenu, keys_74, pad_74, drv1_74, drv0_74}),
    .q   ({host_rst, diag_opt, inmenu, key_set, pad_type, drv1, drv0})
);

// The files' sizes settle long before a mount looks at them, and are only looked at for being zero
// and by the FDC once it's mounted: taken as they stand, the .sdc cuts them. A drive's is that of
// the file it holds now (drv0_q, below), not the one the menu shows until it's been changed over.
wire [2:0]  drv0_q, drv1_q;
wire [20:0] size0 = (drv0_q == 3'd7) ? 21'd0 : dsize_74[drv0_q];
wire [20:0] size1 = (drv1_q == 3'd7) ? 21'd0 : dsize_74[drv1_q];

wire allcomplete_40, t_done_40;
wire [2:0] t_err_40;
synch_3 s_allc (.i(dataslot_allcomplete), .o(allcomplete_40), .clk(clk40), .rise(), .fall());
synch_3 s_tdone (.i(target_dataslot_done), .o(t_done_40), .clk(clk40), .rise(), .fall());
synch_3 #(.WIDTH(3)) s_terr (.i(target_dataslot_err), .o(t_err_40), .clk(clk40), .rise(), .fall());

reg diag_opt_q = 1'b0;
always @(posedge clk40) diag_opt_q <= diag_opt;
wire diag_clr = diag_opt_q & ~diag_opt;     // overlay turned off: the peaks and sticky flags clear

// ================================================================== clock enables, as upstream
wire  snd_clockmode;
reg   sys_ce_r = 1'b0, mpu_cep_r = 1'b0, mpu_cen_r = 1'b0, snd_ce_r = 1'b0;
reg   [1:0] opm_ce_r = 2'd0;
reg   [4:0] div_opm = 5'd0;
reg   [1:0] div_sys = 2'd0;
reg   [3:0] div_snd = 4'd0;
reg   [3:0] div_snd2 = 4'd0;

// Pause: the machine stands still while the Pocket's own menu is open, once a disk command has
// finished. The picture goes black in the scan-out, whose timing runs on.
wire  disk_busy;
wire  pause = inmenu & ~disk_busy;

always @(posedge clk40) begin
    div_sys  <= div_sys + 2'd1;
    div_snd  <= (div_snd == 4'd4)  ? 4'd0 : div_snd + 4'd1;
    div_snd2 <= (div_snd2 == 4'd9) ? 4'd0 : div_snd2 + 4'd1;
    div_opm  <= (div_opm == 5'd19) ? 5'd0 : div_opm + 5'd1;

    opm_ce_r[0] <= (div_snd2 == 4'd9) & ~pause;
    opm_ce_r[1] <= (div_opm == 5'd19) & ~pause;
    sys_ce_r    <= (&div_sys) & ~pause;
    mpu_cep_r   <= ( div_sys[1] & div_sys[0]) & ~pause;
    mpu_cen_r   <= (~div_sys[1] & div_sys[0]) & ~pause;
    snd_ce_r    <= (snd_clockmode ? (div_snd2 == 4'd9) : (div_snd == 4'd4)) & ~pause;
end

// ================================================================== inputs
//
// The Pocket's keys in the order upstream's pad table reads them: right, left, down, up, A, B, Run,
// Select, X, Y, L, R. Start is Run and Select is Select: as two buttons, they read as both of a pair
// of directions, as the machine's own pads wire them. Start is also F1 on the keyboard (player 2's,
// F2), below.
//
// Pad type Auto, the default, is the two-button pad until the program drives a port's strobe high
// (PPI port C bit 4 or 5), which none of the two-button games, the IPL or Human68k does, and the
// Mega Drive 3-button pad from then until the machine is reset. sf2ce and ssf2 raise it to look for
// that pad and find it by themselves (MAME, with these tables: the same fights as Mega Drive 3 chosen);
// the Capcom 6-button pad they take only once it's set in their own menus, so it stays a choice. The
// others are upstream's kinds, as chosen. (pocket_pad: 0 two, 1 Mega Drive 3, 2 Capcom 6, 3 Magical 6.)
//
// R is rapid shot with the two-button and Mega Drive 3 pads, which don't use it: R held is A pressed
// for two frames and released for two, counted as vertical blank ends, starting pressed on the frame
// R goes down; A and R together are A held. Two frames, not one: gradius reads its pad every other
// frame, and A flipped every frame would look to it held or never pressed, while chorensa, which
// reads all through a frame, fires as fast either way (MAME, shots on screen). The 6-button pads have
// R as a button of their own, so there it is that.
wire [15:0] k1, k2;
synch_3 #(.WIDTH(16)) s_k1 (.i(cont1_key[15:0]), .o(k1), .clk(clk40), .rise(), .fall());
synch_3 #(.WIDTH(16)) s_k2 (.i(cont2_key[15:0]), .o(k2), .clk(clk40), .rise(), .fall());

wire  machine_rst = ~pll_locked_40 | ~reset_n_40 | host_rst;
wire  str_a, str_b;
reg   strobed = 1'b0;
always @(posedge clk40) begin
    if (machine_rst) strobed <= 1'b0;
    else if (str_a | str_b) strobed <= 1'b1;
end
wire [1:0] pad_kind = (pad_type == 3'd0) ? (strobed ? 2'd1 : 2'd0) :
                      (pad_type >= 3'd4) ? 2'd3 : pad_type[1:0] - 2'd1;
wire       rapid_ok = (pad_kind == 2'd0 || pad_kind == 2'd1);

wire       v_vb;                           // the machine's vertical blank (video, below)
reg  [1:0] rap1 = 2'd0, rap2 = 2'd0;       // frames since R went down, mod 4: pressed on 0 and 1
reg        rvb_q = 1'b0;
always @(posedge clk40) begin
    rvb_q <= v_vb;
    if (!v_vb && rvb_q && !pause) begin rap1 <= rap1 + 2'd1; rap2 <= rap2 + 2'd1; end
    if (!k1[9]) rap1 <= 2'd0;
    if (!k2[9]) rap2 <= 2'd0;
end
wire       a1 = k1[4] | (rapid_ok & k1[9] & ~rap1[1]);
wire       a2 = k2[4] | (rapid_ok & k2[9] & ~rap2[1]);

wire [11:0] j1 = {k1[9], k1[8], k1[7], k1[6], k1[14], k1[15], k1[5], a1, k1[0], k1[1], k1[2], k1[3]};
wire [11:0] j2 = {k2[9], k2[8], k2[7], k2[6], k2[14], k2[15], k2[5], a2, k2[0], k2[1], k2[2], k2[3]};

wire [5:0] joy_a, joy_b;
pocket_pad u_pad_a (.clk(clk40), .kind(pad_kind), .j(j1), .str(str_a), .joy(joy_a));
pocket_pad u_pad_b (.clk(clk40), .kind(pad_kind), .j(j2), .str(str_b), .joy(joy_b));

// The keyboard: F1 is player 1's Start, F2 player 2's, for the games that start from the keyboard
// (parodius). L is ESC (a pause in many games), and X and Y a pair of keys chosen in Core Settings
// (Keys on X, Y), for the games that wait for one to start or go on: SPACE and RETURN, 1 and 2 (a
// numbered menu, bf92; player 1 or 2, bbknuckl), or Y and N (a yes-or-no question, wrecking; New
// game, lockon). Over the 225 sets of the card's Games folder in MAME, those are the keys that moved
// a game the pad couldn't. Only where the pad type leaves the button free: the two-button pad (Auto
// before a strobe) has no use for X, Y and L, the Mega Drive 3-button pad has Y as its C, and the
// 6-button pads use all three. Either pad's button is the keyboard's.
wire       keys_xl = (pad_kind == 2'd0 || pad_kind == 2'd1);
wire       keys_y  = (pad_kind == 2'd0);
wire       kx = keys_xl & (k1[6] | k2[6]);
wire       ky = keys_y  & (k1[7] | k2[7]);
wire       kl = keys_xl & (k1[8] | k2[8]);
wire       set_12 = (key_set == 2'd1), set_yn = (key_set == 2'd2), set_sr = ~set_12 & ~set_yn;
wire kbd_clk, kbd_dat, kbd_hclk, kbd_hdat, kbd_ready;
pocket_kbd u_kbd (
    .clk      (clk40),
    .ce       (sys_ce_r),
    .rst      (machine_rst),
    .keys     ({ky & set_yn, kx & set_yn, ky & set_12, kx & set_12, kl, ky & set_sr, kx & set_sr, k2[15], k1[15]}),
    .host_clk (kbd_hclk),
    .host_dat (kbd_hdat),
    .dev_clk  (kbd_clk),
    .dev_dat  (kbd_dat),
    .ready    (kbd_ready)
);

// ================================================================== RTC
//
// APF's date and time, in upstream's order: seconds, minutes, hours, day, month, year, weekday, and a
// top bit that flips on a new value.
reg  [64:0] sysrtc_74 = 65'd0;
reg         rtc_valid_q = 1'b0;
always @(posedge clk_74a) begin
    rtc_valid_q <= rtc_valid;
    if (rtc_valid && !rtc_valid_q)
        sysrtc_74 <= {~sysrtc_74[64], 8'd0, 5'd0, rtc_date_bcd[26:24], rtc_date_bcd[23:0], rtc_time_bcd[23:0]};
end
// The date as it stands (the .sdc cuts it), with its top bit taken across so it flips after the rest.
wire        rtc_flip;
synch_3 s_rtcflip (.i(sysrtc_74[64]), .o(rtc_flip), .clk(clk40), .rise(), .fall());
wire [64:0] sysrtc = {rtc_flip, sysrtc_74[63:0]};

// ================================================================== mounting
//
// Upstream's pulses: a disk going in is taken out for 0.4 s, so a program looking for a change sees
// one, then shown as mounted for 1.6 ms. A drive's list changes this, as does the machine starting,
// and a machine reset says the disks are still there.
//
// A change made in the menu waits for three things before the drive takes it. The menu closed: the
// machine stands still under it, and would never see the disk go out. No sector in hand. And the
// FDC's buffer written out: upstream's emulator holds a written block until the FDC's command ends
// or it wants another, and a mount clears it unwritten, so a change in the middle of a write would
// lose that block, or after a change of file write it into the new one. A change is the menu's value
// changing, not its differing from what the drive holds, which the disk swap below can change.
//
// The disk swap. A game with more disks than drives ejects the drive and waits for the next one:
// sf2ce and ssf2 load every disk into RAM when there is room, each into drive 1 in turn (files 3-4,
// and 3-7), and want none back. So a drive the program has ejected, left empty with the motor off for
// a second, takes the set's next file after the highest that has been in a drive, if the set has one,
// through the same wait as a menu change. With the motor still running (Human68k stops it 2 s after
// the last access) a disk put in gets Human68k's "no disk" box instead of the game's read, so the
// motor-off second comes first. A game that polls for its next disk itself keeps the motor on and
// would wait for ever (Overtake, after GAME), so a drive left ejected and empty for 5 s takes it
// whatever the motor: sf2ce's and ssf2's motor goes off under 2 s after their ejects, so they take
// the first way, a couple of seconds before this. The menu still changes a drive by hand; it shows
// what was chosen there, not what the swap put in.
//
// Reset Game (Core Settings) starts the game over, as does a game loaded again from the Pocket's menu
// when APF keeps the core and only resets it: each drive goes back to the menu's file as the machine
// comes out of reset, before the IPL looks, and the next file is the one after those. A starting
// machine needn't see a disk go out, so the menu needn't close first; only a block still to be
// written makes it wait, as a menu change.
//
// The sync. The FDC has the emulator write its block out at the end of each write command; one left
// in the buffer some other way (a command cut short) is written once the disk has been quiet for
// 0.1 s (pFDSYNC, which upstream's DIM and XDF emulator didn't take), and again every 0.1 s until it
// has gone, so a drive change can't wait on it for ever.
wire        ldr_done, rom_fail;
wire        fd_dirty;
wire        fd_motor;
wire [1:0]  fd_ejected;
reg  [1:0]  drv_q_v = 2'b00;                //   the first mount has been made
reg  [2:0]  drv0_r = 3'd0, drv1_r = 3'd0;   //   the file each drive holds
reg  [2:0]  drv0_m = 3'd0, drv1_m = 3'd0;   //   the menu's value last taken
reg  [1:0]  fd_back = 2'b00;                //   after a reset: the menu's file again
reg  [2:0]  fd_next = 3'd0;                 //   the swap's next file (7: past the last)
reg  [25:0] fd_wait = 26'd0;                //   ejected, empty and the motor off
reg  [27:0] fd_wait_on = 28'd0;             //   ejected and empty, whatever the motor
reg  [23:0] mnt0 = 24'd0, mnt1 = 24'd0;
reg         rst_q = 1'b1;
reg  [21:0] fd_quiet = 22'd0;
reg  [1:0]  fd_sync = 2'b00;
reg  [7:0]  mounts0 = 8'd0, mounts1 = 8'd0;  // drive changes made, for the overlay
assign drv0_q = drv0_r;
assign drv1_q = drv1_r;

wire [7:0]  mist_rd, mist_wr;
wire [1:0]  mist_ack;
wire        fd_quiet_now = ~disk_busy & ~(|mist_rd[1:0]) & ~(|mist_wr[1:0]) & ~(|mist_ack);
wire        fd_can_swap  = ldr_done & ~inmenu & ~fd_dirty & fd_quiet_now;
localparam [21:0] FD_SYNC_AFTER = 22'd4000000;   // 0.1 s
localparam [25:0] FD_SWAP_AFTER = 26'd40000000;  // 1 s, the motor off
localparam [27:0] FD_SWAP_ON    = 28'd200000000; // 5 s, whatever the motor

wire        menu0    = ldr_done & drv_q_v[0] & (drv0 != drv0_m | fd_back[0]) & fd_can_swap;
wire        menu1    = ldr_done & drv_q_v[1] & (drv1 != drv1_m | fd_back[1]) & fd_can_swap;
wire        menu_pend = drv0 != drv0_m | drv1 != drv1_m | (|fd_back);
wire [1:0]  fd_empty = fd_ejected & {mnt1 == 24'd0, mnt0 == 24'd0};
wire        fd_has_next = fd_next != 3'd7 && dsize_74[fd_next] != 21'd0;
wire        fd_swap_ok = drv_q_v == 2'b11 & (|fd_empty) & fd_can_swap & ~menu_pend & fd_has_next
                         & ~machine_rst;

// the next file once f has been in a drive (7: none)
function [2:0] after(input [2:0] n, input [2:0] f);
    after = (f == 3'd7 || f < n) ? n : f + 3'd1;
endfunction

reg  [2:0]  next_v;
always @(posedge clk40) begin
    rst_q <= machine_rst;
    if (mnt0 != 24'd0) mnt0 <= mnt0 - 24'd1;
    if (mnt1 != 24'd0) mnt1 <= mnt1 - 24'd1;
    next_v = fd_next;

    // the first mount, as the machine starts
    if (ldr_done && !drv_q_v[0]) begin
        mounts0 <= mounts0 + 8'd1;
        drv0_r  <= drv0;
        drv0_m  <= drv0;
        drv_q_v[0] <= 1'b1;
        mnt0    <= 24'hFFFFFF;
        next_v  = after(next_v, drv0);
    end
    if (ldr_done && !drv_q_v[1]) begin
        mounts1 <= mounts1 + 8'd1;
        drv1_r  <= drv1;
        drv1_m  <= drv1;
        drv_q_v[1] <= 1'b1;
        mnt1    <= 24'hFFFFFF;
        next_v  = after(next_v, drv1);
    end

    // the menu's
    if (menu0) begin
        drv0_m     <= drv0;
        fd_back[0] <= 1'b0;
        if (drv0 != drv0_r) begin
            mounts0 <= mounts0 + 8'd1;
            drv0_r  <= drv0;
            mnt0    <= 24'hFFFFFF;
        end
        next_v = after(next_v, drv0);
    end
    if (menu1) begin
        drv1_m     <= drv1;
        fd_back[1] <= 1'b0;
        if (drv1 != drv1_r) begin
            mounts1 <= mounts1 + 8'd1;
            drv1_r  <= drv1;
            mnt1    <= 24'hFFFFFF;
        end
        next_v = after(next_v, drv1);
    end

    // the swap's, drive 1 first if both are empty
    if (!fd_swap_ok || fd_motor) fd_wait <= 26'd0;
    else if (fd_wait != FD_SWAP_AFTER) fd_wait <= fd_wait + 26'd1;
    if (!fd_swap_ok) fd_wait_on <= 28'd0;
    else if (fd_wait_on != FD_SWAP_ON) fd_wait_on <= fd_wait_on + 28'd1;
    if (fd_swap_ok && (fd_wait == FD_SWAP_AFTER || fd_wait_on == FD_SWAP_ON)) begin
        fd_wait    <= 26'd0;
        fd_wait_on <= 28'd0;
        if (fd_empty[1]) begin
            mounts1 <= mounts1 + 8'd1;
            drv1_r  <= fd_next;
            mnt1    <= 24'hFFFFFF;
        end else begin
            mounts0 <= mounts0 + 8'd1;
            drv0_r  <= fd_next;
            mnt0    <= 24'hFFFFFF;
        end
        next_v = after(next_v, fd_next);
    end
    fd_next <= next_v;

    if (rst_q && !machine_rst && drv_q_v == 2'b11) begin
        mnt0 <= 24'h00FFFF;
        mnt1 <= 24'h00FFFF;
        if (!fd_dirty) begin                // the menu's files, in at once with the pulse above
            drv0_r  <= drv0;
            drv0_m  <= drv0;
            drv1_r  <= drv1;
            drv1_m  <= drv1;
            fd_next <= after(after(3'd0, drv0), drv1);
        end else begin                      // a block to write first: as a menu change
            fd_back <= 2'b11;
            fd_next <= 3'd0;
        end
    end

    fd_sync <= 2'b00;
    if (!fd_dirty || !fd_quiet_now) fd_quiet <= 22'd0;
    else if (fd_quiet != FD_SYNC_AFTER) fd_quiet <= fd_quiet + 22'd1;
    else begin
        fd_quiet <= 22'd0;
        fd_sync  <= 2'b11;
    end
end

wire  [1:0] fd_eject   = {|mnt1[23:16], |mnt0[23:16]};
wire  [1:0] fd_mounted = {~fd_eject[1] & (|mnt1) & (|size1), ~fd_eject[0] & (|mnt0) & (|size0)};
wire [20:0] fd_size    = fd_mounted[0] ? size0 : size1;

// ================================================================== disks
wire [31:0] mist_lba;
wire [8:0]  mist_buffaddr;
wire [7:0]  mist_buffdout, mist_buffdin;
wire        mist_buffwr;

wire [19:0] ldr_addr;
wire        ldr_aen, ldr_wr, ldr_ack;
wire [7:0]  ldr_wdat;
wire [1:0]  ps_ready, ps_fail;
wire [6:0]  ps0_lat, ps1_lat;
wire        ps_late, disk_err;
wire [7:0]  ps_cpu_wait;
wire [15:0] sector_peak;
wire [4:0]  disk_st;

pocket_disk u_disk (
    .clk_74a        (clk_74a),
    .bridge_wr      (bridge_wr),
    .bridge_rd      (bridge_rd),
    .bridge_addr    (bridge_addr),
    .bridge_wr_data (bridge_wr_data),
    .bridge_rd_word (win_bridge_rd),
    .clk            (clk40),
    .rst            (~pll_locked_40),
    .go             (allcomplete_40 & reset_n_40 & (&ps_ready)),
    .t_read         (t_read),
    .t_write        (t_write),
    .t_id           (t_id),
    .t_offset       (t_offset),
    .t_length       (t_length),
    .t_done         (t_done_40),
    .t_err          (t_err_40),
    .drive0_id      (16'd10 + {13'd0, drv0_q}),
    .drive1_id      (16'd10 + {13'd0, drv1_q}),
    .drive0_size    (size0),
    .drive1_size    (size1),
    .ldr_addr       (ldr_addr),
    .ldr_aen        (ldr_aen),
    .ldr_wdat       (ldr_wdat),
    .ldr_wr         (ldr_wr),
    .ldr_ack        (ldr_ack),
    .ldr_done       (ldr_done),
    .rom_fail       (rom_fail),
    .mist_lba       (mist_lba),
    .mist_rd        (mist_rd[1:0]),
    .mist_wr        (mist_wr[1:0]),
    .mist_ack       (mist_ack),
    .mist_buffaddr  (mist_buffaddr),
    .mist_buffdout  (mist_buffdout),
    .mist_buffdin   (mist_buffdin),
    .mist_buffwr    (mist_buffwr),
    .busy           (disk_busy),
    .err            (disk_err),
    .sector_peak    (sector_peak),
    .diag_clr       (diag_clr),
    .state          (disk_st)
);

// ================================================================== save
wire [13:0] nv_addr;
wire [7:0]  nv_wdat, nv_rdat;
wire        nv_wr;

pocket_sram_slot u_save (
    .clk_74a        (clk_74a),
    .bridge_wr      (bridge_wr),
    .bridge_rd      (bridge_rd),
    .bridge_addr    (bridge_addr),
    .bridge_wr_data (bridge_wr_data),
    .bridge_rd_word (nv_bridge_rd),
    .nv_addr        (nv_addr),
    .nv_wdat        (nv_wdat),
    .nv_wr          (nv_wr),
    .nv_rdat        (nv_rdat)
);

// ================================================================== PSRAM pins
//
// The chips' clocks leave through DDIO cells, high while clk40 is low, so a chip's rising edge is
// midway between the edges its pins change on (pocket_psram_bus).
wire [15:0] cram0_dq_o, cram1_dq_o;
wire        cram0_dq_oe, cram1_dq_oe, cram0_run, cram1_run;
assign cram0_dq = cram0_dq_oe ? cram0_dq_o : 16'hzzzz;
assign cram1_dq = cram1_dq_oe ? cram1_dq_o : 16'hzzzz;

pin_ddio_clk u_cram0_clk (.datain_h(1'b0), .datain_l(cram0_run), .outclock(clk40), .dataout(cram0_clk));
pin_ddio_clk u_cram1_clk (.datain_h(1'b0), .datain_l(cram1_run), .outclock(clk40), .dataout(cram1_clk));

// ================================================================== SDRAM pins
//
// The Pocket's SDRAM has no CS# pin, and its clock is forwarded a half period behind clk80.
wire        sd_cs_n_unused, sd_ldq, sd_udq, sd_ba0, sd_ba1;
assign dram_dqm = {sd_udq, sd_ldq};
assign dram_ba  = {sd_ba1, sd_ba0};

pin_ddio_clk u_dram_clk (.datain_h(1'b1), .datain_l(1'b0), .outclock(clk_sdram_ps), .dataout(dram_clk));

// ================================================================== the machine
wire [7:0]  v_r, v_g, v_b;
wire        v_ce, v_hs, v_vs, v_hb, v_hbw, v_vbw, v_en;
wire [3:0]  v_mode;
wire [15:0] snd_l, snd_r;

// Upstream waits for its PLL here. There's none: a change of mode only has to settle, and the scan-out
// to be reset across it, so it comes back on a mode that has held for a moment.
reg  [3:0]  scan_mode = 4'd0;
reg  [3:0]  mode_q = 4'd0;
reg  [7:0]  mode_quiet = 8'd0;
always @(posedge clk40) begin
    mode_q <= v_mode;
    if (mode_q != v_mode) mode_quiet <= 8'd0;
    else if (mode_quiet != 8'hFF) mode_quiet <= mode_quiet + 8'd1;
    else scan_mode <= mode_q;
end

wire        led_unused;
wire [1:0]  fd_active;

X68K_top u_x68k (
    .ramclk      (clk80),
    .sysclk      (clk40),
    .vidclk      (clk40),
    .sprclk      (clk80),
    .scanclk     (clk80),
    .scan_ready  (&mode_quiet),
    .scan_mode   (scan_mode),
    .scan_reset_out (),
    .fdcclk      (clk40),
    .sndclk      (clk40),

    .sys_ce      (sys_ce_r),
    .mpu_cep     (mpu_cep_r),
    .mpu_cen     (mpu_cen_r),
    .snd_ce      (snd_ce_r),
    .opm_ce      (opm_ce_r),
    .cm_out      (snd_clockmode),
    .vid_hz      (1'b0),

    .plllock     (pll_locked_40),
    .sysrtc      (sysrtc),

    .pMemCke     (dram_cke),
    .pMemCs_n    (sd_cs_n_unused),
    .pMemRas_n   (dram_ras_n),
    .pMemCas_n   (dram_cas_n),
    .pMemWe_n    (dram_we_n),
    .pMemUdq     (sd_udq),
    .pMemLdq     (sd_ldq),
    .pMemBa1     (sd_ba1),
    .pMemBa0     (sd_ba0),
    .pMemAdr     (dram_a),
    .pMemDat     (dram_dq),

    .cram0_run   (cram0_run),   .cram0_a     (cram0_a),     .cram0_dq_o  (cram0_dq_o),
    .cram0_dq_oe (cram0_dq_oe), .cram0_dq_i  (cram0_dq),    .cram0_adv_n (cram0_adv_n),
    .cram0_cre   (cram0_cre),   .cram0_ce0_n (cram0_ce0_n), .cram0_oe_n  (cram0_oe_n),
    .cram0_we_n  (cram0_we_n),  .cram0_ub_n  (cram0_ub_n),  .cram0_lb_n  (cram0_lb_n),
    .cram1_run   (cram1_run),   .cram1_a     (cram1_a),     .cram1_dq_o  (cram1_dq_o),
    .cram1_dq_oe (cram1_dq_oe), .cram1_dq_i  (cram1_dq),    .cram1_adv_n (cram1_adv_n),
    .cram1_cre   (cram1_cre),   .cram1_ce0_n (cram1_ce0_n), .cram1_oe_n  (cram1_oe_n),
    .cram1_we_n  (cram1_we_n),  .cram1_ub_n  (cram1_ub_n),  .cram1_lb_n  (cram1_lb_n),
    .ps_ready    (ps_ready),
    .ps_fail     (ps_fail),
    .ps0_lat     (ps0_lat),
    .ps1_lat     (ps1_lat),
    .ps_late     (ps_late),
    .ps_cpu_wait (ps_cpu_wait),
    .ps_diag_clr (diag_clr),

    .save_clk    (clk_74a),
    .save_addr   (nv_addr),
    .save_wdat   (nv_wdat),
    .save_wr     (nv_wr),
    .save_rdat   (nv_rdat),

    .ldr_addr    (ldr_addr),
    .ldr_aen     (ldr_aen),
    .ldr_wdat    (ldr_wdat),
    .ldr_wr      (ldr_wr),
    .ldr_ack     (ldr_ack),
    .ldr_done    (ldr_done),

    // the keyboard is pocket_kbd's two keys; no mouse: its lines rest high
    .pPs2Clkin   (kbd_clk), .pPs2Clkout (kbd_hclk), .pPs2Datin (kbd_dat), .pPs2Datout (kbd_hdat),
    .pPmsClkin   (1'b1), .pPmsClkout (), .pPmsDatin (1'b1), .pPmsDatout (),

    .pJoyA       (joy_a),
    .pJoyB       (joy_b),
    .pStrA       (),
    .pStrB       (),
    .pJoySelA    (str_a),
    .pJoySelB    (str_b),

    .pFDSYNC     (fd_sync),
    .pFDDIRTY    (fd_dirty),
    .pFDEJECT    (fd_eject),
    .pFDMOTOR    (fd_motor),
    .pFDACTIVE   (fd_active),
    .pFDEJECTED  (fd_ejected),
    .pfdwait     (2'b00),

    .mist_mounted ({6'd0, fd_mounted}),
    .mist_readonly(8'd0),
    .mist_imgsize ({43'd0, fd_size}),
    .mist_lba    (mist_lba),
    .mist_rd     (mist_rd),
    .mist_wr     (mist_wr),
    .mist_ack    ({6'd0, mist_ack}),
    .mist_buffaddr (mist_buffaddr),
    .mist_buffdout (mist_buffdout),
    .mist_buffdin  (mist_buffdin),
    .mist_buffwr   (mist_buffwr),

    .pDip        (4'b0000),
    .pLed        (led_unused),
    .pPsw        (2'b11),
    .pkbdtype    (3'd0),
    .pSramld     (1'b0),
    .pSramst     (1'b0),

    .pMidi_in    (1'b1),
    .pMidi_out   (),

    .pVideoClk   (v_ce),
    .pVideoR     (v_r),
    .pVideoG     (v_g),
    .pVideoB     (v_b),
    .pVideoHB    (v_hb),
    .pVideoVB    (v_vb),
    .pVideoHBw   (v_hbw),
    .pVideoVBw   (v_vbw),
    .pVideoEN    (v_en),
    .pVideoHS    (v_hs),
    .pVideoVS    (v_vs),
    .pVideoF1    (),
    .pVideo31k   (),
    .pPixCe      (1'b0),
    .pPixExt     (1'b0),
    .pVideoMode  (v_mode),
    .pVideoDyn   (),

    .pSndL       (snd_r),
    .pSndR       (snd_l),
    .pSndYML     (), .pSndYMR (), .pSndPCML (), .pSndPCMR (),

    .rstn        (~machine_rst),
    .vid_mode    (2'b01),            // HB and VB of the box, a fixed size whatever the program sets;
                                     // HBw and VBw the program's own window, for the scan-out's crop
    .mix_fix     (1'b1)
);

// ============================================================ DIAGNOSTICS
//
// pocket_diag draws these over the picture when the menu's Diagnostic overlay is on, over colour bars
// until the boot ROM is in. With it off, the screen is black until then, or says BOOT ROM NOT FOUND
// if the card had no boot ROM to give. Values change a few times a frame and are only read off
// the screen, so they go to it as they stand.
//
// Flags (left to right, green = 1):
//   0 PLL locked              1 SDRAM initialised         2 APF reset released
//   3 APF all slots seen      4 boot ROM in               5 no card command has failed
//   6 CRAM0 ready, measured   7 CRAM1 ready, measured     8 machine out of reset
//   9 overlay on              10 blinks, about once a second
//   11 a disk's size is known in drive 0                  12 the same in drive 1
//   13 every graphics row filled before its line          14 FD motor on
//   15 in the Pocket's menu
//
// Counters (hex):
//   0 CRAM latencies: chip 1 write, sample edge and read; chip 0 the same, a digit each (a read of
//     8 or more is latency + 8, at the later edge)
//   1 the CPU's longest wait for graphics VRAM, clocks of 40 MHz
//   2 the longest sector, in units of 102 us (a floppy's own is thousands of us)
//   3 the frame count, low 16 bits
//   4 the drives, a digit each: drive 0 in the menu, drive 0 as held, drive 1 the same two (0-6 files
//     1-7, 7 none); {dirty block, sector in hand, a read asked for, ack}; {the swap waiting its
//     second, the set has a next file, drive 1 ejected, drive 0 ejected} (empty since the program
//     ejected it); pocket_disk's state, two digits
//   5 drive changes made: drive 1's count, drive 0's, two digits each; the sectors read and written,
//     low 16 bits
//   6 the last card command: slot id (two digits), its error, the mailbox {waiting on 0x0140, waiting on
//     a card command, 'bu' in it, 'cm' in it} (0 idle; 5 asked and not taken up, 6 taken up, not done),
//     then its offset in 512-byte sectors
//   7 card commands the watchdog gave up on or asked again (two digits, from power-on), then drive 1's
//     file size in bytes, as the data table gives it
reg  [15:0] frames = 16'd0;
reg         vb_q = 1'b0;
always @(posedge clk40) begin
    vb_q <= v_vb;
    if (v_vb && !vb_q) frames <= frames + 16'd1;
end

wire [15:0] diag_flags = {inmenu, fd_motor, ~ps_late, |size1, |size0, frames[5], diag_opt, ~machine_rst,
                          ps_ready[1] & ~ps_fail[1], ps_ready[0] & ~ps_fail[0], ~disk_err, ldr_done,
                          allcomplete_40, reset_n_40, 1'b1, pll_locked_40};
reg  [15:0] sectors = 16'd0;
reg         t_go_q = 1'b0;
always @(posedge clk40) begin
    t_go_q <= t_read | t_write;
    if ((t_read | t_write) && !t_go_q && ldr_done) sectors <= sectors + 16'd1;
end
wire [255:0] diag_cnt = {target_wd_count, 3'd0, size1,
                         t_id[7:0], 1'b0, t_err_40, target_wd_state, t_offset[24:9],
                         mounts1, mounts0, sectors,
                         1'b0, drv0, 1'b0, drv0_r, 1'b0, drv1, 1'b0, drv1_r,
                         fd_dirty, disk_busy, |mist_rd[1:0], |mist_ack, fd_swap_ok, fd_has_next, fd_ejected,
                         3'd0, disk_st,
                         16'd0, frames,
                         16'd0, sector_peak,
                         24'd0, ps_cpu_wait,
                         16'd0, 1'b0, ps1_lat[6:4], ps1_lat[3:0], 1'b0, ps0_lat[6:4], ps0_lat[3:0]};

// ================================================================== video
assign video_rgb_clock    = clk40;
assign video_rgb_clock_90 = clk40_90;

pocket_scanout u_scanout (
    .clk80     (clk80),
    .ce        (v_ce),
    .hs        (v_hs),
    .vs        (v_vs),
    .hb        (v_hb),
    .vb        (v_vb),
    .hbw       (v_hbw),
    .vbw       (v_vbw),
    .r         (v_r),
    .g         (v_g),
    .b         (v_b),
    .clk40     (clk40),
    .black     (inmenu),
    .own_raster(~ldr_done),
    .diag_on   (diag_opt),
    .bars      (diag_opt & ~ldr_done),
    .msg       (rom_fail),
    .flags     (diag_flags),
    .cnt       (diag_cnt),
    .video_rgb (video_rgb),
    .video_de  (video_de),
    .video_hs  (video_hs),
    .video_vs  (video_vs),
    .video_skip(video_skip)
);

// ================================================================== audio
//
// The machine's two channels, resampled from the FM chip's 62.5 kHz to 48 kHz (pocket_audio_resample
// says why); sound_i2s (agg23, MIT) makes MCLK, SCLK and LRCK from clk_74a and takes each new sample
// across through a small FIFO.
wire signed [15:0] aud_l, aud_r;
pocket_audio_resample u_resample (
    .clk   (clk40),
    .in_l  (snd_l),
    .in_r  (snd_r),
    .out_l (aud_l),
    .out_r (aud_r)
);

sound_i2s #(
    .CHANNEL_WIDTH(16),
    .SIGNED_INPUT (1)
) u_i2s (
    .clk_74a   (clk_74a),
    .clk_audio (clk40),
    .audio_l   (aud_l),
    .audio_r   (aud_r),
    .audio_mclk(audio_mclk),
    .audio_lrck(audio_lrck),
    .audio_dac (audio_dac)
);

endmodule

`default_nettype wire
