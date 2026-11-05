// SPDX-License-Identifier: GPL-3.0-or-later
// For the simulation: Altera's altsyncram as far as the board and the shell use it. One or two ports,
// each with a registered address; port B on clock0 or clock1 as its registers are set; port A as wide
// as port B or a whole multiple of it; byte enables on port A; an init file, read as plain hex from
// <init_file>.hex in the run's folder (made from the .mif by sim/gradius/translate.py).
//
// A read in the clock of a write to the same address follows read_during_write_mode: the same port
// gives the new word, the other port the old one. DONT_CARE on the other port gives the old one too,
// which a chip needn't: define RDW_RUBBISH to read such a collision as inverted bits, and see whether
// anything shows.
module altsyncram #(
  parameter address_aclr_a = "UNUSED", address_aclr_b = "NONE", address_reg_b = "CLOCK1",
  parameter byte_size = 8, byteena_aclr_a = "UNUSED", byteena_aclr_b = "NONE", byteena_reg_b = "CLOCK1",
  parameter clock_enable_core_a = "USE_INPUT_CLKEN", clock_enable_core_b = "USE_INPUT_CLKEN",
  parameter clock_enable_input_a = "NORMAL", clock_enable_input_b = "NORMAL",
  parameter clock_enable_output_a = "NORMAL", clock_enable_output_b = "NORMAL",
  parameter intended_device_family = "", ecc_pipeline_stage_enabled = "FALSE", enable_ecc = "FALSE",
  parameter implement_in_les = "OFF", indata_aclr_a = "UNUSED", indata_aclr_b = "NONE", indata_reg_b = "CLOCK1",
  parameter init_file = "UNUSED", init_file_layout = "PORT_A", maximum_depth = 0,
  parameter numwords_a = 0, numwords_b = 0, operation_mode = "BIDIR_DUAL_PORT",
  parameter outdata_aclr_a = "NONE", outdata_aclr_b = "NONE", outdata_reg_a = "UNREGISTERED", outdata_reg_b = "UNREGISTERED",
  parameter power_up_uninitialized = "FALSE", ram_block_type = "AUTO", rdcontrol_aclr_b = "NONE", rdcontrol_reg_b = "CLOCK1",
  parameter read_during_write_mode_mixed_ports = "DONT_CARE",
  parameter read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ", read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
  parameter stratixiv_m144k_allow_dual_clocks = "ON",
  parameter width_a = 8, width_b = 1, width_byteena_a = 1, width_byteena_b = 1, width_eccstatus = 3,
  parameter widthad_a = 1, widthad_b = 1, wrcontrol_aclr_a = "UNUSED", wrcontrol_aclr_b = "NONE", wrcontrol_wraddress_reg_b = "CLOCK1",
  parameter lpm_hint = "UNUSED", lpm_type = "altsyncram"
) (
  input  wire aclr0, aclr1,
  input  wire [widthad_a-1:0] address_a,
  input  wire [widthad_b-1:0] address_b,
  input  wire addressstall_a, addressstall_b,
  input  wire [width_byteena_a-1:0] byteena_a,
  input  wire [width_byteena_b-1:0] byteena_b,
  input  wire clock0, clock1,
  input  wire clocken0, clocken1, clocken2, clocken3,
  input  wire [width_a-1:0] data_a,
  input  wire [width_b-1:0] data_b,
  output wire [width_eccstatus-1:0] eccstatus,
  output wire [width_a-1:0] q_a,
  output wire [width_b-1:0] q_b,
  input  wire rden_a, rden_b,
  input  wire wren_a, wren_b
);
  localparam int WORDS = (numwords_a != 0) ? numwords_a : (1 << widthad_a);
  localparam bit IS_ROM = operation_mode == "ROM";
  localparam bit TWO = !IS_ROM;
  // port B's words to port A's, in the bits it can hold
  localparam int RATIO = (TWO && width_b > 0 && width_a > width_b) ? (width_a / width_b) : 1;
  localparam int LOGR  = $clog2(RATIO);
  localparam bit BMIXED = RATIO > 1;

  reg [width_a-1:0] mem [0:WORDS-1] /*verilator public_flat_rw*/;
  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = '0;
    if (init_file != "UNUSED") $readmemh({init_file, ".hex"}, mem);
  end
  assign eccstatus = '0;

  // ------------------------------------------------------------------ port A
  wire [width_a-1:0] be_mask;
  generate
    if (width_byteena_a > 1) begin : g_be
      genvar i;
      for (i = 0; i < width_byteena_a; i = i + 1) begin : g
        assign be_mask[i*byte_size +: byte_size] = {byte_size{byteena_a[i]}};
      end
    end else begin : g_nobe
      assign be_mask = {width_a{byteena_a[0]}};
    end
  endgenerate

  wire [width_a-1:0] merged_a = (mem[address_a] & ~be_mask) | (data_a & be_mask);
  reg  [width_a-1:0] qa_r;
  always @(posedge clock0) begin
    if (wren_a) begin
      mem[address_a] <= merged_a;
      qa_r <= merged_a;
    end else
      qa_r <= mem[address_a];
  end
  generate
    if (outdata_reg_a != "UNREGISTERED") begin : g_qa
      reg [width_a-1:0] qa_o;
      always @(posedge clock0) qa_o <= qa_r;
      assign q_a = qa_o;
    end else begin : g_qa
      assign q_a = qa_r;
    end
  endgenerate

  // ------------------------------------------------------------------ port B
  generate
    if (TWO) begin : g_b
      wire clk_b = (address_reg_b == "CLOCK0") ? clock0 : clock1;
      reg [width_b-1:0] qb_r;
        if (BMIXED) begin : g_mix
          wire [widthad_b-LOGR-1:0] word = address_b[widthad_b-1:LOGR];
          wire [LOGR-1:0] lane = address_b[LOGR-1:0];
          always @(posedge clk_b) begin
            if (wren_b) begin
              mem[word][lane*width_b +: width_b] <= data_b;
              qb_r <= data_b;
            end else
              qb_r <= mem[word][lane*width_b +: width_b];
          end
        end else begin : g_same
          always @(posedge clk_b) begin
            if (wren_b) begin
              mem[address_b] <= data_b;
              qb_r <= data_b;
            end else begin
`ifdef RDW_RUBBISH
              if (wren_a && address_a == address_b && read_during_write_mode_mixed_ports == "DONT_CARE")
                qb_r <= ~mem[address_b];
              else
`endif
              qb_r <= mem[address_b];
            end
          end
        end
        if (outdata_reg_b != "UNREGISTERED") begin : g_qb
          reg [width_b-1:0] qb_o;
          always @(posedge clk_b) qb_o <= qb_r;
          assign q_b = qb_o;
        end else begin : g_qb
          assign q_b = qb_r;
        end
    end else begin : g_b
      assign q_b = '0;
    end
  endgenerate
endmodule
