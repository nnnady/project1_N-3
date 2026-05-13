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

    // --------------------------------------------------------------
    // Состояния конечного автомата
    // --------------------------------------------------------------
    typedef enum logic [3:0] {
        IDLE,                   // Ожидание команды или записи данных
        RAM_STREAM_WRITE,       // Приём одного слова из APB в RAM (для потоковой записи)
        RAM_STREAM_READ_ADDR,   // Установка адреса RAM для выгрузки данных (потоковое чтение)
        RAM_STREAM_READ_DATA,   // Чтение из RAM и ожидание, пока процессор заберёт данные
        EXT_SINGLE_HANDLE,      // Обработка одиночной внешней транзакции (чтение/запись)
        EXT_STREAM_PREPARE,     // Подготовка к передаче одного слова потоковой операции
        EXT_STREAM_HANDLE,      // Непосредственная передача/приём одного слова
        EXT_STREAM_WAIT,        // Ожидание завершения всей потоковой транзакции
        EXT_STREAM_WAIT_ACK,    // Ожидание снятия сигнала word_done (между словами)
        DONE                    // Завершение операции, сброс сигналов
    } state_t;

    state_t state, next_state_after_ack;
    logic [1:0] word_cnt;       // Текущее слово в потоке (0..3)
    logic [1:0] load_cnt;       // Счётчик записанных в RAM слов (для потоковой записи)
    logic [1:0] unload_cnt;     // Счётчик выгруженных из RAM слов (для потокового чтения)
    logic [31:0] rdata_reg;     // Регистр для временного хранения прочитанных данных

    // --------------------------------------------------------------
    // Преобразование команд APB в команды для внешнего мастера
    // APB: 00 – чтение, 01 – запись, 10 – поток.запись, 11 – поток.чтение
    // Мастер: cmd_int[1] = поток, cmd_int[0] = 1 – запись, 0 – чтение
    // --------------------------------------------------------------
    logic [1:0] cmd_int;
    always_comb
        case (apb_cmd_i)
            2'b10:   cmd_int = 2'b11;   // потоковая запись -> запись + поток
            2'b11:   cmd_int = 2'b10;   // потоковое чтение  -> чтение + поток
            default: cmd_int = apb_cmd_i;
        endcase

    // --------------------------------------------------------------
    // Основной автомат (синхронный, с асинхронным сбросом)
    // --------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            word_cnt   <= 2'b0;
            load_cnt   <= 2'b0;
            unload_cnt <= 2'b0;
            rdata_reg  <= 32'b0;
        end else begin
            // Значения по умолчанию (обнуляются только те сигналы, которые должны быть импульсными)
            apb_busy_o      <= 1'b0;
            apb_rdata_o     <= rdata_reg;
            ram_wr_en       <= 1'b0;   // запись в RAM разрешена только в явных состояниях

            case (state)
                // ----------------------------------------------------------
                // IDLE – ждём либо записи данных в регистр DATA (потоковая запись),
                // либо команды старта от процессора.
                // ----------------------------------------------------------
                IDLE: begin
                    parallel_req_o   <= 1'b0;
                    parallel_cmd_o   <= 2'b00;
                    parallel_addr_o  <= 16'b0;
                    parallel_wdata_o <= 32'b0;
                    ram_addr         <= 5'b0;
                    ram_wdata        <= 32'b0;
                    next_state_after_ack <= IDLE;

                    if (apb_data_written_o) begin
                        // Процессор записал данные в регистр DATA – начинаем приём в RAM
                        state <= RAM_STREAM_WRITE;
                    end else if (apb_start_req) begin
                        // Поступила команда старта – выбираем режим по коду команды
                        case (apb_cmd_i)
                            2'b00, 2'b01: state <= EXT_SINGLE_HANDLE;   // одиночные
                            2'b10, 2'b11: begin                         // потоковые
                                word_cnt   <= 2'b0;
                                load_cnt   <= 2'b0;
                                unload_cnt <= 2'b0;
                                state <= EXT_STREAM_PREPARE;
                            end
                            default: state <= IDLE;
                        endcase
                    end
                end

                // ----------------------------------------------------------
                // RAM_STREAM_WRITE – сохраняем одно слово из APB в RAM (для потоковой записи)
                // Адрес в RAM = базовый адрес + load_cnt
                // ----------------------------------------------------------
                RAM_STREAM_WRITE: begin
                    ram_addr  <= apb_addr_i[4:0] + load_cnt;
                    ram_wdata <= apb_wdata_i;
                    ram_wr_en <= 1'b1;
                    load_cnt  <= load_cnt + 1'b1;
                    state     <= IDLE;   // после каждого слова возвращаемся в IDLE
                end

                // ----------------------------------------------------------
                // RAM_STREAM_READ_ADDR – установка адреса RAM для выгрузки (потоковое чтение)
                // ----------------------------------------------------------
                RAM_STREAM_READ_ADDR: begin
                    ram_addr <= apb_addr_i[4:0] + unload_cnt;
                    state    <= RAM_STREAM_READ_DATA;
                end

                // ----------------------------------------------------------
                // RAM_STREAM_READ_DATA – чтение из RAM и ожидание, пока процессор
                // заберёт данные через APB (сигнал apb_rdata_pop)
                // ----------------------------------------------------------
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

                // ----------------------------------------------------------
                // EXT_SINGLE_HANDLE – одиночная транзакция (чтение или запись)
                // Выставляем запрос параллельному мастеру и ждём parallel_done_i
                // ----------------------------------------------------------
                EXT_SINGLE_HANDLE: begin
                    apb_busy_o     <= 1'b1;
                    parallel_req_o <= 1'b1;
                    parallel_addr_o<= apb_addr_i;
                    if (cmd_int[0]) begin
                        // запись: передаём данные
                        parallel_cmd_o   <= cmd_int;
                        parallel_wdata_o <= apb_wdata_i;
                    end else begin
                        // чтение: только команда
                        parallel_cmd_o   <= cmd_int;
                    end
                    if (parallel_done_i) begin
                        parallel_req_o <= 1'b0;
                        if (!cmd_int[0]) begin
                            // для чтения сохраняем полученные данные
                            rdata_reg <= parallel_rdata_i;
                            apb_rdata_o <= parallel_rdata_i;
                        end
                        state <= DONE;
                    end
                end

                // ----------------------------------------------------------
                // EXT_STREAM_PREPARE – подготовка к передаче одного слова в потоке
                // Устанавливаем адрес для параллельного мастера и адрес RAM
                // ----------------------------------------------------------
                EXT_STREAM_PREPARE: begin
                    apb_busy_o      <= 1'b1;
                    parallel_addr_o <= apb_addr_i + word_cnt;
                    ram_addr        <= apb_addr_i[4:0] + word_cnt;   // адрес RAM для чтения/записи
                    state           <= EXT_STREAM_HANDLE;
                end

                // ----------------------------------------------------------
                // EXT_STREAM_HANDLE – активная передача одного слова
                // Для записи: данные берутся из RAM (ram_rdata)
                // Для чтения: полученные данные сохраняются в RAM
                // ----------------------------------------------------------
                EXT_STREAM_HANDLE: begin
                    apb_busy_o      <= 1'b1;
                    parallel_req_o  <= 1'b1;
                    parallel_cmd_o  <= cmd_int;
                    parallel_addr_o <= apb_addr_i + word_cnt;
                    if (cmd_int[0])
                        parallel_wdata_o <= ram_rdata;   // запись: данные из RAM

                    if (parallel_word_done_i) begin
                        // Слово передано/принято
                        if (!cmd_int[0]) begin
                            // чтение: сохраняем полученное слово в RAM
                            ram_wr_en <= 1'b1;
                            ram_addr  <= apb_addr_i[4:0] + word_cnt;
                            ram_wdata <= parallel_rdata_i;
                        end
                        // Переход к следующему слову или к завершению потока
                        if (word_cnt == 2'd3) begin
                            next_state_after_ack <= EXT_STREAM_WAIT;
                        end else begin
                            word_cnt <= word_cnt + 1'b1;
                            next_state_after_ack <= EXT_STREAM_PREPARE;
                        end
                        state <= EXT_STREAM_WAIT_ACK;
                    end
                end

                // ----------------------------------------------------------
                // EXT_STREAM_WAIT – ожидание сигнала parallel_done_i,
                // который означает завершение всей потоковой транзакции
                // ----------------------------------------------------------
                EXT_STREAM_WAIT: begin
                    if (parallel_done_i) begin
                        parallel_req_o <= 1'b0;
                        if (!cmd_int[0]) begin
                            // потоковое чтение: после приёма всех слов выгружаем их в APB
                            unload_cnt <= 2'd0;
                            state <= RAM_STREAM_READ_ADDR;
                        end else begin
                            // потоковая запись: завершаем
                            state <= DONE;
                        end
                    end else begin
                        // параллельный мастер ещё не закончил – продолжаем удерживать запрос
                        parallel_req_o  <= 1'b1;
                        parallel_cmd_o  <= cmd_int;
                        parallel_addr_o <= apb_addr_i + word_cnt;
                        if (cmd_int[0])
                            parallel_wdata_o <= ram_rdata;
                    end
                end

                // ----------------------------------------------------------
                // EXT_STREAM_WAIT_ACK – ожидание снятия сигнала word_done
                // (пауза между словами, чтобы мастер успел переключиться)
                // ----------------------------------------------------------
                EXT_STREAM_WAIT_ACK: begin
                    apb_busy_o <= 1'b1;
                    if (!parallel_word_done_i) begin
                        ram_wr_en <= 1'b0;
                        state     <= next_state_after_ack;
                    end else begin
                        // word_done всё ещё активен – продолжаем удерживать запрос
                        parallel_req_o  <= 1'b1;
                        parallel_cmd_o  <= cmd_int;
                        parallel_addr_o <= apb_addr_i + word_cnt;
                        if (cmd_int[0])
                            parallel_wdata_o <= ram_rdata;
                    end
                end

                // ----------------------------------------------------------
                // DONE – сброс всех управляющих сигналов, возврат в IDLE
                // ----------------------------------------------------------
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