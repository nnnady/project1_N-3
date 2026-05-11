library verilog;
use verilog.vl_types.all;
entity converter_top is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        psel            : in     vl_logic;
        penable         : in     vl_logic;
        pwrite          : in     vl_logic;
        paddr           : in     vl_logic_vector(15 downto 0);
        pwdata          : in     vl_logic_vector(31 downto 0);
        prdata          : out    vl_logic_vector(31 downto 0);
        pready          : out    vl_logic;
        pslverr         : out    vl_logic;
        ext_ready_i     : in     vl_logic;
        ext_ack_i       : in     vl_logic;
        ext_rdata_i     : in     vl_logic_vector(15 downto 0);
        ext_addr_o      : out    vl_logic_vector(15 downto 0);
        ext_cmd_o       : out    vl_logic_vector(1 downto 0);
        ext_data_o      : out    vl_logic_vector(15 downto 0);
        ext_stream_o    : out    vl_logic;
        ext_word_done_o : out    vl_logic;
        ext_tick_o      : out    vl_logic;
        ext_half_o      : out    vl_logic
    );
end converter_top;
