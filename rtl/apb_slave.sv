module apb_slave (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [15:0] paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr,

    input  logic        busy_i,
    output logic        start_req,
    output logic [1:0]  cmd_out,
    output logic [15:0] addr_out,
    output logic [31:0] data_out,
    output logic        data_written_o,
    input  logic [31:0] fsm_wdata_i,
    output logic        apb_rdata_pop
);
    logic [15:0] ADDR_REG;
    logic [31:0] DATA_REG;
    logic [1:0]  CMD_REG;
    logic        STATUS_REG;
    logic        CTRL_REG;

    logic apb_rdata_valid;
    logic apb_rdata_valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) apb_rdata_valid_r <= 1'b0;
        else        apb_rdata_valid_r <= apb_rdata_valid;
    end
    assign apb_rdata_pop = apb_rdata_valid && !apb_rdata_valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ADDR_REG   <= 16'b0;
            DATA_REG   <= 32'b0;
            CMD_REG    <= 2'b0;
            STATUS_REG <= 1'b0;
            CTRL_REG   <= 1'b0;
        end else if (psel && penable && pwrite && !pslverr) begin
            case (paddr[15:0])
                16'h0004: CTRL_REG <= pwdata[0];
                16'h0008: ADDR_REG <= pwdata[15:0];
                16'h000C: CMD_REG  <= pwdata[1:0];
                16'h0010: DATA_REG <= pwdata[31:0];
            endcase
        end
        STATUS_REG <= busy_i;
    end

    always_comb begin
        if (!pwrite) begin
            case (paddr[15:0])
                16'h0000: prdata = {31'b0, STATUS_REG};
                16'h0008: prdata = {16'b0, ADDR_REG};
                16'h000C: prdata = {30'b0, CMD_REG};
                16'h0010: prdata = fsm_wdata_i;
                default:  prdata = 32'b0;
            endcase
        end else
            prdata = 32'b0;
    end

    always_comb begin
        if (psel && penable) begin
            if ((pwrite && paddr == 16'h0000) ||
                (!pwrite && paddr == 16'h0004) ||
                !(paddr inside {16'h0000,16'h0004,16'h0008,16'h000C,16'h0010}))
                pslverr = 1'b1;
            else
                pslverr = 1'b0;
        end else
            pslverr = 1'b0;
    end

    assign pready = psel & penable;
    assign data_written_o = psel && penable && pwrite && (paddr == 16'h0010);
    assign apb_rdata_valid = !pwrite && penable && psel && (paddr == 16'h0010);
    assign cmd_out   = CMD_REG;
    assign start_req = CTRL_REG;
    assign addr_out  = ADDR_REG;
    assign data_out  = DATA_REG;
endmodule