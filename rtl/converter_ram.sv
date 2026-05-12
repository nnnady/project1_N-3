// ============================================================================
// Модуль: converter_ram (обновлённый)
// Простое двухпортовое ОЗУ (32 слова x 32 бита). При сбросе память обнуляется.
// ============================================================================
module converter_ram (
    input  logic        clk,
    input  logic        rst_n,      // сброс
    input  logic [4:0]  addr,
    input  logic [31:0] wdata,
    input  logic        wr_en,
    output logic [31:0] rdata
);
    logic [31:0] mem [0:31];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 32; i++) mem[i] <= 32'h0;
        end else if (wr_en) begin
            mem[addr] <= wdata;
        end
    end

    assign rdata = mem[addr];
endmodule