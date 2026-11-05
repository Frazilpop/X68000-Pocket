// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket: graphics VRAM, 512 KB on CRAM0, in place of upstream's gvram_ctrl.
//
// THE RENDERER'S SIDE IS UPSTREAM'S. vidcont reads eight ports, four pages of two banks: one bank
// is rendered from while the other is filled for the next line, and they swap at hcomp. Each port
// sits on a 512-word line cache with a tag, and a port asking for a row its cache doesn't hold starts
// a fill, which fills every port wanting that row. Rows are fetched whole, because a game's raster
// scroll may change X right up to the line, so a window worked out earlier could be the wrong one.
//
// THE FILL takes 4 bursts of 128 words, 3.4 us each, 13.7 us a row. Each bank fills for itself, so a
// double-scanned line with two pages on different rows costs two rows every raster line, not every
// other: at 16 words a burst, 20 us a row, that was 40 us of a 31.7 us line. A CPU access gets the chip
// after any burst, so a fill holds the CPU up for one burst at most, and a fill or a fast clear gets
// the next turn after a CPU access. `late` says a fill was still going at hcomp, when the renderer
// starts on it.
//
// CPU WRITES GO THROUGH. Upstream throws a written row out of its caches and reads it again: 6 us
// from block RAM, but 18 us here, and a game writing to a row on display could keep it from ever
// finishing. So a write updates the word in any cache holding its row, byte enables and all, and the
// tag stands. A word fetched after the write is new in the chip; one fetched before is updated here.
//
// WRITES. A word or byte mask goes straight to the chip with its byte enables. A nibble mask, the
// 16-colour modes, reads the word first.
//
// FAST CLEAR. As upstream: when a page asks for a row it didn't clear last, its nibbles of that row
// go to zero, sharing the row with any other page asking for the same one, and every tag is thrown
// out. Whole bytes are a plain write burst; single nibbles read each burst into a small buffer first.
//
// One clock throughout, 40 MHz: the renderer, the CPU's bus and this are all on it, so nothing
// here crosses a clock. Addresses are the machine's word addresses, 256K words, 2^18.

`default_nettype none

module gvram_psram (
  input  wire        clk,
  input  wire        rstn,
  input  wire        hcomp,

  input  wire [17:0] g00_addr, input wire g00_rd, output wire [15:0] g00_rdat,
  input  wire [17:0] g01_addr, input wire g01_rd, output wire [15:0] g01_rdat,
  input  wire [17:0] g02_addr, input wire g02_rd, output wire [15:0] g02_rdat,
  input  wire [17:0] g03_addr, input wire g03_rd, output wire [15:0] g03_rdat,
  input  wire [17:0] g10_addr, input wire g10_rd, output wire [15:0] g10_rdat,
  input  wire [17:0] g11_addr, input wire g11_rd, output wire [15:0] g11_rdat,
  input  wire [17:0] g12_addr, input wire g12_rd, output wire [15:0] g12_rdat,
  input  wire [17:0] g13_addr, input wire g13_rd, output wire [15:0] g13_rdat,

  input  wire [9:0]  g0_caddr, input wire g0_clear,
  input  wire [9:0]  g1_caddr, input wire g1_clear,
  input  wire [9:0]  g2_caddr, input wire g2_clear,
  input  wire [9:0]  g3_caddr, input wire g3_clear,

  input  wire [17:0] cpu_addr,
  input  wire [15:0] cpu_wdat,
  output reg  [15:0] cpu_rdat,
  input  wire [1:0]  cpu_wr,
  input  wire        cpu_rd,
  input  wire [1:0]  cpu_rmw,
  input  wire [15:0] cpu_rmwmask,
  output wire        cpu_ack,

  input  wire        diag_clr,
  output reg         late,
  output reg  [7:0]  cpu_wait_peak,
  output wire        ready,
  output wire        cal_fail,
  output wire [2:0]  rd_lat,
  output wire        rd_ph,
  output wire [2:0]  wr_lat,

  output wire        cram_run,
  output wire [21:16] cram_a,
  output wire [15:0] cram_dq_o,
  output wire        cram_dq_oe,
  input  wire [15:0] cram_dq_i,
  output wire        cram_adv_n,
  output wire        cram_cre,
  output wire        cram_ce0_n,
  output wire        cram_oe_n,
  output wire        cram_we_n,
  output wire        cram_ub_n,
  output wire        cram_lb_n
);

  localparam [2:0] S_IDLE = 3'd0, S_FILL = 3'd1, S_CLR_RD = 3'd2, S_CLR_WR = 3'd3,
                   S_CPU_RD = 3'd4, S_CPU_RMW = 3'd5, S_CPU_WR = 3'd6;
  reg [2:0] st;

  // ------------------------------------------------------------------ the chip
  reg         p_req, p_we;
  reg  [17:0] p_addr;
  reg  [6:0]  p_len;
  wire        p_grant, p_done, p_rd_valid;
  wire [15:0] p_rd_data;
  wire [6:0]  p_idx;
  reg  [15:0] p_wdata;
  reg  [1:0]  p_wbe;

  reg rst_p = 1'b1;
  always @(posedge clk) rst_p <= 1'b0;

  pocket_psram_bus #(.CLEAR_BURSTS(16384)) u_chip (
    .clk(clk), .rst(rst_p),
    .req(p_req), .we(p_we), .addr(p_addr), .len_m1(p_len),
    .grant(p_grant), .done(p_done), .rd_valid(p_rd_valid), .rd_data(p_rd_data), .word_idx(p_idx),
    .wdata(p_wdata), .wbe(p_wbe),
    .ready(ready), .cal_fail(cal_fail), .rd_lat(rd_lat), .rd_ph(rd_ph), .wr_lat(wr_lat),
    .cram_run(cram_run), .cram_a(cram_a), .cram_dq_o(cram_dq_o), .cram_dq_oe(cram_dq_oe),
    .cram_dq_i(cram_dq_i), .cram_adv_n(cram_adv_n), .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n),
    .cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n), .cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n)
  );

  // ------------------------------------------------------- the ports and tags
  wire [7:0]  port_rd  = {g13_rd, g12_rd, g11_rd, g10_rd, g03_rd, g02_rd, g01_rd, g00_rd};
  wire [17:0] port_addr [0:7];
  assign port_addr[0] = g00_addr; assign port_addr[1] = g01_addr;
  assign port_addr[2] = g02_addr; assign port_addr[3] = g03_addr;
  assign port_addr[4] = g10_addr; assign port_addr[5] = g11_addr;
  assign port_addr[6] = g12_addr; assign port_addr[7] = g13_addr;
  wire [15:0] port_q [0:7];
  assign g00_rdat = port_q[0]; assign g01_rdat = port_q[1];
  assign g02_rdat = port_q[2]; assign g03_rdat = port_q[3];
  assign g10_rdat = port_q[4]; assign g11_rdat = port_q[5];
  assign g12_rdat = port_q[6]; assign g13_rdat = port_q[7];

  reg  [8:0] tag [0:7];
  reg  [7:0] valid;
  reg  [7:0] fill_mask;
  reg  [8:0] fill_row;
  reg  [1:0] fill_b;
  reg        fill_active;

  // the caches' one write port, the fill's or the CPU's: they never run together
  reg  [8:0]  cw_col;
  reg  [15:0] cw_data;
  reg  [1:0]  cw_be;
  reg  [8:0]  cw_row;
  reg         cw_commit;

  wire [8:0]  cache_waddr = cw_commit ? cw_col : {fill_b, p_idx};
  wire [15:0] cache_wdata = cw_commit ? cw_data : p_rd_data;
  wire [1:0]  cache_be    = cw_commit ? cw_be : 2'b11;
  reg  fill_op;                               // the operation in hand is a fill's burst

  wire [7:0] miss, hit_w;
  genvar g;
  generate for (g = 0; g < 8; g = g + 1) begin : ports
    assign miss[g]  = port_rd[g] && (!valid[g] || tag[g] != port_addr[g][17:9]);
    assign hit_w[g] = valid[g] && tag[g] == cw_row;
    pocket_vram_cache #(.AW(9)) u_cache (
      .clk(clk),
      .we((p_rd_valid && fill_op && fill_mask[g]) || (cw_commit && hit_w[g])),
      .be(cache_be), .waddr(cache_waddr), .wdata(cache_wdata),
      .raddr(port_addr[g][8:0]), .q(port_q[g])
    );
  end endgenerate

  reg [8:0] pick_row;
  integer   pi;
  always @(*) begin
    pick_row = 9'd0;
    for (pi = 7; pi >= 0; pi = pi - 1) if (miss[pi]) pick_row = port_addr[pi][17:9];
  end
  wire any_miss = |miss;

  // ---------------------------------------------------------------- fast clear
  reg  [9:0] caddrh [0:3];
  reg  [3:0] clr_pages;
  reg  [8:0] clr_row;
  reg  [4:0] clr_b;
  reg        clr_active;

  wire [3:0] clr_want = {g3_clear && g3_caddr != caddrh[3], g2_clear && g2_caddr != caddrh[2],
                         g1_clear && g1_caddr != caddrh[1], g0_clear && g0_caddr != caddrh[0]};
  wire [8:0] clr_pick = clr_want[0] ? g0_caddr[9:1] : clr_want[1] ? g1_caddr[9:1] :
                        clr_want[2] ? g2_caddr[9:1] : g3_caddr[9:1];
  wire [3:0] clr_same = {clr_want[3] && g3_caddr[9:1] == clr_pick, clr_want[2] && g2_caddr[9:1] == clr_pick,
                         clr_want[1] && g1_caddr[9:1] == clr_pick, clr_want[0] && g0_caddr[9:1] == clr_pick};

  wire [15:0] clr_mask   = {{4{clr_pages[3]}}, {4{clr_pages[2]}}, {4{clr_pages[1]}}, {4{clr_pages[0]}}};
  wire        clr_nibble = (clr_pages[1] != clr_pages[0]) || (clr_pages[3] != clr_pages[2]);

  (* ramstyle = "MLAB, no_rw_check" *) reg [15:0] clr_buf [0:15];
  reg  [15:0] clr_buf_q;
  always @(*) clr_buf_q = clr_buf[p_idx[3:0]];
  always @(posedge clk) if (p_rd_valid && st == S_CLR_RD) clr_buf[p_idx[3:0]] <= p_rd_data;

  // ---------------------------------------------------------------------- CPU
  wire cpu_req = cpu_rd || (|cpu_wr) || (|cpu_rmw);
  reg  cpu_done;
  assign cpu_ack = cpu_done && cpu_req;
  wire cpu_pending = cpu_req && !cpu_done;

  // what a write will send: the mask, and whether it needs the word read first
  wire [15:0] w_mask   = (|cpu_rmw) ? cpu_rmwmask : {{8{cpu_wr[1]}}, {8{cpu_wr[0]}}};
  wire        w_direct = (w_mask == 16'hFFFF) || (w_mask == 16'hFF00) || (w_mask == 16'h00FF);
  wire [1:0]  w_be     = {w_mask[15], w_mask[0]};

  // ------------------------------------------------------------ the arbitration
  reg       cpu_turn;                          // a burst has gone by: the CPU may go next
  reg       clr_turn;                          // of the two bursts, the clear goes next

  // the data a write burst sends, for the word it's on
  always @(*) begin
    p_wdata = cw_data;
    p_wbe   = cw_be;
    if (st == S_CLR_WR) begin
      p_wdata = clr_nibble ? (clr_buf_q & ~clr_mask) : 16'd0;
      p_wbe   = clr_nibble ? 2'b11 : {clr_pages[3] | clr_pages[2], clr_pages[1] | clr_pages[0]};
    end
  end

  reg [7:0] cpu_wait;
  integer i;
  always @(posedge clk) begin
    cw_commit <= 1'b0;
    if (p_grant) p_req <= 1'b0;
    if (!cpu_req) cpu_done <= 1'b0;
    if (hcomp && fill_active) late <= 1'b1;
    // how long the CPU waits for the chip: read off the overlay, in clocks of 40 MHz
    if (!cpu_pending) cpu_wait <= 8'd0;
    else if (cpu_wait != 8'hFF) cpu_wait <= cpu_wait + 8'd1;
    if (cpu_pending && cpu_wait > cpu_wait_peak) cpu_wait_peak <= cpu_wait;
    if (diag_clr) begin late <= 1'b0; cpu_wait_peak <= 8'd0; end

    if (!rstn) begin
      st          <= S_IDLE;
      p_req       <= 1'b0;
      valid       <= 8'd0;
      fill_active <= 1'b0;
      fill_op     <= 1'b0;
      clr_active  <= 1'b0;
      cpu_done    <= 1'b0;
      cpu_turn    <= 1'b0;
      clr_turn    <= 1'b0;
      for (i = 0; i < 4; i = i + 1) caddrh[i] <= 10'h3FF;
    end else begin
      // a new row to fetch, when none is in hand
      if (!fill_active && any_miss) begin
        fill_active <= 1'b1;
        fill_row    <= pick_row;
        fill_b      <= 2'd0;
        for (i = 0; i < 8; i = i + 1) begin
          if (miss[i] && port_addr[i][17:9] == pick_row) begin
            tag[i]       <= pick_row;
            valid[i]     <= 1'b1;
            fill_mask[i] <= 1'b1;
          end else
            fill_mask[i] <= 1'b0;
        end
      end

      // a new row to clear, when none is in hand
      if (!clr_active && (|clr_want)) begin
        clr_active <= 1'b1;
        clr_row    <= clr_pick;
        clr_pages  <= clr_same;
        clr_b      <= 5'd0;
        if (clr_same[0]) caddrh[0] <= g0_caddr;
        if (clr_same[1]) caddrh[1] <= g1_caddr;
        if (clr_same[2]) caddrh[2] <= g2_caddr;
        if (clr_same[3]) caddrh[3] <= g3_caddr;
        valid <= 8'd0;
      end

      case (st)
        S_IDLE: begin
          fill_op <= 1'b0;
          if (cpu_pending && (cpu_turn || !(fill_active || clr_active))) begin
            cpu_turn <= 1'b0;
            p_req    <= 1'b1;
            p_len    <= 7'd0;
            p_addr   <= cpu_addr;
            cw_row   <= cpu_addr[17:9];
            cw_col   <= cpu_addr[8:0];
            if (cpu_rd) begin
              p_we <= 1'b0;
              st   <= S_CPU_RD;
            end else if (w_direct) begin
              p_we    <= 1'b1;
              cw_data <= cpu_wdat;
              cw_be   <= w_be;
              st      <= S_CPU_WR;
            end else begin
              p_we <= 1'b0;
              st   <= S_CPU_RMW;
            end
          end else if (fill_active && !(clr_active && clr_turn)) begin
            clr_turn <= 1'b1;
            cpu_turn <= 1'b1;
            fill_op  <= 1'b1;
            p_req    <= 1'b1;
            p_we     <= 1'b0;
            p_len    <= 7'd127;
            p_addr   <= {fill_row, fill_b, 7'd0};
            st       <= S_FILL;
          end else if (clr_active) begin
            clr_turn <= 1'b0;
            cpu_turn <= 1'b1;
            p_req    <= 1'b1;
            p_we     <= !clr_nibble;
            p_len    <= 7'd15;
            p_addr   <= {clr_row, clr_b, 4'd0};
            st       <= clr_nibble ? S_CLR_RD : S_CLR_WR;
          end
        end

        S_FILL: if (p_done) begin
          if (fill_b == 2'd3) fill_active <= 1'b0;
          fill_b <= fill_b + 2'd1;
          st     <= S_IDLE;
        end

        S_CLR_RD: if (p_done) begin
          p_req <= 1'b1;
          p_we  <= 1'b1;
          st    <= S_CLR_WR;
        end

        S_CLR_WR: if (p_done) begin
          if (clr_b == 5'd31) clr_active <= 1'b0;
          clr_b <= clr_b + 5'd1;
          st    <= S_IDLE;
        end

        S_CPU_RD: begin
          if (p_rd_valid) cpu_rdat <= p_rd_data;
          if (p_done) begin
            cpu_done <= 1'b1;
            st       <= S_IDLE;
          end
        end

        S_CPU_RMW: begin
          if (p_rd_valid) cw_data <= (p_rd_data & ~w_mask) | (cpu_wdat & w_mask);
          if (p_done) begin
            cw_be <= 2'b11;
            p_req <= 1'b1;
            p_we  <= 1'b1;
            st    <= S_CPU_WR;
          end
        end

        S_CPU_WR: if (p_done) begin
          cw_commit <= 1'b1;
          cpu_done  <= 1'b1;
          st        <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
