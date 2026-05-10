package trans_pkg;
    class trans_t;
        bit          wr_en;
        logic [4:0]  addr;
        logic [31:0] data;
        bit          geom_update;
        logic [31:0] a0, a1;
    endclass

    typedef mailbox #(trans_t) trans_mbx;
endpackage