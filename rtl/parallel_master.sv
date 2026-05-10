module parallel_master (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        req_i,
    input  logic [15:0] addr_i,
    input  logic [1:0]  wr_i,
    input  logic [31:0] wdata_i,
    input  logic        ext_ready_i,
    input  logic        ext_ack_i,
    input  logic [15:0] ext_rdata_i,
    output logic        done_o,
    output logic        word_done_o,
    output logic [31:0] rdata_o,
    output logic [15:0] ext_addr_o,
    output logic [1:0]  ext_cmd_o,
    output logic [15:0] ext_data_o,
    output logic        ext_stream_o,
    output logic        ext_word_done_o,
    output logic        ext_tick_o
);
    typedef enum logic [2:0] { IDLE, ADDR_PHASE, DATA_LOW, DATA_HIGH, WAIT_ACK } state_t;

    logic [1:0]  word_cnt;
    logic        stream_mode;
    state_t      state;
    logic [2:0]  div_cnt;
    logic        tick;
    logic [15:0] data_low;

    assign ext_tick_o      = tick;
    assign ext_word_done_o = word_done_o;
    assign ext_stream_o    = wr_i[1];

    // ƒелитель на 3
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 3'b0;
            tick    <= 1'b0;
        end else begin
            div_cnt <= (div_cnt == 3'd2) ? 3'b0 : div_cnt + 1'b1;
            tick    <= (div_cnt == 3'd2);
        end
    end

    // ≈динственный синхронный процесс, управл€ющий всеми регистрами и выходами
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            word_cnt    <= 2'b0;
            stream_mode <= 1'b0;
            done_o      <= 1'b0;
            word_done_o <= 1'b0;
            rdata_o     <= 32'b0;
            ext_addr_o  <= 16'b0;
            ext_cmd_o   <= 2'b00;
            ext_data_o  <= 16'b0;
            data_low    <= 16'b0;
        end else if (tick) begin
            done_o      <= 1'b0;
            word_done_o <= 1'b0;
            case (state)
                IDLE: begin
                    ext_cmd_o  <= 2'b00;
                    ext_data_o <= 16'b0;
                    if (req_i) begin
                        stream_mode <= wr_i[1];
                        word_cnt    <= 2'b0;
                        state       <= ADDR_PHASE;
                    end
                end

                ADDR_PHASE: begin
                    ext_addr_o <= addr_i;
                    ext_cmd_o  <= 2'b01;
                    if (ext_ready_i) begin
                        if (wr_i[0]) begin
                            data_low   <= wdata_i[15:0];
                            ext_data_o <= wdata_i[15:0];
                            ext_cmd_o  <= 2'b11;  // WRITE
                            state      <= DATA_HIGH;
                        end else begin
                            ext_cmd_o  <= 2'b10;  // READ
                            state      <= DATA_LOW;
                        end
                    end
                end

                DATA_LOW: begin
                    ext_addr_o <= addr_i;
                    ext_cmd_o  <= 2'b10;
                    if (ext_ready_i) begin
                        data_low   <= ext_rdata_i;
                        state      <= DATA_HIGH;
                    end
                end

                DATA_HIGH: begin
                    ext_addr_o <= addr_i;
                    if (wr_i[0]) begin
                        ext_data_o <= wdata_i[31:16];
                        ext_cmd_o  <= 2'b11;
                        state <= WAIT_ACK;
                    end else begin
                        ext_cmd_o  <= 2'b10;
                        if (ext_ready_i) begin
                            rdata_o   <= {ext_rdata_i, data_low};
                            state     <= WAIT_ACK;
                        end
                    end
                end

                WAIT_ACK: begin
                    ext_addr_o  <= addr_i;
                    ext_cmd_o   <= wr_i[0] ? 2'b11 : 2'b10;
                    word_done_o <= 1'b1;
                    if (ext_ack_i) begin
                        word_done_o <= 1'b0;
                        if (stream_mode && (word_cnt < 2'd3)) begin
                            word_cnt <= word_cnt + 1'b1;
                            state    <= ADDR_PHASE;
                        end else begin
                            word_cnt <= 2'b0;
                            done_o   <= 1'b1;
                            state    <= IDLE;
                        end
                    end
                end

                default: begin
                    state      <= IDLE;
                    ext_cmd_o  <= 2'b00;
                    ext_data_o <= 16'b0;
                end
            endcase
        end
    end
endmodule