package tb_pkg;

class trans_t;
    bit          wr_en;
    logic [4:0]  addr;
    logic [31:0] data;
endclass

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

    function void check_actual(trans_t tr);
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
    endfunction

    function void report();
        $display("\n[SCOREBOARD] Total: %0d, Passed: %0d, Failed: %0d",
                 total, passed, failed);
        if (failed == 0) $display("[SCOREBOARD] ALL TESTS PASSED\n");
        else $display("[SCOREBOARD] %0d TEST(S) FAILED\n", failed);
    endfunction
endclass

class agent_ext;
    logic [31:0] mem [0:31];
    scoreboard sb;

    function new(scoreboard sb);
        this.sb = sb;
    endfunction

    function void handle_write(trans_t tr);
        mem[tr.addr] = tr.data;
        $display("[%0t] AGENT: Write addr=0x%0h data=0x%0h", $time, tr.addr, tr.data);
        if ((tr.addr == 0) || (tr.addr == 1)) begin
            if ((mem[0] != 0) && (mem[1] != 0))
                update_geometric();
        end
        sb.check_actual(tr);
    endfunction

    function void handle_read(ref trans_t tr);
        tr.data = mem[tr.addr];
        $display("[%0t] AGENT: Read addr=0x%0h data=0x%0h", $time, tr.addr, tr.data);
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
        $display("[%0t] GEOM: a0=0x%0h, a1=0x%0h, q=0x%0h", $time, a0, a1, q);
        for (i = 0; i < 14; i++) begin
            mem[16 + i] = cur;
            $display("[%0t] GEOM: mem[%0d] = 0x%0h", $time, 16+i, cur);
            cur = cur * q;
            if (cur == 0 && q != 0) break;
        end
    endfunction
endclass

class drv_int;
    virtual apb_if vif;

    function new(virtual apb_if vif);
        this.vif = vif;
    endfunction

    task write(input [15:0] addr, input [31:0] data);
        $display("[%0t] APB WRITE INITIATED: Addr=0x%0h, Data=0x%0h", $time, addr, data);
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
        $display("[%0t] APB WRITE COMPLETED: Addr=0x%0h, Data=0x%0h, %s",
                 $time, addr, data, vif.pslverr ? "FAILED (SLVERR)" : "SUCCESS");
    endtask

    task read(input [15:0] addr, output [31:0] data);
        $display("[%0t] APB READ INITIATED: Addr=0x%0h", $time, addr);
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
        $display("[%0t] APB READ COMPLETED: Addr=0x%0h, Data=0x%0h, %s",
                 $time, addr, data, vif.pslverr ? "FAILED (SLVERR)" : "SUCCESS");
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
        trans_t t;
        logic [15:0] wdata_low;

        forever begin
            while (vif.ext_cmd == 2'b00) @(posedge vif.clk);
            $display("[%0t] EXT: Transaction started, cmd=0x%0h", $time, vif.ext_cmd);

            // Адресная фаза
            vif.ext_ready = 1;
            while (vif.ext_cmd == 2'b01) @(posedge vif.clk);
            $display("[%0t] EXT: Addr phase done, addr=0x%0h", $time, vif.ext_addr);
            vif.ext_ready = 0;

            t = new();
            t.addr = vif.ext_addr[4:0];

            if (vif.ext_cmd == 2'b11) begin       // Запись
                $display("[%0t] EXT: Write data phase started", $time);
                wdata_low = vif.ext_wdata;
                while (!vif.ext_word_done) @(posedge vif.clk);
                t.wr_en = 1;
                t.data = {vif.ext_wdata, wdata_low};
                agent.handle_write(t);
                $display("[%0t] EXT: Write data received: 0x%0h", $time, t.data);

                vif.ext_ack = 1;
                while (!vif.ext_done) @(posedge vif.clk);
                vif.ext_ack = 0;
                $display("[%0t] EXT: Write transaction completed", $time);
            end else begin                       // Чтение
                $display("[%0t] EXT: Read data phase started", $time);
                t.wr_en = 0;
                agent.handle_read(t);

                // Младшие 16 бит
                vif.ext_rdata = t.data[15:0];
                vif.ext_ready = 1;
                while (!vif.ext_word_done) @(posedge vif.clk);
                vif.ext_ready = 0;

                // Старшие 16 бит
                vif.ext_rdata = t.data[31:16];
                vif.ext_ready = 1;
                while (!vif.ext_word_done) @(posedge vif.clk);
                vif.ext_ready = 0;

                $display("[%0t] EXT: Read data sent: 0x%0h", $time, t.data);

                vif.ext_ack = 1;
                while (!vif.ext_done) @(posedge vif.clk);
                vif.ext_ack = 0;
                $display("[%0t] EXT: Read transaction completed", $time);
            end

            while (vif.ext_cmd != 2'b00) @(posedge vif.clk);
        end
    endtask
endclass

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

endpackage