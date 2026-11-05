// SPDX-License-Identifier: GPL-3.0-or-later
// X68000 for Analogue Pocket: the one PLL
//
// From the 74.25 MHz reference (clk_74a), on a VCO of 800.25 MHz = 74.25 x 97 / 9, so every output is
// an integer divide of it and rises with the others. 80.025 and 40.0125 are 0.03 % fast of the
// machine's 80 and 40, with no fractional PLL to pay for.
//
//   clk80         80.025 MHz  /10  the SDRAM and its cache, the sprite engine, the scan-out
//   clk40         40.0125 MHz /20  the 68000 side, the renderer, the VRAMs, the FDC, the sound
//   clk_sdram_ps  80.025 MHz  /10, 180 degrees: forwarded to dram_clk
//   clk40_90      40.0125 MHz /20, 90 degrees: APF's DDR video clock
//
// There is no video PLL: the dot clocks are fractional enables on clk80 (x68k_native_crtc).

`default_nettype none

module pocket_pll_core (
    input  wire refclk,
    output wire clk80,
    output wire clk40,
    output wire clk_sdram_ps,
    output wire clk40_90,
    output wire locked
);
    altera_pll #(
        .fractional_vco_multiplier ("false"),
        .reference_clock_frequency ("74.25 MHz"),
        .operation_mode            ("normal"),
        .number_of_clocks          (4),
        .output_clock_frequency0   ("80.025000 MHz"),  .phase_shift0 ("0 ps"),    .duty_cycle0 (50),
        .output_clock_frequency1   ("40.012500 MHz"),  .phase_shift1 ("0 ps"),    .duty_cycle1 (50),
        .output_clock_frequency2   ("80.025000 MHz"),  .phase_shift2 ("6248 ps"), .duty_cycle2 (50),
        .output_clock_frequency3   ("40.012500 MHz"),  .phase_shift3 ("6248 ps"), .duty_cycle3 (50),
        .pll_type                  ("General"),
        .pll_subtype               ("General")
    ) altera_pll_i (
        .rst      (1'b0),
        .outclk   ({clk40_90, clk_sdram_ps, clk40, clk80}),
        .locked   (locked),
        .fboutclk (),
        .fbclk    (1'b0),
        .refclk   (refclk)
    );
endmodule

`default_nettype wire
