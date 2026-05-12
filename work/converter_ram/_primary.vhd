library verilog;
use verilog.vl_types.all;
entity converter_ram is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        addr            : in     vl_logic_vector(4 downto 0);
        wdata           : in     vl_logic_vector(31 downto 0);
        wr_en           : in     vl_logic;
        rdata           : out    vl_logic_vector(31 downto 0)
    );
end converter_ram;
