library verilog;
use verilog.vl_types.all;
entity converter_fsm is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        apb_addr_i      : in     vl_logic_vector(15 downto 0);
        apb_wdata_i     : in     vl_logic_vector(31 downto 0);
        apb_cmd_i       : in     vl_logic_vector(1 downto 0);
        apb_start_req   : in     vl_logic;
        apb_data_written_o: in     vl_logic;
        apb_rdata_pop   : in     vl_logic;
        apb_busy_o      : out    vl_logic;
        apb_rdata_o     : out    vl_logic_vector(31 downto 0);
        parallel_done_i : in     vl_logic;
        parallel_word_done_i: in     vl_logic;
        parallel_rdata_i: in     vl_logic_vector(31 downto 0);
        parallel_req_o  : out    vl_logic;
        parallel_addr_o : out    vl_logic_vector(15 downto 0);
        parallel_cmd_o  : out    vl_logic_vector(1 downto 0);
        parallel_wdata_o: out    vl_logic_vector(31 downto 0);
        ram_rdata       : in     vl_logic_vector(31 downto 0);
        ram_addr        : out    vl_logic_vector(4 downto 0);
        ram_wdata       : out    vl_logic_vector(31 downto 0);
        ram_wr_en       : out    vl_logic
    );
end converter_fsm;
