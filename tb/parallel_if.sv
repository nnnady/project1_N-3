interface parallel_if;
    logic        clk;
    logic        ext_ready;
    logic        ext_ack;
    logic [15:0] ext_rdata;
    logic [15:0] ext_addr;
    logic [1:0]  ext_cmd;
    logic [15:0] ext_wdata;
    logic        ext_done;
    logic        ext_word_done;
    logic        ext_stream;
    logic        ext_tick;
endinterface