# X68000 for Analogue Pocket: core timing constraints
#
# Read by apf/apf_constraints.sdc (Analogue's, unmodified) after it has created clk_74a, clk_74b and
# bridge_spiclk and run derive_pll_clocks. Not listed in ap_core.qsf, so it is applied once.

derive_clock_uncertainty

# ------------------------------------------------------------------ clocks
#
# The PLL's output counters, by the path derive_pll_clocks gives them. Renaming any level silently
# breaks every line below, so each is checked.
set pll {ic|u_pll_core|altera_pll_i}
set clk80    [get_clocks -nowarn "${pll}|general\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk40    [get_clocks -nowarn "${pll}|general\[1\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set sdram_ps [get_clocks -nowarn "${pll}|general\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"]
set clk40_90 [get_clocks -nowarn "${pll}|general\[3\].gpll~PLL_OUTPUT_COUNTER|divclk"]

foreach {name c} [list clk80 $clk80 clk40 $clk40 sdram_ps $sdram_ps clk40_90 $clk40_90] {
    if {[get_collection_size $c] == 0} {
        post_message -type error "core_constraints.sdc: PLL output '$name' not found. The constraints below would be no-ops; fix the path."
    }
}

# The SDRAM clock as the device sees it: clk_sdram_ps through a DDIO output register.
create_generated_clock -name dram_clk_pin \
    -source [get_pins "${pll}|general\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"] \
    [get_ports {dram_clk}]

# ---------------------------------------------------------- clock groups
#
# clk_74a (bridge, pad bus, I2S, the save slot) is the PLL's reference but is treated as unrelated to
# its outputs: every path between them crosses through a synchroniser, a dcfifo or a dual-clock RAM.
set_clock_groups -asynchronous \
    -group [get_clocks {clk_74a}] \
    -group [get_clocks {clk_74b}] \
    -group [get_clocks {bridge_spiclk}] \
    -group [add_to_collection [get_clocks "${pll}|*"] [get_clocks {dram_clk_pin}]]

# Settled long before they're read, and said so in core_top.
set_false_path -from [get_registers {*|size0_74[*] *|size1_74[*] *|sysrtc_74[*]}] -to $clk40

# ---------------------------------------------------- the machine's 80 and 40 MHz
#
# Upstream's: clk80 and clk40 rise together, and what crosses between them is held for more than a
# cycle by the memory controller's handshakes.
set_multicycle_path -from $clk80 -to $clk40 -start -setup 2
set_multicycle_path -from $clk80 -to $clk40 -start -hold 1
set_multicycle_path -from $clk40 -to $clk80 -end -setup 2
set_multicycle_path -from $clk40 -to $clk80 -end -hold 1

# But not these, which move every dot and have only the half-period they look to have:
#   the renderer's dot address into the sprite line buffers, and its dot back out;
#   the scan-out's held pixel into clk40, and the renderer's HCOMP into the sprite engine.
set spr_buf {*|spritec:sprite|sline:*}
set_multicycle_path -setup -end 1 -from [get_keepers {*|vidcont:*|haddr[*]}] -to [get_keepers "${spr_buf}|*"]
set_multicycle_path -hold -end 0  -from [get_keepers {*|vidcont:*|haddr[*]}] -to [get_keepers "${spr_buf}|*"]
set_multicycle_path -setup -start 1 -from [get_keepers "${spr_buf}|*"] -to $clk40
set_multicycle_path -hold -start 0  -from [get_keepers "${spr_buf}|*"] -to $clk40
set_multicycle_path -setup -start 1 -from [get_keepers {*|u_scanout|h_*}] -to [get_keepers {*|u_scanout|s_*}]
set_multicycle_path -hold -start 0  -from [get_keepers {*|u_scanout|h_*}] -to [get_keepers {*|u_scanout|s_*}]

# ---------------------------------------------------- the machine's own exceptions
#
# Upstream's, re-rooted. The DMA and the 68000 work on enables, a step in four clocks at the least.
set_multicycle_path -from {*|DMA63450:DMA|*} -setup 2
set_multicycle_path -from {*|DMA63450:DMA|*} -hold 1
set_multicycle_path -from {*|fx68k:MPU|*} -setup 2
set_multicycle_path -from {*|fx68k:MPU|*} -hold 1
set_multicycle_path -to   {*|fx68k:MPU|*} -setup 2
set_multicycle_path -to   {*|fx68k:MPU|*} -hold 1
set_false_path -from {*|contcont:cont|contval*}
set_false_path -from {*~portb_we_reg} -to {*VLBUF*}
set_multicycle_path -to {*|sprram:spmem|bgvram:*} -setup 2
set_multicycle_path -to {*|sprram:spmem|bgvram:*} -hold 1
set_false_path -to {*|memcont:RAM|cachecont:CACHEC|cacheext:*|srclk}

# The line number and the sprites' vertical origin change at hcomp, and the sprite engine reads nothing
# by them until the second clock of clk80 after it.
foreach from {{*|vidcont:*|vaddr[*]} {*|sprregs:spreg|vdisp_vid[*]}} {
    foreach to {{*|spritec:sprite|*} {*|sprram:spmem|*}} {
        set_multicycle_path -setup -end 2 -from [get_keepers $from] -to [get_keepers $to]
        set_multicycle_path -hold -end 1  -from [get_keepers $from] -to [get_keepers $to]
    }
}

# ------------------------------------------------------------------ SDRAM
#
# AS4C32M16MSA-6 (1.8 V mobile SDR), CL = 2 as SDRAMC programs it. Figures from the -6 grade of the
# family's sheet: command and data setup 2.0 ns, hold 1.0; access from clock 6.0 max, hold 2.5 min.
# 0.2 ns allowed for a flight each way.
set sdr_trace 0.2

set sdr_out [get_ports {dram_a[*] dram_ba[*] dram_dqm[*] dram_ras_n dram_cas_n dram_we_n dram_dq[*]}]
set_output_delay -clock dram_clk_pin -max [expr {2.0 + $sdr_trace}] $sdr_out
set_output_delay -clock dram_clk_pin -min [expr {-1.0}]             $sdr_out

# Read data is latched one full cycle after the default edge, and read back at the Pocket by the first
# boot: this keeps the input path timed the same way from one fit to the next.
set_input_delay -clock dram_clk_pin -max [expr {6.0 + 2 * $sdr_trace}] [get_ports {dram_dq[*]}]
set_input_delay -clock dram_clk_pin -min 2.5                           [get_ports {dram_dq[*]}]
set_multicycle_path -from [get_clocks {dram_clk_pin}] -to $clk80 -setup -end 2
set_multicycle_path -from [get_clocks {dram_clk_pin}] -to $clk80 -hold  -end 1

set_false_path -to [get_ports {dram_cke}]

# ------------------------------------------------------------ PSRAM, SRAM
#
# The PSRAMs are clocked at 40 MHz through DDIO cells: every pin changes 12.5 ns before the part samples
# it on its clock's rise and holds 12.5 ns after, against the part's 3 ns setup and 2 ns hold, and read
# data is taken on both edges of clk40, the boot choosing which. Those margins are half-periods, not
# picoseconds, and the fitter is told not to second-guess them; the latencies are measured on the part
# at power-up and shown on the overlay. The SRAM isn't used.
set_false_path -to   [get_ports {cram0_* cram1_*}]
set_false_path -from [get_ports {cram0_dq[*] cram1_dq[*] cram0_wait cram1_wait}]
set_false_path -to   [get_ports {sram_a[*] sram_dq[*] sram_oe_n sram_we_n sram_ub_n sram_lb_n}]
set_false_path -from [get_ports {sram_dq[*]}]
