interface apb_if;
    logic        clk;
    logic        rst_n;
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [15:0] paddr;
    logic [31:0] pwdata;
    logic [31:0] prdata;
    logic        pready;
    logic        pslverr;
endinterface
//cd C:/altera/13.0sp1/project1_N=3