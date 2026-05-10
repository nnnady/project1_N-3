module converter_ram (
    input  logic        clk,
    input  logic [4:0]  addr,
    input  logic [31:0] wdata,
    input  logic        wr_en,
    output logic [31:0] rdata
);
    logic [31:0] mem [0:31];
    always_ff @(posedge clk)
        if (wr_en) mem[addr] <= wdata;
    assign rdata = mem[addr];
endmodule