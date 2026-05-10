// ============================================================
// Единый файл с классами верификации (без mailbox)
// ============================================================

// ----- Класс транзакции -----
class trans_t;
    bit          wr_en;
    logic [4:0]  addr;
    logic [31:0] data;
endclass

// ----- Scoreboard -----
class scoreboard;
    int total, passed, failed;
    logic [31:0] expected_mem [0:31];

    function new();
        integer i;
        total = 0; passed = 0; failed = 0;
        for (i = 0; i < 32; i++) expected_mem[i] = 'x;
    endfunction

    function void pass(string msg);
        total++; passed++;
        $display("[SCOREBOARD] PASS: %s", msg);
    endfunction

    function void fail(string msg);
        total++; failed++;
        $display("[SCOREBOARD] FAIL: %s", msg);
    endfunction

    function void expect_write(logic [4:0] addr, logic [31:0] data);
        expected_mem[addr] = data;
        if ((addr == 0) || (addr == 1))
            update_expected_geom();
    endfunction

    function void expect_read(logic [4:0] addr, logic [31:0] data);
        expected_mem[addr] = data;
    endfunction

    function void update_expected_geom();
        logic [31:0] q, cur;
        integer i;
        if (expected_mem[0] === 'x || expected_mem[1] === 'x) return;
        if (expected_mem[0] == 0) return;
        q = expected_mem[1] / expected_mem[0];
        cur = expected_mem[0] * q * q;
        for (i = 0; i < 14; i++) begin
            expected_mem[16 + i] = cur;
            cur = cur * q;
        end
    endfunction

    task check_actual(trans_t tr);
        if (expected_mem[tr.addr] === 'x) begin
            fail($sformatf("Addr 0x%0h unexpected transaction", tr.addr));
            return;
        end
        if (tr.wr_en) begin
            if (expected_mem[tr.addr] === tr.data)
                pass($sformatf("Write addr=0x%0h data=0x%0h", tr.addr, tr.data));
            else
                fail($sformatf("Write addr=0x%0h expected=0x%0h got=0x%0h",
                               tr.addr, expected_mem[tr.addr], tr.data));
        end else begin
            if (expected_mem[tr.addr] === tr.data)
                pass($sformatf("Read addr=0x%0h data=0x%0h", tr.addr, tr.data));
            else
                fail($sformatf("Read addr=0x%0h expected=0x%0h got=0x%0h",
                               tr.addr, expected_mem[tr.addr], tr.data));
        end
    endtask

    function void report();
        $display("\n[SCOREBOARD] Total: %0d, Passed: %0d, Failed: %0d",
                 total, passed, failed);
        if (failed == 0) $display("[SCOREBOARD] ALL TESTS PASSED\n");
        else $display("[SCOREBOARD] %0d TEST(S) FAILED\n", failed);
    endfunction
endclass

// ----- Внешний агент (память + геометрическая прогрессия) -----
class agent_ext;
    logic [31:0] mem [0:31];
    scoreboard sb;

    function new(scoreboard sb);
        this.sb = sb;
    endfunction

    task run();
        // в данной архитектуре не используется, оставлен для совместимости
        forever @(posedge sb);
    endtask

    function void handle_write(trans_t tr);
        mem[tr.addr] = tr.data;
        if ((tr.addr == 0) || (tr.addr == 1)) begin
            if ((mem[0] != 0) && (mem[1] != 0))
                update_geometric();
        end
        sb.check_actual(tr);
    endfunction

    function void handle_read(ref trans_t tr);
        tr.data = mem[tr.addr];
        sb.check_actual(tr);
    endfunction

    function void update_geometric();
        logic [31:0] a0, a1, q, cur;
        integer i;
        a0 = mem[0];
        a1 = mem[1];
        if (a0 == 0) return;
        q = a1 / a0;
        cur = a0 * q * q;
        for (i = 0; i < 14; i++) begin
            mem[16 + i] = cur;
            cur = cur * q;
            if (cur == 0 && q != 0) break;
        end
    endfunction
endclass

// ----- Драйвер внутреннего APB -----
class drv_int;
    virtual apb_if vif;

    function new(virtual apb_if vif);
        this.vif = vif;
    endfunction

    task write(input [15:0] addr, input [31:0] data);
        @(posedge vif.clk);
        vif.psel    = 1;
        vif.penable = 0;
        vif.pwrite  = 1;
        vif.paddr   = addr;
        vif.pwdata  = data;
        @(posedge vif.clk);
        vif.penable = 1;
        while (!vif.pready) @(posedge vif.clk);
        @(posedge vif.clk);
        vif.psel    = 0;
        vif.penable = 0;
    endtask

    task read(input [15:0] addr, output [31:0] data);
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
    endtask
endclass

class drv_ext;
    virtual parallel_if vif;
    agent_ext agent;

    function new(virtual parallel_if vif, agent_ext agent);
        this.vif = vif;
        this.agent = agent;
    endfunction

    task run();
        forever begin
            while (vif.ext_cmd == 2'b00) @(posedge vif.clk);
            // адресная фаза
            vif.ext_ready = 1;
            while (vif.ext_cmd == 2'b01) @(posedge vif.clk);
            vif.ext_ready = 0;

            if (vif.ext_stream) begin
                case (vif.ext_cmd)
                    2'b10: stream_read();
                    2'b11: stream_write();
                endcase
            end else begin
                case (vif.ext_cmd)
                    2'b10: single_read();
                    2'b11: single_write();
                endcase
                while (vif.ext_cmd != 2'b00) @(posedge vif.clk);
                vif.ext_ready = 0;
                vif.ext_ack   = 0;
            end
        end
    endtask

    task single_write();
        trans_t t;
        logic [31:0] wd;
        t = new();
        t.wr_en = 1;
        t.addr  = vif.ext_addr[4:0];
        // ждём, пока parallel_master выдаст данные
        while (!vif.ext_word_done) @(posedge vif.clk);
        wd[15:0] = vif.ext_wdata;    // младшие 16 бит
        // старшие 16 бит появляются на шине в DATA_HIGH и держатся в WAIT_ACK
        wd[31:16] = vif.ext_wdata;
        t.data = wd;
        agent.handle_write(t);
        // подтверждаем
        vif.ext_ack = 1;
        // ждём завершения транзакции (done)
        while (!vif.ext_done) @(posedge vif.clk);
        vif.ext_ack = 0;
    endtask

    task single_read();
        trans_t t;
        t = new();
        t.wr_en = 0;
        t.addr  = vif.ext_addr[4:0];
        agent.handle_read(t);
        // передаём младшие 16 бит
        vif.ext_rdata = t.data[15:0];
        vif.ext_ready = 1;
        while (!vif.ext_word_done) @(posedge vif.clk);
        // передаём старшие 16 бит
        vif.ext_rdata = t.data[31:16];
        while (!vif.ext_word_done) @(posedge vif.clk);
        // ack
        vif.ext_ack = 1;
        while (!vif.ext_done) @(posedge vif.clk);
        vif.ext_ack = 0;
        vif.ext_ready = 0;
    endtask

    task stream_write();
        integer i;
        logic [31:0] wd;
        for (i = 0; i < 4; i++) begin
            while (vif.ext_cmd != 2'b11) @(posedge vif.clk);
            while (!vif.ext_word_done) @(posedge vif.clk);
            wd[15:0] = vif.ext_wdata;
            wd[31:16] = vif.ext_wdata;
            trans_t t = new();
            t.wr_en = 1;
            t.addr  = vif.ext_addr[4:0];
            t.data  = wd;
            agent.handle_write(t);
            vif.ext_ack = 1;
            while (!vif.ext_done) @(posedge vif.clk);
            vif.ext_ack = 0;
            if (i < 3) begin
                // ждём следующей адресной фазы
                while (vif.ext_cmd != 2'b01) @(posedge vif.clk);
                vif.ext_ready = 1;
                while (vif.ext_cmd == 2'b01) @(posedge vif.clk);
                vif.ext_ready = 0;
            end
        end
    endtask

    task stream_read();
        integer i;
        for (i = 0; i < 4; i++) begin
            while (vif.ext_cmd != 2'b10) @(posedge vif.clk);
            trans_t t = new();
            t.wr_en = 0;
            t.addr  = vif.ext_addr[4:0];
            agent.handle_read(t);
            vif.ext_rdata = t.data[15:0];
            vif.ext_ready = 1;
            while (!vif.ext_word_done) @(posedge vif.clk);
            vif.ext_rdata = t.data[31:16];
            while (!vif.ext_word_done) @(posedge vif.clk);
            vif.ext_ack = 1;
            while (!vif.ext_done) @(posedge vif.clk);
            vif.ext_ack = 0;
            vif.ext_ready = 0;
            if (i < 3) begin
                while (vif.ext_cmd != 2'b01) @(posedge vif.clk);
                vif.ext_ready = 1;
                while (vif.ext_cmd == 2'b01) @(posedge vif.clk);
                vif.ext_ready = 0;
            end
        end
    endtask
endclass

// ----- Тестовые классы -----

virtual class ABC_TEST;
    protected drv_int    drv;
    protected scoreboard sb;
    protected string     name;

    function new(drv_int d, scoreboard s, string n);
        this.drv = d; this.sb = s; this.name = n;
    endfunction

    pure virtual task run();

    task wait_busy_done();
        logic [31:0] status;
        do begin
            drv.read(16'h0000, status);
        end while (status[0] != 0);
    endtask
endclass

class test_single_write extends ABC_TEST;
    logic [15:0] addr;
    logic [31:0] wdata;

    function new(drv_int drv, scoreboard sb, logic [15:0] a, logic [31:0] wd);
        super.new(drv, sb, "single write");
        this.addr = a; this.wdata = wd;
    endfunction

    task run();
        $display("\n=== %s ===", name);
        sb.expect_write(addr[4:0], wdata);
        drv.write(16'h0008, {16'b0, addr});
        drv.write(16'h000C, 32'h1);
        drv.write(16'h0010, wdata);
        drv.write(16'h0004, 32'h1);
        drv.write(16'h0004, 32'h0);
        wait_busy_done();
    endtask
endclass

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
        drv.write(16'h000C, 32'h0);
        drv.write(16'h0004, 32'h1);
        drv.write(16'h0004, 32'h0);
        wait_busy_done();
        drv.read(16'h0010, rd);
        $display("Read data = 0x%08X, expected 0x%08X", rd, expected);
    endtask
endclass

class test_geom_progression extends ABC_TEST;
    logic [31:0] a0_val, a1_val;

    function new(drv_int drv, scoreboard sb, logic [31:0] a0, logic [31:0] a1);
        super.new(drv, sb, "geometric progression");
        this.a0_val = a0; this.a1_val = a1;
    endfunction

    task run();
        logic [31:0] q, cur, rd;
        integer i;
        $display("\n=== %s ===", name);
        sb.expect_write(5'h0, a0_val);
        drv.write(16'h0008, 32'h0000_0000);
        drv.write(16'h000C, 32'h1);
        drv.write(16'h0010, a0_val);
        drv.write(16'h0004, 32'h1); drv.write(16'h0004, 32'h0);
        wait_busy_done();

        sb.expect_write(5'h1, a1_val);
        drv.write(16'h0008, 32'h0000_0001);
        drv.write(16'h000C, 32'h1);
        drv.write(16'h0010, a1_val);
        drv.write(16'h0004, 32'h1); drv.write(16'h0004, 32'h0);
        wait_busy_done();

        q = a1_val / a0_val;
        cur = a0_val * q * q;
        for (i = 0; i < 14; i++) begin
            sb.expect_read(5'(16 + i), cur);
            drv.write(16'h0008, 32'(16 + i));
            drv.write(16'h000C, 32'h0);
            drv.write(16'h0004, 32'h1); drv.write(16'h0004, 32'h0);
            wait_busy_done();
            drv.read(16'h0010, rd);
            $display("addr 0x%0h = 0x%0h (expected 0x%0h)", 16 + i, rd, cur);
            cur = cur * q;
        end
    endtask
endclass

class test_pslverr extends ABC_TEST;
    function new(drv_int drv, scoreboard sb);
        super.new(drv, sb, "PSLVERR");
    endfunction

    task run();
        logic [31:0] dummy;
        $display("\n=== %s ===", name);
        drv.write(16'h0000, 32'h1);
        if (drv.vif.pslverr === 1'b1) sb.pass("PSLVERR write STATUS blocked");
        else                            sb.fail("PSLVERR write STATUS should be blocked");

        drv.read(16'h0004, dummy);
        if (drv.vif.pslverr === 1'b1) sb.pass("PSLVERR read CTRL blocked");
        else                            sb.fail("PSLVERR read CTRL should be blocked");

        drv.read(16'h0014, dummy);
        if (drv.vif.pslverr === 1'b1) sb.pass("PSLVERR invalid address blocked");
        else                            sb.fail("PSLVERR invalid address should be blocked");
    endtask
endclass