module converter_fsm (
    input  logic        clk, rst_n,
    input  logic [15:0] apb_addr_i,
    input  logic [31:0] apb_wdata_i,
    input  logic [1:0]  apb_cmd_i,
    input  logic        apb_start_req,
    input  logic        apb_data_written_o,
    input  logic        apb_rdata_pop,
    output logic        apb_busy_o,
    output logic [31:0] apb_rdata_o,
    input  logic        parallel_done_i,
    input  logic        parallel_word_done_i,
    input  logic [31:0] parallel_rdata_i,
    output logic        parallel_req_o,
    output logic [15:0] parallel_addr_o,
    output logic [1:0]  parallel_cmd_o,
    output logic [31:0] parallel_wdata_o,
    input  logic [31:0] ram_rdata,
    output logic [4:0]  ram_addr,
    output logic [31:0] ram_wdata,
    output logic        ram_wr_en
);
    typedef enum logic [3:0] {
        IDLE, RAM_STREAM_WRITE, RAM_STREAM_READ_ADDR, RAM_STREAM_READ_DATA,
        EXT_SINGLE_HANDLE, EXT_STREAM_PREPARE, EXT_STREAM_HANDLE,
        EXT_STREAM_WAIT, EXT_STREAM_WAIT_ACK, DONE
    } state_t;

    state_t state, next_state_after_ack;
    logic [1:0] word_cnt, load_cnt, unload_cnt;
    logic [31:0] rdata_reg;

    // Преобразование APB команды в {stream, write}
    logic [1:0] cmd_int;
    always_comb
        case (apb_cmd_i)
            2'b10:   cmd_int = 2'b11;   // потоковая запись
            2'b11:   cmd_int = 2'b10;   // потоковое чтение
            default: cmd_int = apb_cmd_i;
        endcase

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            word_cnt   <= 2'b0;
            load_cnt   <= 2'b0;
            unload_cnt <= 2'b0;
            rdata_reg  <= 32'b0;
        end else begin
            // Значения по умолчанию (большинство сигналов НЕ обнуляется, чтобы сохранять удержание)
            apb_busy_o      <= 1'b0;
            apb_rdata_o     <= rdata_reg;
            ram_wr_en       <= 1'b0;   // явно сбрасываем, чтобы не было ложных записей

            case (state)
                IDLE: begin
                    parallel_req_o   <= 1'b0;
                    parallel_cmd_o   <= 2'b00;
                    parallel_addr_o  <= 16'b0;
                    parallel_wdata_o <= 32'b0;
                    ram_addr         <= 5'b0;
                    ram_wdata        <= 32'b0;
                    next_state_after_ack <= IDLE;

                    if (apb_data_written_o) begin
                        state <= RAM_STREAM_WRITE;
                    end else if (apb_start_req) begin
                        case (apb_cmd_i)
                            2'b00, 2'b01: state <= EXT_SINGLE_HANDLE;
                            2'b10, 2'b11: begin
                                word_cnt   <= 2'b0;
                                load_cnt   <= 2'b0;   // <-- СБРОС СЧЕТЧИКОВ
                                unload_cnt <= 2'b0;
                                state <= EXT_STREAM_PREPARE;
                            end
                            default: state <= IDLE;
                        endcase
                    end
                end

                RAM_STREAM_WRITE: begin
                    ram_addr  <= apb_addr_i[4:0] + load_cnt;
                    ram_wdata <= apb_wdata_i;
                    ram_wr_en <= 1'b1;
                    load_cnt  <= load_cnt + 1'b1;
                    state     <= IDLE;
                end

                RAM_STREAM_READ_ADDR: begin
                    ram_addr <= apb_addr_i[4:0] + unload_cnt;
                    state    <= RAM_STREAM_READ_DATA;
                end

                RAM_STREAM_READ_DATA: begin
                    apb_rdata_o <= ram_rdata;
                    if (apb_rdata_pop) begin
                        rdata_reg <= ram_rdata;
                        if (unload_cnt == 2'd3) begin
                            unload_cnt <= 2'd0;
                            state      <= DONE;
                        end else begin
                            unload_cnt <= unload_cnt + 1'b1;
                            state      <= RAM_STREAM_READ_ADDR;
                        end
                    end
                end

                EXT_SINGLE_HANDLE: begin
                    apb_busy_o     <= 1'b1;
                    parallel_req_o <= 1'b1;
                    parallel_addr_o<= apb_addr_i;
                    if (cmd_int[0]) begin
                        parallel_cmd_o   <= cmd_int;
                        parallel_wdata_o <= apb_wdata_i;
                    end else begin
                        parallel_cmd_o   <= cmd_int;
                    end
                    if (parallel_done_i) begin
                        parallel_req_o <= 1'b0;
                        if (!cmd_int[0]) begin
                            rdata_reg <= parallel_rdata_i;
                            apb_rdata_o <= parallel_rdata_i;
                        end
                        state <= DONE;
                    end
                end

                EXT_STREAM_PREPARE: begin
                    apb_busy_o      <= 1'b1;
                    parallel_addr_o <= apb_addr_i + word_cnt;
                    ram_addr        <= apb_addr_i[4:0] + word_cnt;   // готовим адрес ОЗУ
                    state           <= EXT_STREAM_HANDLE;
                end

                EXT_STREAM_HANDLE: begin
                    apb_busy_o      <= 1'b1;
                    parallel_req_o  <= 1'b1;
                    parallel_cmd_o  <= cmd_int;
                    parallel_addr_o <= apb_addr_i + word_cnt;
                    if (cmd_int[0])
                        parallel_wdata_o <= ram_rdata;

                    if (parallel_word_done_i) begin
                        if (!cmd_int[0]) begin   // чтение: записываем в ОЗУ немедленно
                            ram_wr_en <= 1'b1;
                            ram_addr  <= apb_addr_i[4:0] + word_cnt;
                            ram_wdata <= parallel_rdata_i;
                        end
                        if (word_cnt == 2'd3)
                            next_state_after_ack <= EXT_STREAM_WAIT;
                        else begin
                            word_cnt <= word_cnt + 1'b1;
                            next_state_after_ack <= EXT_STREAM_PREPARE;
                        end
                        state <= EXT_STREAM_WAIT_ACK;
                    end
                end

                EXT_STREAM_WAIT: begin
                    if (parallel_done_i) begin
                        parallel_req_o <= 1'b0;
                        if (!cmd_int[0]) begin
                            unload_cnt <= 2'd0;
                            state <= RAM_STREAM_READ_ADDR;
                        end else begin
                            state <= DONE;
                        end
                    end else begin
                        parallel_req_o  <= 1'b1;
                        parallel_cmd_o  <= cmd_int;
                        parallel_addr_o <= apb_addr_i + word_cnt;
                        if (cmd_int[0])
                            parallel_wdata_o <= ram_rdata;
                    end
                end

                EXT_STREAM_WAIT_ACK: begin
                    apb_busy_o <= 1'b1;
                    // ждём снятия word_done
                    if (!parallel_word_done_i) begin
                        ram_wr_en <= 1'b0;               // выключаем запись в ОЗУ (если была)
                        state     <= next_state_after_ack;
                    end else begin
                        parallel_req_o  <= 1'b1;
                        parallel_cmd_o  <= cmd_int;
                        parallel_addr_o <= apb_addr_i + word_cnt;
                        if (cmd_int[0])
                            parallel_wdata_o <= ram_rdata;
                    end
                end

                DONE: begin
                    apb_busy_o      <= 1'b0;
                    parallel_req_o   <= 1'b0;
                    parallel_cmd_o   <= 2'b00;
                    parallel_addr_o  <= 16'b0;
                    parallel_wdata_o <= 32'b0;
                    word_cnt         <= 2'b0;
                    load_cnt         <= 2'b0;
                    state            <= IDLE;
                end
            endcase
        end
    end
endmodule