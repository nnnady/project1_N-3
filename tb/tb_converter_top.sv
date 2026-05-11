`timescale 1ns/1ps
import tb_pkg::*;

module tb_converter_top;
    logic clk, rst_n;
    wire psel, penable, pwrite, pready, pslverr;
    wire [15:0] paddr;
    wire [31:0] pwdata, prdata;

    wire        ext_ready, ext_ack, ext_stream, ext_word_done, ext_tick;
    wire [15:0] ext_addr;
    wire [1:0]  ext_cmd;
    wire [15:0] ext_wdata, ext_rdata;
    wire ext_half;

    converter_top dut (
        .clk, .rst_n,
        .psel, .penable, .pwrite, .paddr, .pwdata, .prdata, .pready, .pslverr,
        .ext_ready_i(ext_ready), .ext_ack_i(ext_ack), .ext_rdata_i(ext_rdata),
        .ext_addr_o(ext_addr), .ext_cmd_o(ext_cmd), .ext_data_o(ext_wdata),
        .ext_stream_o(ext_stream), .ext_half_o(ext_half), .ext_word_done_o(ext_word_done), .ext_tick_o(ext_tick)
    );

    apb_if      apb_vif();
    parallel_if par_vif();

    assign apb_vif.clk    = clk;
    assign apb_vif.rst_n  = rst_n;
    assign apb_vif.prdata = prdata;
    assign apb_vif.pready = pready;
    assign apb_vif.pslverr = pslverr;
    assign psel    = apb_vif.psel;
    assign penable = apb_vif.penable;
    assign pwrite  = apb_vif.pwrite;
    assign paddr   = apb_vif.paddr;
    assign pwdata  = apb_vif.pwdata;

    assign par_vif.ext_half = ext_half;
    assign par_vif.clk   = clk;
    assign par_vif.ext_addr = ext_addr;
    assign par_vif.ext_cmd  = ext_cmd;
    assign par_vif.ext_wdata= ext_wdata;
    assign par_vif.ext_done = dut.u_master.done_o;
    assign par_vif.ext_word_done = ext_word_done;
    assign par_vif.ext_stream   = ext_stream;
    assign par_vif.ext_tick     = ext_tick;
    assign ext_ready = par_vif.ext_ready;
    assign ext_ack   = par_vif.ext_ack;
    assign ext_rdata = par_vif.ext_rdata;

    always #5 clk = ~clk;

    scoreboard  sb;
    drv_int     int_drv;
    agent_ext   agent;
    drv_ext     ext_drv;

    test_single_write       t1;
    test_single_read        t2;
    test_geom_progression   t3;
    test_pslverr            t4;

    initial begin
        clk = 0; rst_n = 0;
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);

        sb      = new();
        agent   = new(sb);
        int_drv = new(apb_vif);
        ext_drv = new(par_vif, agent);

        fork
            ext_drv.run();
        join_none

        t1 = new(int_drv, sb, 16'h0000, 32'hA5A5A5A5);
        t1.run();

        t2 = new(int_drv, sb, 16'h0000, 32'hA5A5A5A5);
        t2.run();

        t3 = new(int_drv, sb, 32'd2, 32'd6);
        t3.run();

        t4 = new(int_drv, sb);
        t4.run();

        #1000;
        sb.report();
        $finish;
    end
endmodule