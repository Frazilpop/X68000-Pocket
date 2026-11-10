// SPDX-License-Identifier: GPL-3.0-or-later
// For the simulation: the Pocket's SDRAM, 16 bits, 4 banks, 8192 rows of 1024 words, as upstream's
// SDRAMC uses it: a mode word of CAS latency 2 and a full-page burst. Commands are taken on the rising
// edge of its own clock, which on this board is clk80's falling edge; a burst goes on until the next
// READ, WRITE, or precharge. Timing rules are checked, in clocks of 80 MHz, and any breach is counted.
//
// WHEN A WORD SHOWS. SDRAMC takes a READ's first word on the third rising edge of its clock after the
// edge that launched the READ: launched at E, in the cache from E + 3. So that's when it shows here,
// which leaves the word on the pins for the third edge, however that's met on a board: a chip whose
// clock is half a period behind has the word at its pins from about E + 1.9 to E + 2.7, and it's the
// path into the input register that carries it to E + 3. This model has no opinion on that path.
`default_nettype none
module sdram_model #(
  parameter int unsigned T_RCD = 2, T_RP = 2, T_RC = 6, T_RAS = 4, T_RRD = 2, T_WR = 2, T_MRD = 2,
  parameter int unsigned T_REFMAX = 4000   // clocks without a refresh before it's called a fault
) (
  input  wire         clk,
  input  wire         cke,
  input  wire         ras_n, cas_n, we_n,
  input  wire  [1:0]  ba,
  input  wire  [12:0] a,
  input  wire  [1:0]  dqm,
  input  wire  [15:0] dq_i,
  output reg   [15:0] dq_o,
  output reg          dq_oe,
  output int unsigned violations,
  output int unsigned reads_served,
  output int unsigned writes_served
);
  reg [15:0] mem [0:(1 << 25) - 1] /*verilator public_flat_rw*/;

  reg          row_open [0:3];
  reg  [12:0]  open_row [0:3];
  longint      t_act [0:3], t_pre [0:3], t_wr [0:3];
  longint      cyc, t_act_any, t_ref, t_mrs;
  reg          inited;
  reg  [3:0]   cl_mode;

  // the running burst
  reg          rd_on, wr_on;
  reg  [1:0]   b_ba;
  reg  [12:0]  b_row;
  reg  [9:0]   b_col;
  reg          rd_pend;
  reg  [15:0]  dq_1;
  reg          oe_1;
  reg  [24:0]  rd_pend_a;

  int unsigned reported;

  /* verilator lint_off BLKSEQ */
  task automatic flag(input string msg);
    violations = violations + 1;
    if (reported < 20) begin
      reported = reported + 1;
      $display("SDRAM @%0d: %s", cyc, msg);
    end
  endtask

  initial begin
    for (int i = 0; i < 4; i++) begin
      row_open[i] = 0; open_row[i] = 0; t_act[i] = -1000; t_pre[i] = -1000; t_wr[i] = -1000;
    end
    cyc = 0; t_act_any = -1000; t_ref = 0; t_mrs = -1000; inited = 0; cl_mode = 2;
    violations = 0; reported = 0; reads_served = 0; writes_served = 0;
    rd_on = 0; wr_on = 0; rd_pend = 0; dq_oe = 0; dq_o = 0; oe_1 = 0; dq_1 = 0;
  end

  wire [2:0] cmd = {ras_n, cas_n, we_n};
  localparam [2:0] C_NOP = 3'b111, C_ACT = 3'b011, C_READ = 3'b101, C_WRITE = 3'b100,
                   C_PRE = 3'b010, C_REF = 3'b001, C_MRS = 3'b000, C_BST = 3'b110;

  always @(posedge clk) begin
    cyc = cyc + 1;
    // a burst's next word, out or in
    dq_o  <= dq_1;
    dq_oe <= oe_1;
    oe_1  <= 1'b0;
    if (rd_pend) begin
      dq_1  <= mem[rd_pend_a];
      oe_1  <= 1'b1;
      reads_served = reads_served + 1;
`ifdef SDRAM_LOG
      if (reads_served < 60 || (rd_pend_a[24:1] >= 25'h0780000/2 && reads_served < 3000 && reads_served[5:0]==0)) $display("SD R %07x %04x @%0d", rd_pend_a, mem[rd_pend_a], cyc);
`endif
    end
    rd_pend = 1'b0;
    if (rd_on) begin
      rd_pend   = 1'b1;
      rd_pend_a = {b_ba, b_row, b_col};
      b_col     = b_col + 10'd1;
    end
    if (wr_on && cmd == C_NOP) begin
      if (!dqm[0]) mem[{b_ba, b_row, b_col}][7:0]  = dq_i[7:0];
      if (!dqm[1]) mem[{b_ba, b_row, b_col}][15:8] = dq_i[15:8];
      t_wr[b_ba] = cyc;
      writes_served = writes_served + 1;
`ifdef SDRAM_LOG
      if (writes_served < 400) $display("SD w %07x %04x dqm %b @%0d", {b_ba, b_row, b_col}, dq_i, dqm, cyc);
`endif
      b_col = b_col + 10'd1;
    end

    // A gap past T_REFMAX is flagged at the refresh that ends it, with its length; one that never ends,
    // every 100 times T_REFMAX.
    if (inited && (cyc - t_ref) > 100 * longint'(T_REFMAX)) begin
      flag($sformatf("no refresh for %0d clocks and counting", cyc - t_ref));
      t_ref = cyc;
    end

    if (cke && cyc > 16) case (cmd)
      C_MRS: begin
        for (int k = 0; k < 4; k++) if (row_open[k]) flag("MRS with a bank open");
        t_mrs = cyc; inited = 1; t_ref = cyc;
        if (a[6:4] != 3'd2 || a[2:0] != 3'd7) flag("a mode this model doesn't have");
      end
      C_ACT: begin
        if (row_open[ba]) flag("ACTIVATE on an open bank");
        if (cyc - t_pre[ba] < longint'(T_RP)) flag("tRP");
        if (cyc - t_act[ba] < longint'(T_RC)) flag("tRC");
        if (cyc - t_act_any < longint'(T_RRD)) flag("tRRD");
        row_open[ba] = 1; open_row[ba] = a; t_act[ba] = cyc; t_act_any = cyc;
      end
      C_READ, C_WRITE: begin
        if (!row_open[ba]) flag("READ or WRITE with no open row");
        else if (cyc - t_act[ba] < longint'(T_RCD)) flag("tRCD");
        b_ba = ba; b_row = open_row[ba]; b_col = a[9:0];
        rd_on = (cmd == C_READ);
        wr_on = (cmd == C_WRITE);
        if (rd_on) begin
          rd_pend   = 1'b1;
          rd_pend_a = {b_ba, b_row, b_col};
          b_col     = b_col + 10'd1;
          rd_on     = 1'b1;
        end else begin
          if (!dqm[0]) mem[{b_ba, b_row, b_col}][7:0]  = dq_i[7:0];
          if (!dqm[1]) mem[{b_ba, b_row, b_col}][15:8] = dq_i[15:8];
          t_wr[ba] = cyc;
          writes_served = writes_served + 1;
`ifdef SDRAM_LOG
          if (writes_served < 400) $display("SD W %07x %04x dqm %b @%0d", {b_ba, b_row, b_col}, dq_i, dqm, cyc);
`endif
          b_col = b_col + 10'd1;
        end
        if (a[10]) flag("auto-precharge, which this model doesn't have");
      end
      C_PRE: begin
        for (int k = 0; k < 4; k++) if (a[10] || k == int'(ba)) begin
          if (row_open[k]) begin
            if (cyc - t_act[k] < longint'(T_RAS)) flag("tRAS");
            if (cyc - t_wr[k] < longint'(T_WR)) flag("tWR");
            t_pre[k] = cyc;
          end
          row_open[k] = 0;
        end
        rd_on = 0; wr_on = 0;
      end
      C_REF: begin
        for (int k = 0; k < 4; k++) if (row_open[k]) flag("REFRESH with a bank open");
        if (inited && (cyc - t_ref) > longint'(T_REFMAX)) flag($sformatf("no refresh in time: %0d clocks since the last", cyc - t_ref));
        t_ref = cyc;
      end
      C_BST: begin rd_on = 0; wr_on = 0; end
      default: ;
    endcase
  end
  /* verilator lint_on BLKSEQ */
endmodule
`default_nettype wire
