// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket: one PSRAM chip as a stream of words, in synchronous bursts
//
// THE PART. AS1C8M16PL-70 (Alliance, CellularRAM 1.5 AD-MUX): the low sixteen address bits share
// the DQ pins and are latched by ADV#. Only die 0 is used, and only 512 KB of it.
//
// THE CLOCK. Everything here runs on one 40 MHz clock, and a burst moves a word a clock. The chip's
// clock leaves through a DDIO register outside this module, high while clk is low, so the chip's
// rising edge falls midway between two edges of clk: every pin changes 12.5 ns before the chip
// samples it and holds 12.5 ns after, against the part's 3 ns and 2 ns.
//
// READING. A word appears tACLK (9 ns) after the chip's rising edge and stays until 2 ns after the
// next, plus the round trip of the pins and board, which the boot measures: read data is captured on
// both edges of clk, so the sample point moves in steps of 12.5 ns and always lands in a window of
// about 18 ns. rd_ph picks the falling-edge sample.
//
// THE MODE. BCR = 0x5C1F, as on the Cave core: synchronous burst, fixed latency code 3 (four
// clocks, allowed up to 52 MHz), no wrap, continuous. With fixed latency the first word comes at the
// same clock every time, refresh collisions included, so WAIT isn't needed. A burst ends by taking
// CE# high, and stays well under the part's 4 us limit on CE# low.
//
// BOOT. After the part's 150 us power-up:
//   1. sixteen known words are written asynchronously (clock held low) at a test row, in the top
//      half of the die, far from anything the machine uses;
//   2. the BCR is written;
//   3. the test row is read back with each candidate latency and sample edge until all sixteen
//      words are right: rd_lat, rd_ph;
//   4. a second pattern is burst-written with each candidate write latency and read back: wr_lat;
//   5. CLEAR_BURSTS bursts of zeros from address 0; then `ready`.
// If no latency works, cal_fail is set and the port runs on the datasheet's figure. The overlay
// shows both latencies and the flag.
//
// THE PORT. Hold req, with we, addr and len_m1, until a one-clock grant. A write then takes wdata and
// wbe for word word_idx, read as the burst goes. A read gives rd_valid and rd_data, word word_idx. A
// one-clock done ends it; the next req may start then. Nothing is buffered here, so the only cost
// beyond the state machine is two 16-bit capture registers.

`default_nettype none

module pocket_psram_bus #(
  parameter real         CLOCK_MHZ    = 40.0125,
  parameter logic [15:0] BCR          = 16'h5C1F,
  parameter int unsigned LAT_DEF      = 4,        // the datasheet's reading of code 3
  parameter int unsigned CLEAR_BURSTS = 16384     // 16 words each: 512 KB
) (
  input  wire         clk,
  input  wire         rst,                        // power-on only

  input  wire         req,
  input  wire         we,
  input  wire [17:0]  addr,
  input  wire [3:0]   len_m1,
  output wire         grant,
  output wire         done,
  output wire         rd_valid,
  output wire [15:0]  rd_data,
  output wire [3:0]   word_idx,
  input  wire [15:0]  wdata,
  input  wire [1:0]   wbe,

  output reg          ready,
  output reg          cal_fail,
  output reg  [2:0]   rd_lat,
  output reg          rd_ph,
  output reg  [2:0]   wr_lat,

  output reg          cram_run,                   // the chip's clock runs (the DDIO's low phase data)
  output reg  [21:16] cram_a,
  output reg  [15:0]  cram_dq_o,
  output reg          cram_dq_oe,
  input  wire [15:0]  cram_dq_i,
  output reg          cram_adv_n,
  output reg          cram_cre,
  output reg          cram_ce0_n,
  output reg          cram_oe_n,
  output reg          cram_we_n,
  output reg          cram_ub_n,
  output reg          cram_lb_n
);

  // ----------------------------------------------------------------- capture
  reg [15:0] dq_r, dq_n;
  always @(posedge clk) dq_r <= cram_dq_i;
  always @(negedge clk) dq_n <= cram_dq_i;

  // -------------------------------------------------------------- operations
  localparam [2:0] O_NONE = 3'd0, O_AWR = 3'd1, O_BCR = 3'd2, O_RD = 3'd3, O_WR = 3'd4;
  reg [2:0]   op = O_NONE;
  reg [5:0]   n;                                  // device clocks (async: clocks of clk) into the op
  reg [17:0]  op_addr;
  reg         op_test;                            // the test rows, not the machine's memory
  reg [1:0]   op_src;                             // a write's data: 0 the port's, 1 test pattern, 2 zeros
  reg [15:0]  op_aw;                              // an asynchronous write's word
  reg [3:0]   op_cnt;                             // words - 1
  reg [2:0]   op_lat;
  reg         op_ph;
  reg         op_done, op_grant, op_ok;

  assign grant = op_grant;
  assign done  = op_done;

  wire [5:0] rd_k0   = {3'd0, op_lat} + 6'd2;     // the clock a read's word 0 is taken at
  wire [5:0] rd_last = rd_k0 + {2'd0, op_cnt};
  wire [5:0] wr_last = {3'd0, op_lat} + {2'd0, op_cnt};

  assign rd_valid = (op == O_RD) && (n >= rd_k0) && (n <= rd_last);
  assign rd_data  = op_ph ? dq_n : dq_r;
  assign word_idx = (op == O_RD) ? 4'(n - rd_k0) : 4'(n - {3'd0, op_lat});

  // ---------------------------------------------------------------- the boot
  localparam int unsigned T_PU = int'(CLOCK_MHZ * 160.0);    // > 150 us

  localparam [3:0] B_PU = 4'd0, B_SEED = 4'd1, B_BCR = 4'd2, B_RCAL = 4'd3, B_WCAL_W = 4'd4,
                   B_WCAL_R = 4'd5, B_CLEAR = 4'd6, B_RUN = 4'd7, B_CRE = 4'd8;
  reg [3:0]  boot = B_PU;
  reg [12:0] pu_cnt;
  reg [4:0]  seed_i;
  reg [2:0]  try_lat;
  reg        try_ph;
  reg [14:0] clr_n;

  function automatic [15:0] pat_a(input [3:0] i);            // the async seed
    pat_a = {i, ~i, 4'hA, i} ^ 16'h1234;
  endfunction
  function automatic [15:0] pat_b(input [3:0] i, input [2:0] l);  // a write try's pattern
    pat_b = {l, 1'b1, ~i, i, 4'h5} ^ 16'h0F0F;
  endfunction

  localparam [2:0] LAT_MIN = 3'd2, LAT_MAX = 3'd7;
  wire [15:0] w_word = (op_src == 2'd1) ? pat_b(word_idx, op_lat) :
                       (op_src == 2'd2) ? 16'd0 : wdata;
  wire [1:0]  w_be   = (op_src == 2'd0) ? wbe : 2'b11;
  wire [15:0] expect_w = (boot == B_RCAL) ? pat_a(word_idx) : pat_b(word_idx, try_lat);

  task automatic start(input [2:0] o, input [17:0] a, input t, input [1:0] src, input [15:0] aw,
                       input [3:0] cnt, input [2:0] l, input ph);
    op      <= o;
    n       <= 6'd0;
    op_addr <= a;
    op_test <= t;
    op_src  <= src;
    op_aw   <= aw;
    op_cnt  <= cnt;
    op_lat  <= l;
    op_ph   <= ph;
    op_ok   <= 1'b1;
  endtask

  always @(posedge clk) begin
    op_done  <= 1'b0;
    op_grant <= 1'b0;
    if (rd_valid && rd_data != expect_w) op_ok <= 1'b0;

    if (rst) begin
      cram_run   <= 1'b0;
      cram_adv_n <= 1'b1;
      cram_cre   <= 1'b0;
      cram_ce0_n <= 1'b1;
      cram_oe_n  <= 1'b1;
      cram_we_n  <= 1'b1;
      cram_ub_n  <= 1'b1;
      cram_lb_n  <= 1'b1;
      cram_dq_oe <= 1'b0;
      cram_dq_o  <= 16'd0;
      cram_a     <= 6'd0;
      op         <= O_NONE;
      boot       <= B_PU;
      pu_cnt     <= 13'd0;
      ready      <= 1'b0;
      cal_fail   <= 1'b0;
      rd_lat     <= 3'(LAT_DEF);
      rd_ph      <= 1'b0;
      wr_lat     <= 3'(LAT_DEF);
    end else begin
      // ---------------------------------------------- the operation in hand
      case (op)
        // An asynchronous write, the clock held low, counted in clocks of clk: ADV# low with the
        // address at 0 and high at 1, the data from 2, WE# and CE# high at 5 (125 ns of WE#, against
        // tWP 45 and tAW 70), the bus let go at 6. The BCR write is the same with CRE high around it
        // and the register's value on the address lines.
        O_AWR, O_BCR: begin
          n <= n + 6'd1;
          case (n)
          6'd0: begin
            cram_ce0_n <= 1'b0; cram_adv_n <= 1'b0; cram_we_n <= 1'b0;
            cram_oe_n  <= 1'b1; cram_ub_n  <= 1'b0; cram_lb_n <= 1'b0;
            cram_a     <= (op == O_BCR) ? 6'b00_10_00 : {op_test, 3'd0, op_addr[17:16]};
            cram_dq_o  <= (op == O_BCR) ? BCR : op_addr[15:0];
            cram_dq_oe <= 1'b1;
          end
          6'd1: cram_adv_n <= 1'b1;
          6'd2: cram_dq_o  <= op_aw;
          6'd5: begin cram_we_n <= 1'b1; cram_ce0_n <= 1'b1; end
          6'd6: begin
            cram_dq_oe <= 1'b0; cram_ub_n <= 1'b1; cram_lb_n <= 1'b1;
            cram_cre   <= 1'b0;
            op <= O_NONE; op_done <= 1'b1;
          end
          default: ;
          endcase
        end

        // A burst write, in device clocks: the address at 0 with ADV#, CE# and WE# low; word i at
        // op_lat + i with its byte enables; CE# high and the bus let go the clock after the last.
        O_WR: begin
          n <= n + 6'd1;
          if (n == 6'd0) begin
            cram_ce0_n <= 1'b0; cram_adv_n <= 1'b0; cram_we_n <= 1'b0;
            cram_oe_n  <= 1'b1; cram_ub_n  <= 1'b1; cram_lb_n <= 1'b1;
            cram_a     <= {op_test, 3'd0, op_addr[17:16]};
            cram_dq_o  <= op_addr[15:0];
            cram_dq_oe <= 1'b1;
          end else begin
            cram_adv_n <= 1'b1;
            if (n >= {3'd0, op_lat} && n <= wr_last) begin
              cram_dq_o <= w_word;
              cram_ub_n <= !w_be[1];
              cram_lb_n <= !w_be[0];
            end else if (n == wr_last + 6'd1) begin
              cram_ce0_n <= 1'b1; cram_we_n <= 1'b1;
              cram_ub_n  <= 1'b1; cram_lb_n <= 1'b1;
              cram_dq_oe <= 1'b0;
            end else if (n == wr_last + 6'd2) begin
              op <= O_NONE; op_done <= 1'b1;           // a clock of CE# high: tCBPH
            end
          end
        end

        // A burst read: the address at 0, OE# low and the bus let go at 1, words from rd_k0. CE# goes
        // high after the last, and one more clock lets the chip off the bus.
        O_RD: begin
          n <= n + 6'd1;
          if (n == 6'd0) begin
            cram_ce0_n <= 1'b0; cram_adv_n <= 1'b0; cram_we_n <= 1'b1;
            cram_oe_n  <= 1'b1; cram_ub_n  <= 1'b0; cram_lb_n <= 1'b0;
            cram_a     <= {op_test, 3'd0, op_addr[17:16]};
            cram_dq_o  <= op_addr[15:0];
            cram_dq_oe <= 1'b1;
          end else begin
            if (n == 6'd1) begin
              cram_adv_n <= 1'b1; cram_dq_oe <= 1'b0; cram_oe_n <= 1'b0;
            end
            if (n == rd_last) begin
              cram_ce0_n <= 1'b1; cram_oe_n <= 1'b1;
              cram_ub_n  <= 1'b1; cram_lb_n <= 1'b1;
            end
            if (n == rd_last + 6'd1) begin
              op <= O_NONE; op_done <= 1'b1;
            end
          end
        end

        default: ;
      endcase

      // ------------------------------------------------------------ the boot
      if (op == O_NONE && !op_done) case (boot)
        B_PU: begin
          if (pu_cnt == 13'(T_PU)) begin
            boot   <= B_SEED;
            seed_i <= 5'd0;
          end else pu_cnt <= pu_cnt + 13'd1;
        end
        B_SEED: begin
          if (seed_i == 5'd16) begin
            cram_cre <= 1'b1;                          // ahead of CE#, held through the write
            pu_cnt   <= 13'd0;
            boot     <= B_CRE;
          end else begin
            start(O_AWR, {14'd0, seed_i[3:0]}, 1'b1, 2'd0, pat_a(seed_i[3:0]), 4'd0, 3'd0, 1'b0);
            seed_i <= seed_i + 5'd1;
          end
        end
        B_CRE: begin
          if (pu_cnt == 13'd3) begin
            start(O_BCR, 18'd0, 1'b0, 2'd0, 16'd0, 4'd0, 3'd0, 1'b0);
            boot <= B_BCR;
          end else pu_cnt <= pu_cnt + 13'd1;
        end
        B_BCR: begin
          cram_run <= 1'b1;
          try_lat  <= LAT_MIN;
          try_ph   <= 1'b0;
          start(O_RD, 18'd0, 1'b1, 2'd0, 16'd0, 4'd15, LAT_MIN, 1'b0);
          boot     <= B_RCAL;
        end
        default: ;
      endcase

      if (op_done) case (boot)
        B_RCAL: begin
          if (op_ok) begin
            rd_lat  <= try_lat;
            rd_ph   <= try_ph;
            try_lat <= LAT_MIN;
            start(O_WR, 18'h10, 1'b1, 2'd1, 16'd0, 4'd15, LAT_MIN, 1'b0);
            boot    <= B_WCAL_W;
          end else if (try_lat == LAT_MAX && try_ph) begin
            cal_fail <= 1'b1;
            boot     <= B_CLEAR;
            clr_n    <= 15'd0;
          end else if (!try_ph) begin
            try_ph  <= 1'b1;
            start(O_RD, 18'd0, 1'b1, 2'd0, 16'd0, 4'd15, try_lat, 1'b1);
          end else begin
            try_lat <= try_lat + 3'd1;
            try_ph  <= 1'b0;
            start(O_RD, 18'd0, 1'b1, 2'd0, 16'd0, 4'd15, try_lat + 3'd1, 1'b0);
          end
        end
        B_WCAL_W: begin
          start(O_RD, 18'h10, 1'b1, 2'd0, 16'd0, 4'd15, rd_lat, rd_ph);
          boot <= B_WCAL_R;
        end
        B_WCAL_R: begin
          if (op_ok) begin
            wr_lat <= try_lat;
            boot   <= B_CLEAR;
            clr_n  <= 15'd0;
          end else if (try_lat == LAT_MAX) begin
            cal_fail <= 1'b1;
            boot     <= B_CLEAR;
            clr_n    <= 15'd0;
          end else begin
            try_lat <= try_lat + 3'd1;
            start(O_WR, 18'h10, 1'b1, 2'd1, 16'd0, 4'd15, try_lat + 3'd1, 1'b0);
            boot    <= B_WCAL_W;
          end
        end
        default: ;
      endcase

      // the memory cleared, a burst at a time
      if (boot == B_CLEAR && op == O_NONE && !op_done) begin
        if (clr_n == 15'(CLEAR_BURSTS)) begin
          boot  <= B_RUN;
          ready <= 1'b1;
        end else begin
          start(O_WR, {clr_n[13:0], 4'd0}, 1'b0, 2'd2, 16'd0, 4'd15, wr_lat, 1'b0);
          clr_n <= clr_n + 15'd1;
        end
      end

      // -------------------------------------------------------- the machine
      if (boot == B_RUN && op == O_NONE && !op_done && !op_grant && req) begin
        start(we ? O_WR : O_RD, addr, 1'b0, 2'd0, 16'd0, len_m1, we ? wr_lat : rd_lat, rd_ph);
        op_grant <= 1'b1;
      end
    end
  end

endmodule

`default_nettype wire
