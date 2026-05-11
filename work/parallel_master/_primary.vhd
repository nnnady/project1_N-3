library verilog;
use verilog.vl_types.all;
entity parallel_master is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        req_i           : in     vl_logic;
        addr_i          : in     vl_logic_vector(15 downto 0);
        wr_i            : in     vl_logic_vector(1 downto 0);
        wdata_i         : in     vl_logic_vector(31 downto 0);
        ext_ready_i     : in     vl_logic;
        ext_ack_i       : in     vl_logic;
        ext_rdata_i     : in     vl_logic_vector(15 downto 0);
        done_o          : out    vl_logic;
        word_done_o     : out    vl_logic;
        rdata_o         : out    vl_logic_vector(31 downto 0);
        ext_addr_o      : out    vl_logic_vector(15 downto 0);
        ext_cmd_o       : out    vl_logic_vector(1 downto 0);
        ext_data_o      : out    vl_logic_vector(15 downto 0);
        ext_stream_o    : out    vl_logic;
        ext_word_done_o : out    vl_logic;
        ext_tick_o      : out    vl_logic;
        high_phase_o    : out    vl_logic
    );
end parallel_master;
