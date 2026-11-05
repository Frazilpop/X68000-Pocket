// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket: text VRAM, 512 KB on CRAM1, in place of upstream's tvram_ddr.
//
// Four planes of 64K words, each at its own place on the chip: word {plane, q}, q being the 16-bit
// word within a plane. The renderer reads through two line caches of 64 words a plane, one being
// rendered from and one filled for the next line, as graphics VRAM; they fill in 16 bursts, 8.8 us.
//
// The CPU gets the chip after any burst. A write goes through to a cache holding its row, as in
// gvram_psram, which says why. A mask of whole bytes goes straight to the chip, others read first.
//
// A raster copy moves 32 words of each plane the mask names, through a 32-word buffer, and takes
// the destination's row out of the caches. Upstream's request and acknowledge stand: a level and a
// toggle.

`default_nettype none

module tvram_psram (
  input  wire        clk,
  input  wire        rstn,

  input  wire [17:0] cpu_addr,                 // [1:0] the plane, [17:2] the word in it
  input  wire [15:0] cpu_wdat,
  input  wire        cpu_rd,
  input  wire [1:0]  cpu_wr,
  input  wire [1:0]  cpu_rmw,
  input  wire [15:0] cpu_rmwmask,
  output reg  [15:0] cpu_rdat,
  output wire        cpu_ack,

  input  wire [10:0] cpy_src,
  input  wire [10:0] cpy_dst,
  input  wire [3:0]  cpy_plane,
  input  wire        cpy_req,
  output reg         cpy_ack,

  input  wire [15:0] t0_addr,
  input  wire        t0_rd,
  output wire [15:0] t0_rdat0, t0_rdat1, t0_rdat2, t0_rdat3,
  input  wire [15:0] t1_addr,
  input  wire        t1_rd,
  output wire [15:0] t1_rdat0, t1_rdat1, t1_rdat2, t1_rdat3,

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

  localparam [2:0] S_IDLE = 3'd0, S_FILL = 3'd1, S_CPY_RD = 3'd2, S_CPY_WR = 3'd3,
                   S_CPU_RD = 3'd4, S_CPU_RMW = 3'd5, S_CPU_WR = 3'd6;
  reg [2:0] st;

  // ------------------------------------------------------------------ the chip
  reg         p_req, p_we;
  reg  [17:0] p_addr;
  reg  [3:0]  p_len;
  wire        p_grant, p_done, p_rd_valid;
  wire [15:0] p_rd_data;
  wire [6:0]  p_idx_w;
  wire [3:0]  p_idx = p_idx_w[3:0];
  wire [15:0] p_wdata;
  wire [1:0]  p_wbe;

  reg rst_p = 1'b1;
  always @(posedge clk) rst_p <= 1'b0;

  pocket_psram_bus #(.CLEAR_BURSTS(16384)) u_chip (
    .clk(clk), .rst(rst_p),
    .req(p_req), .we(p_we), .addr(p_addr), .len_m1({3'd0, p_len}),
    .grant(p_grant), .done(p_done), .rd_valid(p_rd_valid), .rd_data(p_rd_data), .word_idx(p_idx_w),
    .wdata(p_wdata), .wbe(p_wbe),
    .ready(ready), .cal_fail(cal_fail), .rd_lat(rd_lat), .rd_ph(rd_ph), .wr_lat(wr_lat),
    .cram_run(cram_run), .cram_a(cram_a), .cram_dq_o(cram_dq_o), .cram_dq_oe(cram_dq_oe),
    .cram_dq_i(cram_dq_i), .cram_adv_n(cram_adv_n), .cram_cre(cram_cre), .cram_ce0_n(cram_ce0_n),
    .cram_oe_n(cram_oe_n), .cram_we_n(cram_we_n), .cram_ub_n(cram_ub_n), .cram_lb_n(cram_lb_n)
  );

  // ------------------------------------------------------------------ caches
  wire [9:0] row0 = t0_addr[15:6];
  wire [9:0] row1 = t1_addr[15:6];
  reg  [9:0] tag0, tag1;
  reg        valid0, valid1;
  reg        fill0, fill1, fill_active, fill_op;
  reg  [9:0] fill_row;
  reg  [3:0] fill_b;                           // {plane, burst}

  wire miss0 = t0_rd && (!valid0 || tag0 != row0);
  wire miss1 = t1_rd && (!valid1 || tag1 != row1);

  reg  [1:0]  cw_plane;
  reg  [5:0]  cw_col;
  reg  [9:0]  cw_row;
  reg  [15:0] cw_data;
  reg  [1:0]  cw_be;
  reg         cw_commit;

  wire [1:0]  w_plane = cw_commit ? cw_plane : fill_b[3:2];
  wire [5:0]  w_col   = cw_commit ? cw_col : {fill_b[1:0], p_idx};
  wire [15:0] w_data  = cw_commit ? cw_data : p_rd_data;
  wire [1:0]  w_be    = cw_commit ? cw_be : 2'b11;
  wire        w_fill0 = p_rd_valid && fill_op && fill0;
  wire        w_fill1 = p_rd_valid && fill_op && fill1;
  wire        w_cpu0  = cw_commit && valid0 && tag0 == cw_row;
  wire        w_cpu1  = cw_commit && valid1 && tag1 == cw_row;

  wire [15:0] q0 [0:3];
  wire [15:0] q1 [0:3];
  assign t0_rdat0 = q0[0]; assign t0_rdat1 = q0[1]; assign t0_rdat2 = q0[2]; assign t0_rdat3 = q0[3];
  assign t1_rdat0 = q1[0]; assign t1_rdat1 = q1[1]; assign t1_rdat2 = q1[2]; assign t1_rdat3 = q1[3];

  genvar g;
  generate for (g = 0; g < 4; g = g + 1) begin : planes
    pocket_vram_cache #(.AW(6)) u_t0 (
      .clk(clk), .we((w_fill0 || w_cpu0) && w_plane == 2'(g)), .be(w_be), .waddr(w_col),
      .wdata(w_data), .raddr(t0_addr[5:0]), .q(q0[g]));
    pocket_vram_cache #(.AW(6)) u_t1 (
      .clk(clk), .we((w_fill1 || w_cpu1) && w_plane == 2'(g)), .be(w_be), .waddr(w_col),
      .wdata(w_data), .raddr(t1_addr[5:0]), .q(q1[g]));
  end endgenerate

  // ---------------------------------------------------------------------- CPU
  wire cpu_req = cpu_rd || (|cpu_wr) || (|cpu_rmw);
  reg  cpu_done;
  assign cpu_ack = cpu_done && cpu_req;
  wire cpu_pending = cpu_req && !cpu_done;

  wire [1:0]  a_be     = (|cpu_rmw) ? cpu_rmw : cpu_wr;
  wire [15:0] a_lanes  = {{8{a_be[1]}}, {8{a_be[0]}}};
  wire [15:0] a_mask   = (|cpu_rmw) ? (cpu_rmwmask & a_lanes) : a_lanes;
  wire        a_direct = (a_mask == 16'hFFFF) || (a_mask == 16'hFF00) || (a_mask == 16'h00FF);

  // ---------------------------------------------------------------- raster copy
  reg        cpy_seen, cpy_pending, cpy_active;
  reg [10:0] cpy_src_l, cpy_dst_l;
  reg [3:0]  cpy_left;                         // planes still to do
  reg [1:0]  cpy_p;
  reg        cpy_half;                         // which 16 of the 32 words

  (* ramstyle = "MLAB, no_rw_check" *) reg [15:0] cpy_buf [0:31];
  wire [4:0] cpy_ix = {cpy_half, p_idx};
  wire [15:0] cpy_q = cpy_buf[cpy_ix];

  wire [1:0] cpy_next = cpy_left[0] ? 2'd0 : cpy_left[1] ? 2'd1 : cpy_left[2] ? 2'd2 : 2'd3;
  wire [3:0] cpy_rest = cpy_left & ~(4'b0001 << cpy_p);

  // ------------------------------------------------------------ the arbitration
  reg       cpu_turn;

  always @(posedge clk) if (p_rd_valid && st == S_CPY_RD) cpy_buf[cpy_ix] <= p_rd_data;

  assign p_wdata = (st == S_CPY_WR) ? cpy_q : cw_data;
  assign p_wbe   = (st == S_CPY_WR) ? 2'b11 : cw_be;

  always @(posedge clk) begin
    cw_commit <= 1'b0;
    if (p_grant) p_req <= 1'b0;
    if (!cpu_req) cpu_done <= 1'b0;

    if (!rstn) begin
      st          <= S_IDLE;
      p_req       <= 1'b0;
      valid0      <= 1'b0;
      valid1      <= 1'b0;
      fill_active <= 1'b0;
      fill_op     <= 1'b0;
      cpu_done    <= 1'b0;
      cpu_turn    <= 1'b0;
      cpy_seen    <= 1'b0;
      cpy_pending <= 1'b0;
      cpy_active  <= 1'b0;
      cpy_ack     <= 1'b0;
    end else begin
      if (!cpy_req) cpy_seen <= 1'b0;
      else if (!cpy_seen) begin
        cpy_seen    <= 1'b1;
        cpy_pending <= 1'b1;
        cpy_src_l   <= cpy_src;
        cpy_dst_l   <= cpy_dst;
        cpy_left    <= cpy_plane;
      end

      if (!fill_active && (miss0 || miss1)) begin
        fill_active <= 1'b1;
        fill_row    <= miss0 ? row0 : row1;
        fill_b      <= 4'd0;
        fill0       <= miss0;
        fill1       <= miss1 && (!miss0 || row1 == row0);
        if (miss0) begin tag0 <= row0; valid0 <= 1'b1; end
        if (miss1 && (!miss0 || row1 == row0)) begin tag1 <= row1; valid1 <= 1'b1; end
      end

      case (st)
        S_IDLE: begin
          fill_op <= 1'b0;
          if (cpu_pending && (cpu_turn || !(fill_active || cpy_active || cpy_pending))) begin
            cpu_turn <= 1'b0;
            p_req    <= 1'b1;
            p_len    <= 4'd0;
            p_addr   <= {cpu_addr[1:0], cpu_addr[17:2]};
            cw_plane <= cpu_addr[1:0];
            cw_row   <= cpu_addr[17:8];
            cw_col   <= cpu_addr[7:2];
            if (cpu_rd) begin
              p_we <= 1'b0;
              st   <= S_CPU_RD;
            end else if (a_direct) begin
              p_we    <= 1'b1;
              cw_data <= cpu_wdat;
              cw_be   <= {a_mask[15], a_mask[0]};
              st      <= S_CPU_WR;
            end else begin
              p_we <= 1'b0;
              st   <= S_CPU_RMW;
            end
          end else if (fill_active) begin
            cpu_turn <= 1'b1;
            fill_op  <= 1'b1;
            p_req    <= 1'b1;
            p_we     <= 1'b0;
            p_len    <= 4'd15;
            p_addr   <= {fill_b[3:2], fill_row, fill_b[1:0], 4'd0};
            st       <= S_FILL;
          end else if (cpy_pending && !cpy_active) begin
            cpy_pending <= 1'b0;
            if (cpy_left == 4'd0) cpy_ack <= ~cpy_ack;
            else begin
              cpy_active <= 1'b1;
              cpy_p      <= cpy_next;
              cpy_half   <= 1'b0;
            end
            if (valid0 && tag0 == cpy_dst_l[10:1]) valid0 <= 1'b0;
            if (valid1 && tag1 == cpy_dst_l[10:1]) valid1 <= 1'b0;
          end else if (cpy_active) begin
            cpu_turn <= 1'b1;
            p_req    <= 1'b1;
            p_we     <= 1'b0;
            p_len    <= 4'd15;
            p_addr   <= {cpy_p, cpy_src_l, cpy_half, 4'd0};
            st       <= S_CPY_RD;
          end
        end

        S_FILL: if (p_done) begin
          if (fill_b == 4'd15) fill_active <= 1'b0;
          fill_b <= fill_b + 4'd1;
          st     <= S_IDLE;
        end

        // sixteen words read, the same sixteen written, then the other half, then the next plane
        S_CPY_RD: if (p_done) begin
          p_req  <= 1'b1;
          p_we   <= 1'b1;
          p_addr <= {cpy_p, cpy_dst_l, cpy_half, 4'd0};
          st     <= S_CPY_WR;
        end

        S_CPY_WR: if (p_done) begin
          st <= S_IDLE;
          if (!cpy_half) cpy_half <= 1'b1;
          else begin
            cpy_half <= 1'b0;
            cpy_left[cpy_p] <= 1'b0;
            cpy_p <= cpy_rest[0] ? 2'd0 : cpy_rest[1] ? 2'd1 : cpy_rest[2] ? 2'd2 : 2'd3;
            if (cpy_rest == 4'd0) begin
              cpy_active <= 1'b0;
              cpy_ack    <= ~cpy_ack;
            end
          end
        end

        S_CPU_RD: begin
          if (p_rd_valid) cpu_rdat <= p_rd_data;
          if (p_done) begin
            cpu_done <= 1'b1;
            st       <= S_IDLE;
          end
        end

        S_CPU_RMW: begin
          if (p_rd_valid) cw_data <= (p_rd_data & ~a_mask) | (cpu_wdat & a_mask);
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
