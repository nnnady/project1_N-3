// ============================================================================
// Модуль: converter_fsm
// Назначение: Управляющий конечный автомат конвертера.
// Координирует взаимодействие APB, ОЗУ и внешнего параллельного мастера.
// Обрабатывает команды: одиночное/потоковое чтение/запись.
// Для варианта 11: хранит данные в ОЗУ, при потоковой записи читает из ОЗУ.
// ============================================================================
module converter_fsm (
    input  logic        clk,                // Системный тактовый сигнал
    input  logic        rst_n,              // Асинхронный сброс

    // Входы от APB (через apb_slave)
    input  logic [15:0] apb_addr_i,         // Адрес, записанный в регистр адреса
    input  logic [31:0] apb_wdata_i,        // Данные, записанные в регистр данных
    input  logic [1:0]  apb_cmd_i,          // Код команды
    input  logic        apb_start_req,      // Запуск операции (из регистра управления)
    input  logic        apb_data_written_o, // Данные записаны в APB (импульс)
    input  logic        apb_rdata_pop,      // APB прочитал данные (импульс)

    // Выходы к APB
    output logic        apb_busy_o,         // Занятость конвертера (1 – выполняет операцию)
    output logic [31:0] apb_rdata_o,        // Данные для чтения через APB

    // Интерфейс к parallel_master (внешнему)
    input  logic        parallel_done_i,      // Транзакция полностью завершена
    input  logic        parallel_word_done_i, // Завершена передача одного слова (в потоке)
    input  logic [31:0] parallel_rdata_i,     // Данные, полученные от внешнего устройства (при чтении)
    output logic        parallel_req_o,       // Запрос на выполнение внешней транзакции
    output logic [15:0] parallel_addr_o,      // Адрес для внешней шины
    output logic [1:0]  parallel_cmd_o,       // Код команды для внешней шины (01-запись, 10-чтение)
    output logic [31:0] parallel_wdata_o,     // Данные для записи во внешнюю шину

    // Интерфейс к ОЗУ (converter_ram)
    input  logic [31:0] ram_rdata,   // Прочитанные данные из ОЗУ
    output logic [4:0]  ram_addr,    // Адрес в ОЗУ (5 бит, 32 слова)
    output logic [31:0] ram_wdata,   // Данные для записи в ОЗУ
    output logic        ram_wr_en    // Разрешение записи в ОЗУ
);
    // ========================================================================
    // Состояния управляющего автомата
    // ========================================================================
    typedef enum logic [3:0] {
        IDLE,                     // Ожидание команды от APB
        RAM_STREAM_WRITE,         // Потоковая запись: сохранение одного слова в ОЗУ
        RAM_STREAM_READ_ADDR,     // Потоковое чтение: установка адреса ОЗУ
        RAM_STREAM_READ_DATA,     // Потоковое чтение: ожидание данных из ОЗУ
        EXT_SINGLE_HANDLE,        // Обработка одиночной внешней транзакции
        EXT_STREAM_PREPARE,       // Подготовка к передаче очередного слова в потоке
        EXT_STREAM_HANDLE,        // Передача/приём одного слова в потоке
        EXT_STREAM_WAIT,          // Ожидание полного завершения потоковой транзакции
        EXT_STREAM_WAIT_ACK,      // Ожидание снятия word_done после приёма/передачи слова
        DONE                      // Операция завершена, переход в IDLE
    } state_t;

    state_t state, next_state_after_ack;  // next_state_after_ack – для возврата после ожидания
    logic [1:0] word_cnt;    // Счётчик переданных/принятых слов в потоке (0..3)
    logic [1:0] load_cnt;    // Счётчик загруженных из APB слов (для потоковой записи)
    logic [1:0] unload_cnt;  // Счётчик выгруженных в APB слов (для потокового чтения)
    logic [31:0] rdata_reg;  // Регистр для хранения прочитанных данных до возврата в IDLE

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            word_cnt   <= 2'b0;
            load_cnt   <= 2'b0;
            unload_cnt <= 2'b0;
            rdata_reg  <= 32'b0;
        end else begin
            // Значения по умолчанию для выходных сигналов (кроме apb_rdata_o)
            apb_busy_o      <= 1'b0;
            parallel_req_o  <= 1'b0;
            ram_wr_en       <= 1'b0;
            ram_wdata       <= 32'b0;
            parallel_cmd_o  <= 2'b00;
            parallel_addr_o <= 16'b0;
            parallel_wdata_o<= 32'b0;
            ram_addr        <= 5'b0;
            apb_rdata_o     <= rdata_reg;   // По умолчанию отдаём последние сохранённые данные

            case (state)
                // ------------------------------------------------------------
                IDLE: begin
                    next_state_after_ack <= IDLE;
                    if (apb_data_written_o) begin
                        // Пришло слово данных от APB – сохраняем в ОЗУ (потоковая запись)
                        state <= RAM_STREAM_WRITE;
                    end else if (apb_start_req) begin
                        // Получен сигнал старта транзакции
                        case (apb_cmd_i)
                            2'b00, 2'b01: state <= EXT_SINGLE_HANDLE; // Одиночные операции
                            2'b10, 2'b11: begin                      // Потоковые операции
                                word_cnt <= 2'b0;
                                state <= EXT_STREAM_PREPARE;
                            end
                            default: state <= IDLE;
                        endcase
                    end
                end

                // ------------------------------------------------------------
                // Сохранение одного слова в ОЗУ (по адресу + смещение load_cnt)
                // ------------------------------------------------------------
                RAM_STREAM_WRITE: begin
                    ram_addr  <= apb_addr_i[4:0] + load_cnt;
                    ram_wdata <= apb_wdata_i;
                    ram_wr_en <= 1'b1;
                    load_cnt  <= load_cnt + 1'b1;
                    state     <= IDLE;  // Возвращаемся, ждём следующее слово
                end

                // ------------------------------------------------------------
                // Подготовка адреса для чтения из ОЗУ (потоковое чтение)
                // ------------------------------------------------------------
                RAM_STREAM_READ_ADDR: begin
                    ram_addr <= apb_addr_i[4:0] + unload_cnt;
                    state    <= RAM_STREAM_READ_DATA;
                end

                // ------------------------------------------------------------
                // Чтение данных из ОЗУ и передача в APB, когда тот готов
                // ------------------------------------------------------------
                RAM_STREAM_READ_DATA: begin
                    apb_rdata_o <= ram_rdata;           // Обновляем данные для APB
                    if (apb_rdata_pop) begin            // APB считал данные
                        rdata_reg <= ram_rdata;         // Сохраняем в регистр
                        if (unload_cnt == 2'd3) begin   // Это было последнее слово
                            unload_cnt <= 2'd0;
                            state      <= DONE;
                        end else begin
                            unload_cnt <= unload_cnt + 1'b1;
                            state      <= RAM_STREAM_READ_ADDR;
                        end
                    end
                end

                // ------------------------------------------------------------
                // Обработка одиночной операции (чтение или запись)
                // ------------------------------------------------------------
                EXT_SINGLE_HANDLE: begin
                    apb_busy_o     <= 1'b1;
                    parallel_req_o <= 1'b1;               // Запрос внешней транзакции
                    parallel_addr_o<= apb_addr_i;
                    if (apb_cmd_i[0] == 1'b1) begin      // Запись
                        parallel_cmd_o   <= 2'b01;       // Код команды записи
                        parallel_wdata_o <= apb_wdata_i;
                    end else begin                       // Чтение
                        parallel_cmd_o   <= 2'b00;       // Код команды чтения
                    end
                    if (parallel_done_i) begin            // Внешняя транзакция завершена
                        parallel_req_o <= 1'b0;
                        if (apb_cmd_i[0] == 1'b0) begin  // При чтении сохраняем данные
                            rdata_reg <= parallel_rdata_i;
                            apb_rdata_o <= parallel_rdata_i;
                        end
                        state <= DONE;
                    end
                end

                // ------------------------------------------------------------
                // Подготовка к отправке/приёму очередного слова в потоке
                // ------------------------------------------------------------
                EXT_STREAM_PREPARE: begin
                    apb_busy_o <= 1'b1;
                    if (apb_cmd_i[0] == 1'b1)               // Потоковая запись
                        ram_addr <= apb_addr_i[4:0] + word_cnt; // Читаем данные из ОЗУ
                    state <= EXT_STREAM_HANDLE;
                end

                // ------------------------------------------------------------
                // Активная фаза передачи одного слова (адрес + данные)
                // ------------------------------------------------------------
                EXT_STREAM_HANDLE: begin
                    apb_busy_o      <= 1'b1;
                    if (!parallel_req_o) begin               // Первый вход – выставляем запрос
                        parallel_req_o  <= 1'b1;
                        parallel_cmd_o  <= apb_cmd_i;        // Код потоковой операции
                        parallel_addr_o <= apb_addr_i + word_cnt; // Адрес с учётом смещения
                        if (apb_cmd_i[0] == 1'b1)            // Потоковая запись: данные из ОЗУ
                            parallel_wdata_o <= ram_rdata;
                    end
                    if (parallel_word_done_i) begin           // Слово передано
                        if (apb_cmd_i[0] == 1'b0) begin       // Потоковое чтение: запоминаем в ОЗУ
                            ram_wr_en <= 1'b1;
                            ram_addr  <= apb_addr_i[4:0] + word_cnt;
                            ram_wdata <= parallel_rdata_i;
                        end
                        if (word_cnt == 2'd3)                 // Все 4 слова переданы?
                            next_state_after_ack <= EXT_STREAM_WAIT;
                        else begin
                            word_cnt <= word_cnt + 1'b1;
                            next_state_after_ack <= EXT_STREAM_PREPARE;
                        end
                        state <= EXT_STREAM_WAIT_ACK;         // Ждём снятия word_done
                    end
                end

                // ------------------------------------------------------------
                // Ожидание полного завершения потоковой транзакции (done)
                // ------------------------------------------------------------
                EXT_STREAM_WAIT: begin
                    if (parallel_done_i) begin
                        parallel_req_o <= 1'b0;
                        if (apb_cmd_i[0] == 1'b0) begin       // Потоковое чтение: готовимся выгружать в APB
                            unload_cnt <= 2'd0;
                            state      <= RAM_STREAM_READ_ADDR;
                        end else begin
                            state <= DONE;
                        end
                    end
                end

                // ------------------------------------------------------------
                // Ожидание снятия word_done (чтобы не задвоить обработку)
                // ------------------------------------------------------------
                EXT_STREAM_WAIT_ACK: begin
                    apb_busy_o <= 1'b1;
                    if (!parallel_word_done_i) begin
                        ram_wr_en <= 1'b0;                    // Снимаем сигнал записи в ОЗУ
                        state     <= next_state_after_ack;
                    end
                end

                // ------------------------------------------------------------
                // Завершение операции и возврат в IDLE
                // ------------------------------------------------------------
                DONE: begin
                    apb_busy_o      <= 1'b0;
                    parallel_req_o  <= 1'b0;
                    word_cnt        <= 2'b0;
                    load_cnt        <= 2'b0;
                    state           <= IDLE;
                end
            endcase
        end
    end
endmodule
