# The board alone, on the MiSTer core's clocks, with its exceptions re-rooted at X68K_top.
create_clock -name ramclk  -period 12.500 [get_ports ramclk]
create_clock -name vidclk  -period 12.500 [get_ports vidclk]
create_clock -name sysclk  -period 25.000 [get_ports sysclk]
create_clock -name fdcclk  -period 25.000 [get_ports fdcclk]
create_clock -name sndclk  -period 25.000 [get_ports sndclk]
create_clock -name scanclk -period 14.378 [get_ports scanclk]
derive_clock_uncertainty
set_clock_groups -asynchronous -group {scanclk} -group {ramclk vidclk sysclk fdcclk sndclk}
set_multicycle_path -from [get_clocks ramclk] -to [get_clocks sysclk] -start -setup 2
set_multicycle_path -from [get_clocks ramclk] -to [get_clocks sysclk] -start -hold 1
set_multicycle_path -from [get_clocks sysclk] -to [get_clocks ramclk] -end -setup 2
set_multicycle_path -from [get_clocks sysclk] -to [get_clocks ramclk] -end -hold 1
set_multicycle_path -from [get_clocks vidclk] -to [get_clocks sysclk] -start -setup 2
set_multicycle_path -from [get_clocks vidclk] -to [get_clocks sysclk] -start -hold 1
set_multicycle_path -from [get_clocks sysclk] -to [get_clocks vidclk] -end -setup 2
set_multicycle_path -from [get_clocks sysclk] -to [get_clocks vidclk] -end -hold 1
set_multicycle_path -from {DMA63450:DMA|*} -setup 2
set_multicycle_path -from {DMA63450:DMA|*} -hold 1
set_multicycle_path -from {fx68k:MPU|*} -setup 2
set_multicycle_path -from {fx68k:MPU|*} -hold 1
set_multicycle_path -to   {fx68k:MPU|*} -setup 2
set_multicycle_path -to   {fx68k:MPU|*} -hold 1
set_false_path -from {contcont:cont|contval*}
set_false_path -from {*~portb_we_reg} -to {*VLBUF*}
set_false_path -from {*~PORT_B_WRITE_ENABLE_REG} -to {*VLBUF*}
set_multicycle_path -to {sprram:spmem|bgvram:*} -setup 2
set_multicycle_path -to {sprram:spmem|bgvram:*} -hold 1
set_false_path -to {memcont:RAM|cachecont:CACHEC|cacheext:*|srclk}
