// ============================================================================
// Модуль: apb_slave
// Назначение: Внутренний интерфейс конвертера – ведомый APB (АРВ/ОСР-РЮ).
// Хранит регистры адреса, команды, данных, статуса и управления.
// Формирует сигналы для FSM конвертера.
// Для варианта 11: master, параллельный внешний интерфейс, геометрическая прогрессия, ОЗУ.
// ============================================================================
module apb_slave (
    input  logic        clk,          // Системный тактовый сигнал
    input  logic        rst_n,        // Асинхронный сброс (активный низкий)
    // Стандартные сигналы APB
    input  logic        psel,         // Выбор устройства (PSEL)
    input  logic        penable,      // Разрешение транзакции (PENABLE)
    input  logic        pwrite,       // Направление: 1 – запись, 0 – чтение
    input  logic [15:0] paddr,        // Адрес регистра
    input  logic [31:0] pwdata,       // Данные для записи
    output logic [31:0] prdata,       // Прочитанные данные
    output logic        pready,       // Готовность (передача завершена)
    output logic        pslverr,      // Ошибка передачи (неверный адрес/операция)

    // Интерфейс к FSM конвертера
    input  logic        busy_i,       // Признак занятости (от FSM)
    output logic        start_req,    // Запуск внешней транзакции (из регистра управления)
    output logic [1:0]  cmd_out,      // Код команды: 00-чтение, 01-запись, 10-поток.запись, 11-поток.чтение
    output logic [15:0] addr_out,     // Адрес для внешней операции
    output logic [31:0] data_out,     // Данные для внешней операции
    output logic        data_written_o, // Импульс: данные записаны в регистр данных (адрес 0x10)
    input  logic [31:0] fsm_wdata_i,  // Данные, пришедшие от FSM (для чтения по 0x10)
    output logic        apb_rdata_pop // Импульс: APB прочитал данные из регистра данных (нужен FSM)
);
    // ========================================================================
    // Регистры внутреннего интерфейса (соответствуют адресам APB)
    // ========================================================================
    logic [15:0] ADDR_REG;   // Регистр адреса (0x08)
    logic [31:0] DATA_REG;   // Регистр данных (0x10)
    logic [1:0]  CMD_REG;    // Регистр команды (0x0C)
    logic        STATUS_REG; // Регистр статуса (0x00): 0 – свободен, 1 – занят
    logic        CTRL_REG;   // Регистр управления (0x04): запись 1 – старт

    // Формирование импульса apb_rdata_pop: фронт сигнала чтения данных
    logic apb_rdata_valid;
    logic apb_rdata_valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) apb_rdata_valid_r <= 1'b0;
        else        apb_rdata_valid_r <= apb_rdata_valid;
    end
    assign apb_rdata_pop = apb_rdata_valid && !apb_rdata_valid_r; // Переход 0->1

    // ========================================================================
    // Логика записи в регистры по APB
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ADDR_REG   <= 16'b0;
            DATA_REG   <= 32'b0;
            CMD_REG    <= 2'b0;
            STATUS_REG <= 1'b0;
            CTRL_REG   <= 1'b0;
        end else if (psel && penable && pwrite && !pslverr) begin
            // Запись разрешена только при отсутствии ошибки
            case (paddr[15:0])
                16'h0004: CTRL_REG <= pwdata[0];          // Бит 0 – старт транзакции
                16'h0008: ADDR_REG <= pwdata[15:0];       // Только младшие 16 бит
                16'h000C: CMD_REG  <= pwdata[1:0];        // Код команды
                16'h0010: DATA_REG <= pwdata[31:0];       // Данные (32 бита)
            endcase
        end
        // Регистр статуса аппаратно обновляется сигналом busy от FSM
        STATUS_REG <= busy_i;
    end

    // ========================================================================
    // Чтение регистров (комбинационная логика)
    // ========================================================================
    always_comb begin
        if (!pwrite) begin
            case (paddr[15:0])
                16'h0000: prdata = {31'b0, STATUS_REG};   // Статус: один значащий бит
                16'h0008: prdata = {16'b0, ADDR_REG};     // Адрес
                16'h000C: prdata = {30'b0, CMD_REG};      // Команда
                16'h0010: prdata = fsm_wdata_i;           // Данные, предоставленные FSM
                default:  prdata = 32'b0;
            endcase
        end else
            prdata = 32'b0;
    end

    // ========================================================================
    // Генерация сигнала ошибки PSLVERR
    // Запрещены: запись в статус (0x00), чтение регистра управления (0x04),
    // обращение по несуществующим адресам.
    // ========================================================================
    always_comb begin
        if (psel && penable) begin
            if ((pwrite && paddr == 16'h0000) ||       // Запись статуса
                (!pwrite && paddr == 16'h0004) ||      // Чтение регистра управления
                !(paddr inside {16'h0000,16'h0004,16'h0008,16'h000C,16'h0010})) // Неверный адрес
                pslverr = 1'b1;
            else
                pslverr = 1'b0;
        end else
            pslverr = 1'b0;
    end

    // APB всегда отвечает готовностью на следующем такте после установки PSEL и PENABLE
    assign pready = psel & penable;

    // Импульс записи данных (для FSM, чтобы сохранить данные в ОЗУ при потоковой записи)
    assign data_written_o = psel && penable && pwrite && (paddr == 16'h0010);

    // Сигнал валидного чтения данных (используется для apb_rdata_pop)
    assign apb_rdata_valid = !pwrite && penable && psel && (paddr == 16'h0010);

    // Выходы к FSM
    assign cmd_out   = CMD_REG;
    assign start_req = CTRL_REG;
    assign addr_out  = ADDR_REG;
    assign data_out  = DATA_REG;
endmodule