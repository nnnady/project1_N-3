// ============================================================================
// Модуль: converter_top
// Назначение: Верхний уровень конвертера. Объединяет APB slave, ОЗУ,
// параллельный мастер и управляющий FSM.
// Для варианта 11: реализует конвертер в роли мастера.
// ============================================================================
module converter_top (
    input  logic        clk,          // Системный тактовый сигнал
    input  logic        rst_n,        // Асинхронный сброс (активный низкий)

    // Интерфейс APB (внутренний)
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [15:0] paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr,

    // Внешний параллельный интерфейс (к верификационному модулю)
    input  logic        ext_ready_i,     // Внешнее устройство готово принять/передать данные
    input  logic        ext_ack_i,       // Подтверждение от внешнего устройства (конец транзакции/слова)
    input  logic [15:0] ext_rdata_i,     // Принятые данные от внешнего устройства
    output logic [15:0] ext_addr_o,      // Адрес для внешней шины
    output logic [1:0]  ext_cmd_o,       // Команда для внешней шины (01-адрес, 10-чтение, 11-запись)
    output logic [15:0] ext_data_o,      // Данные для записи во внешнюю шину
    output logic        ext_stream_o,    // Признак потоковой операции
    output logic        ext_word_done_o, // Импульс завершения передачи слова
    output logic        ext_tick_o,      // Строб делителя частоты (такт внешнего интерфейса)
    output logic        ext_half_o       // Индикатор фазы: 0 – младшая половина 32-битного слова, 1 – старшая
);
    // ========================================================================
    // Внутренние сигналы связи между модулями
    // ========================================================================
    logic apb_start_req, apb_busy, apb_data_written, apb_rdata_pop;
    logic [15:0] apb_addr;
    logic [31:0] apb_wdata, fsm_rdata;
    logic [1:0]  apb_cmd;

    logic parallel_req, parallel_done, parallel_word_done;
    logic [1:0]  parallel_cmd;
    logic [15:0] parallel_addr;
    logic [31:0] parallel_wdata, parallel_rdata;

    logic ram_wr_en;
    logic [4:0]  ram_addr;
    logic [31:0] ram_wdata, ram_rdata;

    // ------------------------------------------------------------------------
    // Экземпляр APB slave (внутренний интерфейс)
    // ------------------------------------------------------------------------
    apb_slave u_apb (
        .clk, .rst_n, .psel, .penable, .pwrite, .paddr, .pwdata,
        .prdata, .pready, .pslverr,
        .busy_i(apb_busy), .start_req(apb_start_req),
        .cmd_out(apb_cmd), .addr_out(apb_addr), .data_out(apb_wdata),
        .data_written_o(apb_data_written), .fsm_wdata_i(fsm_rdata),
        .apb_rdata_pop(apb_rdata_pop)
    );

    // ------------------------------------------------------------------------
    // Экземпляр ОЗУ (32x32)
    // ------------------------------------------------------------------------
    converter_ram u_ram (
        .clk, .addr(ram_addr), .wdata(ram_wdata), .wr_en(ram_wr_en), .rdata(ram_rdata)
    );

    // ------------------------------------------------------------------------
    // Экземпляр параллельного мастера (внешний интерфейс)
    // ------------------------------------------------------------------------
    parallel_master u_master (
        .clk, .rst_n, .req_i(parallel_req),
        .addr_i(parallel_addr), .wr_i(parallel_cmd), .wdata_i(parallel_wdata),
        .ext_ready_i, .ext_ack_i, .ext_rdata_i,
        .done_o(parallel_done), .word_done_o(parallel_word_done),
        .rdata_o(parallel_rdata),
        .ext_addr_o, .ext_cmd_o, .ext_data_o,
        .ext_stream_o, .ext_word_done_o, .ext_tick_o,
        .high_phase_o(ext_half_o)
    );

    // ------------------------------------------------------------------------
    // Экземпляр управляющего автомата (FSM)
    // ------------------------------------------------------------------------
    converter_fsm u_fsm (
        .clk, .rst_n,
        .apb_addr_i(apb_addr), .apb_wdata_i(apb_wdata), .apb_cmd_i(apb_cmd),
        .apb_start_req, .apb_data_written_o(apb_data_written),
        .apb_rdata_pop, .apb_busy_o(apb_busy), .apb_rdata_o(fsm_rdata),
        .parallel_done_i(parallel_done), .parallel_word_done_i(parallel_word_done),
        .parallel_rdata_i(parallel_rdata),
        .parallel_req_o(parallel_req), .parallel_addr_o(parallel_addr),
        .parallel_cmd_o(parallel_cmd), .parallel_wdata_o(parallel_wdata),
        .ram_rdata, .ram_addr, .ram_wdata, .ram_wr_en
    );
endmodule
