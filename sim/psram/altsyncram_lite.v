// SPDX-License-Identifier: GPL-3.0-or-later
// As much of Altera's altsyncram as pocket_vram_cache uses: a write port with byte enables, and a
// read port with a registered address and an unregistered output.
module altsyncram #(
  parameter address_aclr_b = "", address_reg_b = "", byte_size = 8, clock_enable_input_a = "",
  clock_enable_input_b = "", clock_enable_output_b = "", intended_device_family = "", lpm_type = "",
  numwords_a = 1, numwords_b = 1, operation_mode = "", outdata_aclr_b = "", outdata_reg_b = "",
  power_up_uninitialized = "", ram_block_type = "", read_during_write_mode_mixed_ports = "",
  widthad_a = 1, widthad_b = 1, width_a = 16, width_b = 16, width_byteena_a = 2
) (
  input  wire clock0,
  input  wire [widthad_a-1:0] address_a,
  input  wire [width_a-1:0] data_a,
  input  wire wren_a,
  input  wire [width_byteena_a-1:0] byteena_a,
  input  wire [widthad_b-1:0] address_b,
  output wire [width_b-1:0] q_b,
  input  wire aclr0, aclr1, addressstall_a, addressstall_b, byteena_b, clock1,
  input  wire clocken0, clocken1, clocken2, clocken3,
  input  wire [width_b-1:0] data_b,
  output wire eccstatus,
  output wire [width_a-1:0] q_a,
  input  wire rden_a, rden_b, wren_b
);
  reg [width_a-1:0] mem [0:numwords_a-1];
  reg [widthad_b-1:0] ra;
  always @(posedge clock0) begin
    if (wren_a && byteena_a[0]) mem[address_a][7:0]  <= data_a[7:0];
    if (wren_a && byteena_a[1]) mem[address_a][15:8] <= data_a[15:8];
    ra <= address_b;
  end
  assign q_b = mem[ra];
  assign q_a = 0;
  assign eccstatus = 0;
endmodule
