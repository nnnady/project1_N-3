// ============================================================================
// Пакет tb_pkg: содержит классы для тестового окружения
// ============================================================================
`timescale 1ns/1ps
package tb_pkg;
    localparam VERBOSE = 0;   // 1 – подробный лог, 0 – только важное
    // ------------------------------------------------------------------------
    // Класс-контейнер для транзакции (передаётся между компонентами)
    // ------------------------------------------------------------------------
    class trans_t;
        bit          wr_en;       // 1 – запись, 0 – чтение
        logic [4:0]  addr;        // Адрес (5 бит, используется внутри памяти)
        logic [31:0] data;        // Данные
    endclass

    // ------------------------------------------------------------------------
    // Scoreboard – модуль сбора статистики и проверки корректности
    // ------------------------------------------------------------------------
    class scoreboard;
        int total, passed, failed;                     // Счётчики
        logic [31:0] expected_mem [0:31];               // Ожидаемые значения в памяти (32 слова)

        function new();
            integer i;
            total = 0; passed = 0; failed = 0;
            for (i = 0; i < 32; i++) expected_mem[i] = 'x;  // Инициализация неопределённым значением
        endfunction

        function void pass(string msg);
            total++; passed++;
            $display("[SCOREBOARD] PASS: %s", msg);
        endfunction

        function void fail(string msg);
            total++; failed++;
            $display("[SCOREBOARD] FAIL: %s", msg);
        endfunction

        // Запомнить ожидаемое значение при записи
        function void expect_write(logic [4:0] addr, logic [31:0] data);
            expected_mem[addr] = data;
            // При изменении a0 или a1 автоматически пересчитать геометрическую прогрессию
            if ((addr == 0) || (addr == 1))
                update_expected_geom();
        endfunction

        // Запомнить ожидаемое значение при чтении (в тестах)
        function void expect_read(logic [4:0] addr, logic [31:0] data);
            expected_mem[addr] = data;
        endfunction

        // Функция пересчёта ожидаемых значений геометрической прогрессии (14 членов)
        function void update_expected_geom();
            logic [31:0] q, cur;
            integer i;
            if (expected_mem[0] === 'x || expected_mem[1] === 'x) return;
            if (expected_mem[0] == 0) return;
            q = expected_mem[1] / expected_mem[0];
            cur = expected_mem[0] * q * q;   // a0 * q^2 – третий член
            for (i = 0; i < 14; i++) begin
                expected_mem[16 + i] = cur;
                cur = cur * q;
            end
        endfunction

        // Проверка фактической транзакции (write/read) по ожидаемым данным
        function void check_actual(trans_t tr);
            if (expected_mem[tr.addr] === 'x) begin
                fail($sformatf("Addr 0x%0h unexpected transaction", tr.addr));
                return;
            end
            if (tr.wr_en) begin   // Запись
                if (expected_mem[tr.addr] === tr.data)
                    pass($sformatf("Write addr=0x%0h data=0x%0h", tr.addr, tr.data));
                else
                    fail($sformatf("Write addr=0x%0h expected=0x%0h got=0x%0h",
                                   tr.addr, expected_mem[tr.addr], tr.data));
            end else begin        // Чтение
                if (expected_mem[tr.addr] === tr.data)
                    pass($sformatf("Read addr=0x%0h data=0x%0h", tr.addr, tr.data));
                else
                    fail($sformatf("Read addr=0x%0h expected=0x%0h got=0x%0h",
                                   tr.addr, expected_mem[tr.addr], tr.data));
            end
        endfunction

        // Вывод итогового отчёта
        function void report();
            $display("\n[SCOREBOARD] Total: %0d, Passed: %0d, Failed: %0d",
                     total, passed, failed);
            if (failed == 0) $display("[SCOREBOARD] ALL TESTS PASSED\n");
            else $display("[SCOREBOARD] %0d TEST(S) FAILED\n", failed);
        endfunction
    endclass

    // ------------------------------------------------------------------------
    // Агент внешнего интерфейса – реализует ОЗУ на 32 слова и системную функцию
    // (геометрическая прогрессия для варианта 11)
    // ------------------------------------------------------------------------
    class agent_ext;
        logic [31:0] mem [0:31];    // Память на 32 слова, адреса 0..15 – данные конвертера, 16..31 – результаты
        scoreboard sb;

        function new(scoreboard sb);
            this.sb = sb;
        endfunction

        // Обработка записи от конвертера
        function void handle_write(trans_t tr);
            mem[tr.addr] = tr.data;
            $display("[%0t] AGENT: Write addr=0x%0h data=0x%0h", $time, tr.addr, tr.data);
            // При изменении a0 или a1 запустить расчёт геометрической прогрессии
            if ((tr.addr == 0) || (tr.addr == 1)) begin
                if ((mem[0] != 0) && (mem[1] != 0))
                    update_geometric();
            end
            sb.check_actual(tr);   // Сверить с ожиданием
        endfunction

        // Обработка чтения: возвращаем данные из памяти
        function void handle_read(ref trans_t tr);
            tr.data = mem[tr.addr];
            $display("[%0t] AGENT: Read addr=0x%0h data=0x%0h", $time, tr.addr, tr.data);
            sb.check_actual(tr);
        endfunction

        // Расчёт 14 членов геометрической прогрессии и запись в ячейки 16..29
        function void update_geometric();
            logic [31:0] a0, a1, q, cur;
            integer i;
            a0 = mem[0];
            a1 = mem[1];
            if (a0 == 0) return;
            q = a1 / a0;
            cur = a0 * q * q;      // Первый генерируемый член (a0 * q^2)
            $display("[%0t] GEOM: a0=0x%0h, a1=0x%0h, q=0x%0h", $time, a0, a1, q);
            for (i = 0; i < 14; i++) begin
                mem[16 + i] = cur;
                $display("[%0t] GEOM: mem[%0d] = 0x%0h", $time, 16+i, cur);
                cur = cur * q;
                if (cur == 0 && q != 0) break;   // Предотвращение переполнения/зацикливания
            end
        endfunction
    endclass

    // ------------------------------------------------------------------------
    // Драйвер внутреннего (APB) интерфейса – реализует сигнальные протоколы APB
    // ------------------------------------------------------------------------
    class drv_int;
        virtual apb_if vif;   // Указатель на интерфейс APB

        function new(virtual apb_if vif);
            this.vif = vif;
        endfunction

        // Задача записи в регистр APB
        task write(input [15:0] addr, input [31:0] data);
            if (VERBOSE) $display("[%0t] APB WRITE INITIATED: Addr=0x%0h, Data=0x%0h", $time, addr, data);
            @(posedge vif.clk);
            vif.psel    = 1;
            vif.penable = 0;       // Первый такт – адресная фаза
            vif.pwrite  = 1;
            vif.paddr   = addr;
            vif.pwdata  = data;
            @(posedge vif.clk);
            vif.penable = 1;       // Второй такт – фаза данных
            while (!vif.pready) @(posedge vif.clk);  // Ждём готовности
            @(posedge vif.clk);
            vif.psel    = 0;
            vif.penable = 0;
            if (VERBOSE) $display("[%0t] APB WRITE COMPLETED: Addr=0x%0h, Data=0x%0h, %s",
                     $time, addr, data, vif.pslverr ? "FAILED (SLVERR)" : "SUCCESS");
        endtask

        // Задача чтения из регистра APB
        task read(input [15:0] addr, output [31:0] data);
            if (VERBOSE) $display("[%0t] APB READ INITIATED: Addr=0x%0h", $time, addr);
            @(posedge vif.clk);
            vif.psel    = 1;
            vif.penable = 0;
            vif.pwrite  = 0;
            vif.paddr   = addr;
            @(posedge vif.clk);
            vif.penable = 1;
            while (!vif.pready) @(posedge vif.clk);
            data = vif.prdata;
            @(posedge vif.clk);
            vif.psel    = 0;
            vif.penable = 0;
            if (VERBOSE) $display("[%0t] APB READ COMPLETED: Addr=0x%0h, Data=0x%0h, %s",
                     $time, addr, data, vif.pslverr ? "FAILED (SLVERR)" : "SUCCESS");
        endtask
    endclass

// ============================================================================
// Драйвер внешнего параллельного интерфейса (исправленная версия)
// Поддерживает одиночные и потоковые транзакции.
// ============================================================================
class drv_ext;
    virtual parallel_if vif;
    agent_ext agent;

    function new(virtual parallel_if vif, agent_ext agent);
        this.vif = vif;
        this.agent = agent;
    endfunction

    // Основной цикл обработки: перехватываем начало транзакции,
    // затем в цикле обрабатываем все слова, пока не получим done,
    // и только после done ждём возврата ext_cmd в 00.
    task run();
        trans_t t;
        logic [15:0] wdata_low;

        forever begin
            // Ждём начала любой активности (ext_cmd != 00)
            while (vif.ext_cmd == 2'b00) @(posedge vif.clk);
            if (VERBOSE) $display("[%0t] EXT: Transaction started, cmd=0x%0h", $time, vif.ext_cmd);

            // Обрабатываем все слова, пока не будет поднят done
            while (!vif.ext_done) begin
                // === Адресная фаза ===
                vif.ext_ready = 1;
                while (vif.ext_cmd == 2'b01) @(posedge vif.clk);
                if (VERBOSE) $display("[%0t] EXT: Addr phase done, addr=0x%0h", $time, vif.ext_addr);
                vif.ext_ready = 0;

                t = new();
                t.addr = vif.ext_addr[4:0];   // только младшие 5 бит

                // === Фаза данных (запись или чтение) ===
                if (vif.ext_cmd == 2'b11) begin       // Запись
                    if (VERBOSE) $display("[%0t] EXT: Write data phase started", $time);
                    wdata_low = vif.ext_wdata;        // младшая половина уже на шине
                    // Ждём завершения слова (word_done)
                    while (!vif.ext_word_done) @(posedge vif.clk);
                    t.wr_en = 1;
                    t.data = {vif.ext_wdata, wdata_low};   // собираем 32 бита
                    agent.handle_write(t);
                    if (VERBOSE) $display("[%0t] EXT: Write data received: 0x%0h", $time, t.data);

                end else begin                       // Чтение (ext_cmd == 2'b10)
                    if (VERBOSE) $display("[%0t] EXT: Read data phase started", $time);
                    t.wr_en = 0;
                    agent.handle_read(t);            // получаем данные от агента

                    // Младшая половина
                    vif.ext_rdata = t.data[15:0];
                    vif.ext_ready = 1;
                    // Ждём, пока мастер перейдёт в DATA_HIGH (high_phase=1)
                    while (vif.ext_half !== 1'b1) @(posedge vif.clk);
                    vif.ext_ready = 0;

                    // Старшая половина
                    vif.ext_rdata = t.data[31:16];
                    vif.ext_ready = 1;
                    while (!vif.ext_word_done) @(posedge vif.clk);
                    vif.ext_ready = 0;
                    if (VERBOSE) $display("[%0t] EXT: Read data sent: 0x%0h", $time, t.data);
                end

                // === Подтверждение (ack) ===
                vif.ext_ack = 1;
                // Держим ack, пока мастер не уберёт word_done (покинет WAIT_ACK)
                while (vif.ext_word_done) @(posedge vif.clk);
                vif.ext_ack = 0;

                // Ждём либо следующей адресной фазы, либо завершения всей транзакции
                while (!(vif.ext_done || vif.ext_cmd == 2'b01)) @(posedge vif.clk);
            end

            // Транзакция полностью завершена (done = 1).
            // Ждём возврата шины в idle (ext_cmd = 00)
            while (vif.ext_cmd != 2'b00) @(posedge vif.clk);
            if (VERBOSE) $display("[%0t] EXT: Transaction completed", $time);
        end
    endtask
endclass

    // ------------------------------------------------------------------------
    // Базовый класс для тестов (ABC – абстрактный)
    // ------------------------------------------------------------------------
    virtual class ABC_TEST;
        protected drv_int    drv;       // Драйвер APB
        protected scoreboard sb;        // Scoreboard
        protected string     name;      // Имя теста (для вывода)

        function new(drv_int d, scoreboard s, string n);
            this.drv = d; this.sb = s; this.name = n;
        endfunction

        pure virtual task run();       // Абстрактный метод – должен быть определён в наследнике

        // Ожидание завершения операции конвертером (опрос статуса)
        task wait_busy_done();
            logic [31:0] status;
            do begin
                drv.read(16'h0000, status);
                @(posedge drv.vif.clk);
            end while (status[0] != 0); // Ждём, пока статус "свободен" (0)
        endtask
    endclass

    // ------------------------------------------------------------------------
    // Тест "одиночная запись"
    // ------------------------------------------------------------------------
    class test_single_write extends ABC_TEST;
        logic [15:0] addr;
        logic [31:0] wdata;

        function new(drv_int drv, scoreboard sb, logic [15:0] a, logic [31:0] wd);
            super.new(drv, sb, "single write");
            this.addr = a; this.wdata = wd;
        endfunction

        task run();
            $display("\n=== %s ===", name);
            sb.expect_write(addr[4:0], wdata);                // Ожидаемое значение в памяти
            drv.write(16'h0008, {16'b0, addr});               // Записать адрес
            drv.write(16'h000C, 32'h1);                       // Команда "одиночная запись"
            drv.write(16'h0010, wdata);                        // Данные
            drv.write(16'h0004, 32'h1);                       // Запуск
            drv.write(16'h0004, 32'h0);                       // Сброс управляющего бита
            wait_busy_done();
        endtask
    endclass

    // ------------------------------------------------------------------------
    // Тест "одиночное чтение"
    // ------------------------------------------------------------------------
    class test_single_read extends ABC_TEST;
        logic [15:0] addr;
        logic [31:0] expected;

        function new(drv_int drv, scoreboard sb, logic [15:0] a, logic [31:0] e);
            super.new(drv, sb, "single read");
            this.addr = a; this.expected = e;
        endfunction

        task run();
            logic [31:0] rd;
            $display("\n=== %s ===", name);
            sb.expect_read(addr[4:0], expected);
            drv.write(16'h0008, {16'b0, addr});
            drv.write(16'h000C, 32'h0);               // Команда "чтение"
            drv.write(16'h0004, 32'h1);               // Запуск
            drv.write(16'h0004, 32'h0);
            wait_busy_done();
            drv.read(16'h0010, rd);                   // Прочитать полученные данные
            $display("Read data = 0x%08X, expected 0x%08X", rd, expected);
        endtask
    endclass

    // ------------------------------------------------------------------------
    // Тест "геометрическая прогрессия"
    // ------------------------------------------------------------------------
    class test_geom_progression extends ABC_TEST;
        logic [31:0] a0_val, a1_val;   // Первые два члена

        function new(drv_int drv, scoreboard sb, logic [31:0] a0, logic [31:0] a1);
            super.new(drv, sb, "geometric progression");
            this.a0_val = a0; this.a1_val = a1;
        endfunction

        task run();
            logic [31:0] q, cur, rd;
            integer i;
            $display("\n=== %s ===", name);

            // Запись первого члена (a0) по адресу 0
            sb.expect_write(5'h0, a0_val);
            drv.write(16'h0008, 32'h0000_0000);   // Адрес = 0
            drv.write(16'h000C, 32'h1);           // Команда "одиночная запись"
            drv.write(16'h0010, a0_val);          // Данные = a0
            drv.write(16'h0004, 32'h1); drv.write(16'h0004, 32'h0);
            wait_busy_done();

            // Запись второго члена (a1) по адресу 1
            sb.expect_write(5'h1, a1_val);
            drv.write(16'h0008, 32'h0000_0001);   // Адрес = 1
            drv.write(16'h000C, 32'h1);
            drv.write(16'h0010, a1_val);
            drv.write(16'h0004, 32'h1); drv.write(16'h0004, 32'h0);
            wait_busy_done();

            // Чтение сгенерированной прогрессии (ячейки 16..29)
            q = a1_val / a0_val;
            cur = a0_val * q * q;   // Первый генерируемый член
            for (i = 0; i < 14; i++) begin
                sb.expect_read(5'(16 + i), cur);
                drv.write(16'h0008, 32'(16 + i));    // Адрес чтения
                drv.write(16'h000C, 32'h0);          // Команда "чтение"
                drv.write(16'h0004, 32'h1); drv.write(16'h0004, 32'h0);
                wait_busy_done();
                drv.read(16'h0010, rd);
                $display("addr 0x%0h = 0x%0h (expected 0x%0h)", 16 + i, rd, cur);
                cur = cur * q;
            end
        endtask
    endclass

    // ------------------------------------------------------------------------
    // Тест "проверка ошибок PSLVERR"
    // ------------------------------------------------------------------------
    class test_pslverr extends ABC_TEST;
        function new(drv_int drv, scoreboard sb);
            super.new(drv, sb, "PSLVERR");
        endfunction

        task run();
            logic [31:0] dummy;
            $display("\n=== %s ===", name);

            // Запись в статусный регистр (адрес 0x00) должна вызвать ошибку
            drv.write(16'h0000, 32'h1);
            if (drv.vif.pslverr === 1'b1) sb.pass("PSLVERR write STATUS blocked");
            else                            sb.fail("PSLVERR write STATUS should be blocked");

            // Чтение регистра управления (адрес 0x04) запрещено
            drv.read(16'h0004, dummy);
            if (drv.vif.pslverr === 1'b1) sb.pass("PSLVERR read CTRL blocked");
            else                            sb.fail("PSLVERR read CTRL should be blocked");

            // Обращение к несуществующему адресу (0x14) должно вызвать ошибку
            drv.read(16'h0014, dummy);
            if (drv.vif.pslverr === 1'b1) sb.pass("PSLVERR invalid address blocked");
            else                            sb.fail("PSLVERR invalid address should be blocked");
        endtask
    endclass
// ===========================================================================
// Тест "потоковая запись" (Stream Write)
// Проверяет команду 2: запись 4 слов в ОЗУ с последующей передачей наружу.
// ===========================================================================
class test_stream_write extends ABC_TEST;
    logic [4:0]  base_addr;   // базовый адрес в ОЗУ (5 бит)
    logic [31:0] wdata[4];    // массив 4 записываемых слов

    function new(drv_int drv, scoreboard sb, logic [4:0] base,
                 logic [31:0] d0, d1, d2, d3);
        super.new(drv, sb, "stream write");
        base_addr = base;
        wdata[0] = d0; wdata[1] = d1; wdata[2] = d2; wdata[3] = d3;
    endfunction

    task run();
        $display("\n=== %s ===", name);

        for (int i = 0; i < 4; i++)
            sb.expect_write(base_addr + i, wdata[i]);

        // Потоковая запись
        drv.write(16'h0008, {11'b0, base_addr});
        drv.write(16'h000C, 32'h2);                // команда потоковой записи
        foreach (wdata[i])
            drv.write(16'h0010, wdata[i]);         // четыре слова данных
        drv.write(16'h0004, 32'h1);                // старт
        drv.write(16'h0004, 32'h0);
        wait_busy_done();

        // Проверка: одиночные чтения через конвертер
        for (int i = 0; i < 4; i++) begin
            logic [31:0] rd;
            // Установить адрес
            drv.write(16'h0008, {11'b0, base_addr + i});
            // Команда чтения
            drv.write(16'h000C, 32'h0);
            // Запуск
            drv.write(16'h0004, 32'h1);
            drv.write(16'h0004, 32'h0);
            wait_busy_done();
            // Прочитать данные
            drv.read(16'h0010, rd);
            $display("Addr 0x%0h = 0x%0h (expected 0x%0h)", base_addr + i, rd, wdata[i]);
        end
    endtask
endclass

// ===========================================================================
// Тест "потоковое чтение" (Stream Read)
// Проверяет команду 3: чтение 4 слов из внешнего агента через ОЗУ в APB.
// Предварительно заполняем память агента одиночными записями.
// ===========================================================================
class test_stream_read extends ABC_TEST;
    logic [4:0]  base_addr;
    logic [31:0] expected[4];

    function new(drv_int drv, scoreboard sb, logic [4:0] base,
                 logic [31:0] e0, e1, e2, e3);
        super.new(drv, sb, "stream read");
        base_addr = base;
        expected[0] = e0; expected[1] = e1; expected[2] = e2; expected[3] = e3;
    endfunction

    task run();
        $display("\n=== %s ===", name);

        // 1. Заполняем память агента одиночными записями
        for (int i = 0; i < 4; i++) begin
            sb.expect_write(base_addr + i, expected[i]);
            drv.write(16'h0008, {11'b0, base_addr + i});
            drv.write(16'h000C, 32'h1);
            drv.write(16'h0010, expected[i]);
            drv.write(16'h0004, 32'h1);
            drv.write(16'h0004, 32'h0);
            wait_busy_done();
        end

        // 2. Потоковое чтение (команда 3)
        drv.write(16'h0008, {11'b0, base_addr});
        drv.write(16'h000C, 32'h3);
        drv.write(16'h0004, 32'h1);
        drv.write(16'h0004, 32'h0);
        wait_busy_done();
    endtask
endclass

endpackage