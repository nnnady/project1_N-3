library verilog;
use verilog.vl_types.all;
entity apb_slave is
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
        busy_i          : in     vl_logic;
        start_req       : out    vl_logic;
        cmd_out         : out    vl_logic_vector(1 downto 0);
        addr_out        : out    vl_logic_vector(15 downto 0);
        data_out        : out    vl_logic_vector(31 downto 0);
        data_written_o  : out    vl_logic;
        fsm_wdata_i     : in     vl_logic_vector(31 downto 0);
        apb_rdata_pop   : out    vl_logic
    );
end apb_slave;
