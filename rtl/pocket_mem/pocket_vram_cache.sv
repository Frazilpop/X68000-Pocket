// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket: a line cache of 16-bit words with byte enables. One block RAM, read
// with a registered address and an unregistered output, as upstream's CACHEMEMWN; the byte enables
// let the CPU's writes go through to a cached row rather than throwing the row away.

`default_nettype none

module pocket_vram_cache #(
  parameter int unsigned AW = 9
) (
  input  wire          clk,
  input  wire          we,
  input  wire [1:0]    be,
  input  wire [AW-1:0] waddr,
  input  wire [15:0]   wdata,
  input  wire [AW-1:0] raddr,
  output wire [15:0]   q
);
  altsyncram #(
    .address_aclr_b                     ("NONE"),
    .address_reg_b                      ("CLOCK0"),
    .byte_size                          (8),
    .clock_enable_input_a               ("BYPASS"),
    .clock_enable_input_b               ("BYPASS"),
    .clock_enable_output_b              ("BYPASS"),
    .intended_device_family             ("Cyclone V"),
    .lpm_type                           ("altsyncram"),
    .numwords_a                         (1 << AW),
    .numwords_b                         (1 << AW),
    .operation_mode                     ("DUAL_PORT"),
    .outdata_aclr_b                     ("NONE"),
    .outdata_reg_b                      ("UNREGISTERED"),
    .power_up_uninitialized             ("FALSE"),
    .ram_block_type                     ("M10K"),
    .read_during_write_mode_mixed_ports ("DONT_CARE"),
    .widthad_a                          (AW),
    .widthad_b                          (AW),
    .width_a                            (16),
    .width_b                            (16),
    .width_byteena_a                    (2)
  ) ram (
    .clock0    (clk),
    .address_a (waddr),
    .data_a    (wdata),
    .wren_a    (we),
    .byteena_a (be),
    .address_b (raddr),
    .q_b       (q),
    // unused
    .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0), .byteena_b(1'b1),
    .clock1(1'b1), .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
    .data_b({16{1'b1}}), .eccstatus(), .q_a(), .rden_a(1'b1), .rden_b(1'b1), .wren_b(1'b0)
  );
endmodule

`default_nettype wire
