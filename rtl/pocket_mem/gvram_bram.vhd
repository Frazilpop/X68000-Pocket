-- Stands in for upstream's GVRAM block RAM until the PSRAM port takes its place: 256 KB of it
-- does not fit in this chip's M10K. It stores nothing. Each read path is registers
-- that depend on their inputs, so synthesis keeps gvram_ctrl and the fit counts it.
library ieee;
use ieee.std_logic_1164.all;

entity gvram_bram is
port(
	c0_address_a : in std_logic_vector(15 downto 0);
	c0_data_a : in std_logic_vector(15 downto 0);
	c0_wren_a : in std_logic := '0';
	c0_nibbleena_a : in std_logic_vector(3 downto 0) := "1111";
	c0_q_a : out std_logic_vector(15 downto 0);
	c0_address_b : in std_logic_vector(15 downto 0);
	c0_q_b : out std_logic_vector(15 downto 0);
	c1_address_a : in std_logic_vector(15 downto 0);
	c1_data_a : in std_logic_vector(15 downto 0);
	c1_wren_a : in std_logic := '0';
	c1_nibbleena_a : in std_logic_vector(3 downto 0) := "1111";
	c1_q_a : out std_logic_vector(15 downto 0);
	c1_address_b : in std_logic_vector(15 downto 0);
	c1_q_b : out std_logic_vector(15 downto 0);
	clock_a : in std_logic;
	clock_b : in std_logic
);
end gvram_bram;

architecture stub of gvram_bram is
	signal a, b : std_logic_vector(15 downto 0);
begin
	process(clock_a) begin
		if rising_edge(clock_a) then
			a <= c0_data_a xor c1_data_a xor c0_address_a xor c1_address_a;
		end if;
	end process;
	process(clock_b) begin
		if rising_edge(clock_b) then
			b <= c0_address_b xor c1_address_b xor a;
		end if;
	end process;
	c0_q_a <= a;
	c1_q_a <= not a;
	c0_q_b <= b;
	c1_q_b <= not b;
end stub;
