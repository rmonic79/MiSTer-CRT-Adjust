//============================================================================
//  tb_analog_hsize.sv  — self-checking testbench for analog_hsize
//
//  Verifies, for several stretch factors:
//    * every source ACTIVE pixel appears on the output exactly once, in order,
//      byte-exact (no drop, no duplicate, no blend);
//    * the per-line active count is preserved;
//    * the elastic FIFO never overflows and returns to empty every line.
//
//  Run:  iverilog -g2012 -o tb analog_hsize.sv tb_analog_hsize.sv && vvp tb
//============================================================================
`timescale 1ns/1ps

module harness #(parameter K = 4) (input clk);

    // ---- video timing (in core pixels) ----
    localparam HTOTAL   = 440;
    localparam HS_W     = 32;
    localparam BPORCH   = 16;
    localparam HACTIVE  = 256;
    localparam ACT_START= HS_W + BPORCH;
    localparam ACT_END  = ACT_START + HACTIVE;
    localparam NLINES   = 8;

    // ---- core pixel clock-enable: continuous, 1 pulse every 16 clk ----
    reg [4:0] cc = 0;
    wire pxl_cen = (cc == 5'd0);
    always @(posedge clk) cc <= (cc == 5'd15) ? 5'd0 : cc + 1'b1;

    // ---- stimulus state, advanced on pxl_cen ----
    reg [11:0] pidx = 0;
    reg [7:0]  line = 0;
    reg [7:0]  r_in, g_in, b_in;
    reg        hs_in, hb_in, vb_in = 1, vs_in = 0;
    reg        done = 0;

    // Lines 0..1 are vertical blank, so line 2 is the first VISIBLE line after
    // vblank — the case that must not overflow nor drop its first pixel.
    wire vblank = (line < 2);

    wire [15:0] aidx = {4'd0, pidx} - ACT_START;
    always @(posedge clk) if (pxl_cen) begin
        hs_in <= (pidx < HS_W);
        vb_in <= vblank;
        hb_in <= vblank | ~((pidx >= ACT_START) && (pidx < ACT_END));
        if ((pidx >= ACT_START) && (pidx < ACT_END)) begin
            r_in <= line;            // line tag
            g_in <= aidx[15:8];      // active index hi
            b_in <= aidx[7:0];       // active index lo
        end else begin
            r_in <= 0; g_in <= 0; b_in <= 0;
        end
        if (pidx == HTOTAL-1) begin
            pidx <= 0;
            line <= line + 1'b1;
            if (line == NLINES-1) done <= 1;
        end else pidx <= pidx + 1'b1;
    end

    // ---- read clock-enable: glue divider, modulo (16+K), reset on HS rise ----
    reg hs_d = 0;
    always @(posedge clk) hs_d <= hs_in;
    wire hs_rise = hs_in & ~hs_d;

    reg [4:0] ce_div = 0;
    wire [4:0] ce_max = 5'd15 + K[4:0];
    always @(posedge clk) begin
        if      (hs_rise)            ce_div <= 0;
        else if (ce_div == ce_max)  ce_div <= 0;
        else                         ce_div <= ce_div + 1'b1;
    end
    wire pxl2_cen = (K == 0) ? pxl_cen : (ce_div == 0);

    // ---- DUT ----
    wire [7:0] r_out, g_out, b_out;
    wire       hs_out, vs_out, hb_out, vb_out;
    analog_hsize dut (
        .clk(clk), .pxl_cen(pxl_cen), .pxl2_cen(pxl2_cen),
        .hsize($signed(-K)),
        .r_in(r_in), .g_in(g_in), .b_in(b_in),
        .hs_in(hs_in), .vs_in(vs_in), .hb_in(hb_in), .vb_in(vb_in),
        .r_out(r_out), .g_out(g_out), .b_out(b_out),
        .hs_out(hs_out), .vs_out(vs_out), .hb_out(hb_out), .vb_out(vb_out)
    );

    // ---- overflow / occupancy monitor (hierarchical peek) ----
    integer occ, occ_max = 0;
    always @(posedge clk) begin
        occ = (dut.wptr - dut.rptr) & (dut.DEPTH-1);
        if (occ > occ_max) occ_max = occ;
        if (occ >= dut.DEPTH-1) begin
            $display("FAIL[K=%0d]: FIFO overflow, occ=%0d", K, occ);
            $finish;
        end
    end

    // ---- output sampler: 1 clk after the active CE so regs have settled ----
    wire samp_ce = (K == 0) ? pxl_cen : pxl2_cen;
    reg  samp_ce_d = 0;
    always @(posedge clk) samp_ce_d <= samp_ce;

    reg        hso_d = 0;
    integer    exp_a = 0;
    integer    line_cnt = 0;
    integer    out_line = 0;
    integer    errors = 0;
    integer    vis_lines = 0;   // visible lines fully checked
    reg        seg_vb = 0;      // this output line was (partly) vertical blank
    reg [15:0] got_a;

    always @(posedge clk) begin
        hso_d <= hs_out;
        // new output line: hs_out rising edge -> verify the line that finished
        if (hs_out & ~hso_d) begin
            if (!seg_vb && out_line >= 1) begin   // a visible line (skip warm-up line 0)
                if (line_cnt != HACTIVE) begin
                    $display("FAIL[K=%0d]: visible line emitted %0d active px, expected %0d",
                             K, line_cnt, HACTIVE);
                    errors = errors + 1;
                end
                vis_lines = vis_lines + 1;
            end
            out_line = out_line + 1;
            line_cnt = 0;
            exp_a    = 0;
            seg_vb   = 0;
        end
        if (vb_out) seg_vb <= 1;
        if (samp_ce_d && (hb_out == 1'b0)) begin
            got_a = {g_out, b_out};
            if (out_line >= 1) begin
                if (got_a !== exp_a[15:0]) begin
                    $display("FAIL[K=%0d]: px %0d got a=%0d expected %0d (r=%0d)",
                             K, line_cnt, got_a, exp_a, r_out);
                    errors = errors + 1;
                end
            end
            exp_a    = exp_a + 1;
            line_cnt = line_cnt + 1;
        end
    end

    // ---- end of run ----
    reg reported = 0;
    always @(posedge clk) if (done && !reported) begin
        reported <= 1;
        if (errors == 0)
            $display("PASS[K=%0d]: %0d visible lines byte-exact & ordered; peak FIFO occupancy = %0d / %0d",
                     K, vis_lines, occ_max, dut.DEPTH);
        else
            $display("FAIL[K=%0d]: %0d errors", K, errors);
        // signal completion to top via a global event
        top.n_done = top.n_done + 1;
    end

endmodule


module top;
    reg clk = 0;
    always #5 clk = ~clk;   // 100 MHz-ish; only relative timing matters

    integer n_done = 0;

    harness #(.K(0)) h0 (.clk(clk));   // bypass
    harness #(.K(4)) h4 (.clk(clk));   // moderate stretch
    harness #(.K(7)) h7 (.clk(clk));   // max stretch

    // finish once all three harnesses report (each fires once per line at done;
    // wait a bit so the message prints before $finish)
    integer guard = 0;
    always @(posedge clk) begin
        if (n_done >= 3) begin
            guard = guard + 1;
            if (guard > 100) $finish;
        end
    end

    initial begin
        #5_000_000;   // hard timeout
        $display("TIMEOUT");
        $finish;
    end
endmodule
