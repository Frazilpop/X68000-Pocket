-- SPDX-License-Identifier: GPL-3.0-or-later
-- X68000 for Analogue Pocket: the machine's 16 KB of battery SRAM, as upstream's sramram with its
-- second port on a clock of its own, so the save slot reaches it straight from the bridge's clock.
-- The CPU's port is 16 bits with byte enables, the save's 8, on one block RAM per ten kilobits.
-- The init file is named from the project folder, as upstream names it.

LIBRARY ieee;
USE ieee.std_logic_1164.all;

LIBRARY altera_mf;
USE altera_mf.altera_mf_components.all;

ENTITY sramram_dc IS
	PORT
	(
		address_a		: IN STD_LOGIC_VECTOR (12 DOWNTO 0);
		address_b		: IN STD_LOGIC_VECTOR (13 DOWNTO 0);
		byteena_a		: IN STD_LOGIC_VECTOR (1 DOWNTO 0) :=  (OTHERS => '1');
		clock_a		: IN STD_LOGIC  := '1';
		clock_b		: IN STD_LOGIC  := '1';
		data_a		: IN STD_LOGIC_VECTOR (15 DOWNTO 0);
		data_b		: IN STD_LOGIC_VECTOR (7 DOWNTO 0);
		wren_a		: IN STD_LOGIC  := '0';
		wren_b		: IN STD_LOGIC  := '0';
		q_a		: OUT STD_LOGIC_VECTOR (15 DOWNTO 0);
		q_b		: OUT STD_LOGIC_VECTOR (7 DOWNTO 0)
	);
END sramram_dc;

ARCHITECTURE SYN OF sramram_dc IS
BEGIN
	altsyncram_component : altsyncram
	GENERIC MAP (
		address_reg_b => "CLOCK1",
		byte_size => 8,
		clock_enable_input_a => "BYPASS",
		clock_enable_input_b => "BYPASS",
		clock_enable_output_a => "BYPASS",
		clock_enable_output_b => "BYPASS",
		indata_reg_b => "CLOCK1",
		init_file => "rtl/diskemu/sramdefault.hex",
		init_file_layout => "PORT_A",
		intended_device_family => "Cyclone V",
		lpm_type => "altsyncram",
		numwords_a => 8192,
		numwords_b => 16384,
		operation_mode => "BIDIR_DUAL_PORT",
		outdata_aclr_a => "NONE",
		outdata_aclr_b => "NONE",
		outdata_reg_a => "UNREGISTERED",
		outdata_reg_b => "UNREGISTERED",
		power_up_uninitialized => "FALSE",
		read_during_write_mode_port_a => "NEW_DATA_NO_NBE_READ",
		read_during_write_mode_port_b => "NEW_DATA_NO_NBE_READ",
		widthad_a => 13,
		widthad_b => 14,
		width_a => 16,
		width_b => 8,
		width_byteena_a => 2,
		width_byteena_b => 1,
		wrcontrol_wraddress_reg_b => "CLOCK1"
	)
	PORT MAP (
		address_a => address_a,
		address_b => address_b,
		byteena_a => byteena_a,
		clock0 => clock_a,
		clock1 => clock_b,
		data_a => data_a,
		data_b => data_b,
		wren_a => wren_a,
		wren_b => wren_b,
		q_a => q_a,
		q_b => q_b
	);
END SYN;
