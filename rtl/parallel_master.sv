// ============================================================================
// Модуль: parallel_master
// Назначение: Контроллер внешнего параллельного интерфейса (ведущий).
// Передаёт 32-битные данные за два 16-битных слова (младшее, затем старшее).
// Поддерживает одиночные и потоковые операции (до 4 слов подряд).
// Для варианта 11: используется делитель частоты на 3 (N=3, как требовал преподаватель).
// ============================================================================
module parallel_master (
    input  logic        clk,            // Системный тактовый сигнал
    input  logic        rst_n,          // Асинхронный сброс

    // Команды от FSM
    input  logic        req_i,          // Запрос на выполнение транзакции
    input  logic [15:0] addr_i,         // Адрес (16 бит)
    input  logic [1:0]  wr_i,           // Тип операции: 00-чтение, 01-запись, 10-поток.чтение, 11-поток.запись
    input  logic [31:0] wdata_i,        // Данные для записи (32 бита)

    // Внешний параллельный интерфейс
    input  logic        ext_ready_i,    // Ведомый готов к обмену
    input  logic        ext_ack_i,      // Подтверждение транзакции/слова
    input  logic [15:0] ext_rdata_i,    // Данные от ведомого (16 бит)
    output logic        done_o,         // Транзакция полностью завершена
    output logic        word_done_o,    // Передача одного слова завершена
    output logic [31:0] rdata_o,        // Принятые данные (32 бита, сборка из двух 16-битных)

    // Выходы на внешнюю шину
    output logic [15:0] ext_addr_o,     // Адрес
    output logic [1:0]  ext_cmd_o,      // Команда (01-адрес, 10-чтение, 11-запись, 00-нет операции)
    output logic [15:0] ext_data_o,     // Данные для записи
    output logic        ext_stream_o,   // Признак потоковой операции
    output logic        ext_word_done_o,// Импульс завершения слова
    output logic        ext_tick_o,     // Строб делителя частоты (1 раз в 3 такта)
    output logic        high_phase_o    // 0 – передаётся младшая половина слова, 1 – старшая
);
    // ========================================================================
    // Состояния конечного автомата мастера
    // ========================================================================
    typedef enum logic [2:0] {
        IDLE,         // Ожидание запроса
        ADDR_PHASE,   // Передача адреса
        DATA_LOW,     // Приём/передача младшей половины данных
        DATA_HIGH,    // Приём/передача старшей половины данных
        WAIT_ACK      // Ожидание подтверждения (ack) и переход к следующему слову или done
    } state_t;

    logic [1:0]  word_cnt;      // Счётчик переданных слов в потоке (0..3)
    logic        stream_mode;   // Признак потоковой операции (1 – поток)
    state_t      state;
    logic [2:0]  div_cnt;       // Счётчик для делителя частоты на 3
    logic        tick;          // Строб (один такт каждые 3 такта clk)
    logic [15:0] data_low;      // Регистр для младшей половины слова (при сборке чтения)

    // Выходы на верхний уровень
    assign ext_tick_o      = tick;
    assign ext_word_done_o = word_done_o;
    assign ext_stream_o    = wr_i[1];   // Бит 1 команды указывает поток
    assign high_phase_o    = (state == DATA_HIGH) ? 1'b1 : 1'b0;

    // ========================================================================
    // Делитель частоты на 3 (tick = 1 каждые 3 такта clk)
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 3'b0;
            tick    <= 1'b0;
        end else begin
            div_cnt <= (div_cnt == 3'd2) ? 3'b0 : div_cnt + 1'b1;
            tick    <= (div_cnt == 3'd2);   // Строб в последнем такте счёта
        end
    end

    // ========================================================================
    // Основной автомат параллельного мастера (работает по стробу tick)
    // ========================================================================
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
            // Сброс импульсных сигналов в каждом такте tick
            done_o      <= 1'b0;
            word_done_o <= 1'b0;
            case (state)
                // ------------------------------------------------------------
                IDLE: begin
                    ext_cmd_o  <= 2'b00;   // Нет активности на шине
                    ext_data_o <= 16'b0;
                    if (req_i) begin
                        stream_mode <= wr_i[1];   // Запомнить режим
                        word_cnt    <= 2'b0;
                        state       <= ADDR_PHASE;
                    end
                end

                // ------------------------------------------------------------
                ADDR_PHASE: begin
                    ext_addr_o <= addr_i;         // Выставить адрес
                    ext_cmd_o  <= 2'b01;          // Код «адрес»
                    if (ext_ready_i) begin         // Ведомый готов
                        if (wr_i[0]) begin         // Операция записи
                            data_low   <= wdata_i[15:0];
                            ext_data_o <= wdata_i[15:0];  // Младшая половина
                            ext_cmd_o  <= 2'b11;          // Код «запись»
                            state      <= DATA_HIGH;      // Сразу к старшей половине
                        end else begin             // Операция чтения
                            ext_cmd_o  <= 2'b10;          // Код «чтение»
                            state      <= DATA_LOW;       // Ждём младшую половину
                        end
                    end
                end

                // ------------------------------------------------------------
                DATA_LOW: begin    // Приём младшей половины (только чтение)
                    ext_addr_o <= addr_i;
                    ext_cmd_o  <= 2'b10;                // Код «чтение»
                    if (ext_ready_i) begin
                        data_low   <= ext_rdata_i;      // Сохранить младшие 16 бит
                        state      <= DATA_HIGH;        // Перейти к старшей половине
                    end
                end

                // ------------------------------------------------------------
                DATA_HIGH: begin   // Приём (чтение) / передача (запись) старшей половины
                    ext_addr_o <= addr_i;
                    if (wr_i[0]) begin                   // Запись
                        ext_data_o <= wdata_i[31:16];    // Старшая половина
                        ext_cmd_o  <= 2'b11;             // Код «запись»
                        state <= WAIT_ACK;               // Ждать подтверждения слова
                    end else begin                       // Чтение
                        ext_cmd_o  <= 2'b10;             // Код «чтение»
                        if (ext_ready_i) begin
                            rdata_o   <= {ext_rdata_i, data_low}; // Сборка 32 бит
                            state     <= WAIT_ACK;       // Ждать подтверждения
                        end
                    end
                end

                // ------------------------------------------------------------
                WAIT_ACK: begin
                    ext_addr_o  <= addr_i;
                    ext_cmd_o   <= wr_i[0] ? 2'b11 : 2'b10; // Сохраняем тип операции
                    word_done_o <= 1'b1;                    // Сигнал «слово завершено»
                    if (ext_ack_i) begin                     // Ведомый подтвердил
                        word_done_o <= 1'b0;
                        if (stream_mode && (word_cnt < 2'd3)) begin // Есть ещё слова в потоке
                            word_cnt <= word_cnt + 1'b1;
                            state    <= ADDR_PHASE;          // Следующее слово (адрес может увеличиваться снаружи)
                        end else begin
                            word_cnt <= 2'b0;
                            done_o   <= 1'b1;                // Транзакция завершена
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
