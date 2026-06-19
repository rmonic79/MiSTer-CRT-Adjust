//============================================================================
//  analog_hsize.sv
//
//  Horizontal pixel-stretch module for the ANALOG VGA output path of a
//  MiSTer FPGA arcade core.
//
//  ─── What it does ──────────────────────────────────────────────────────────
//  Each source pixel is emitted to the DAC for a longer, integer-uniform
//  number of pixel-clock periods. Every pixel of every line is stretched by
//  the same exact factor (no fractional ratio, no nearest-neighbor decisions
//  per-pixel), so there is:
//      - NO shimmering on moving content
//      - NO blending / blur (output = source pixel, byte-exact)
//      - NO line buffer mismatch (deterministic per-line phase)
//
//  The HDMI path is left COMPLETELY untouched: this module is inserted
//  only on the analog VGA branch, after the core's video composition and
//  before the analog DAC pins (typical insertion point in MiSTer is
//  inside sys_top.v, before the OSD overlay).
//
//  ─── Storage: elastic FIFO (was: full-line ping-pong) ───────────────────────
//  The read side is slower than the write side by an integer ratio
//  (16+|hsize|)/16, so within an active line the writer leads the reader by
//  at most  N * |hsize| / (16+|hsize|)  pixels (N = active pixels per line).
//  For a 320-pixel line at the maximum stretch that is ~100 pixels — far less
//  than a whole line. We therefore only need a small elastic FIFO sized to
//  that peak lead instead of a full 1024-deep ping-pong line buffer.
//
//  The FIFO is a single-clock (clk) design with two clock-enables: it is
//  PUSHED on pxl_cen during active video and POPPED on pxl2_cen. Because both
//  ports live in the same clock domain there is no clock-domain crossing and
//  no gray-code pointers are required. With DEPTH=128 the array is 128x24 =
//  3 Kbit, which fits in LUTRAM/MLAB (ramstyle="MLAB") and frees the M10K(s)
//  the previous full-line buffer consumed.
//
//  Invariant that keeps it bounded: the reader only emits pixels the writer
//  has already pushed THIS line (gate emit_cnt < nactive_run), and the read
//  pointer is resynced to the write pointer at every HSync. The FIFO therefore
//  returns to empty every line and never drifts.
//
//  ─── Resource cost ─────────────────────────────────────────────────────────
//  0 M10K, ~6 MLAB + ~80 ALM, 0 DSP  (DEPTH=128).
//
//  ─── Required external signals ─────────────────────────────────────────────
//  pxl_cen   : the core's pixel clock enable (write rate, e.g. 6 MHz pulse
//              on a 96 MHz clk).
//  pxl2_cen  : the DAC read clock enable, SLOWER than pxl_cen by an integer
//              divisor (16+hsize) of clk, generated externally for phase
//              alignment with HSync (see examples/sys_top_snippet.v).
//  hsize     : signed 4-bit, OSD-controlled stretch factor.
//              hsize = 0 → bypass (passthrough at pxl_cen rate)
//              hsize < 0 → progressively wider pixels (the typical use case;
//                          the OSD usually exposes 0..7 unsigned and the
//                          glue logic negates it before connecting).
//
//  ─── License ───────────────────────────────────────────────────────────────
//  Author: Umberto Parisi (rmonic79), 2026.
//  Distributed under GNU GPL v3 or later.
//============================================================================

module analog_hsize
#(
    // FIFO depth (power of two). Must exceed the peak writer-over-reader lead
    // within a line, i.e. N * |hsize| / (16 + |hsize|) where N = active pixels.
    // 128 covers every practical arcade mode: a 320px line at max stretch peaks
    // at ~97, and wider lines (384px) physically can't stretch far enough to
    // approach the limit (the stretched active must still fit the line porches,
    // which forces a small |hsize|, hence a small peak). Raise it only for an
    // unusually wide active region combined with aggressive stretch.
    parameter DEPTH = 128
)
(
    input              clk,
    input              pxl_cen,      // write clock enable (core pixel rate)
    input              pxl2_cen,     // read clock enable  (DAC pixel rate, slower)

    input  signed [3:0] hsize,       // 0 = bypass, !=0 = stretch active

    input        [7:0] r_in,
    input        [7:0] g_in,
    input        [7:0] b_in,
    input              hs_in,
    input              vs_in,
    input              hb_in,
    input              vb_in,

    output reg   [7:0] r_out,
    output reg   [7:0] g_out,
    output reg   [7:0] b_out,
    output reg         hs_out,
    output reg         vs_out,
    output reg         hb_out,
    output reg         vb_out
);

    localparam integer LAW = $clog2(DEPTH);   // FIFO pointer width
    localparam integer CW  = 12;              // active-pixel counter width (>= line width)

    // ------------------------------------------------------------------
    //  Input pipeline @ pxl_cen (for latency matching in bypass mode and
    //  for passing the regenerated sync/blank flags in stretch mode).
    // ------------------------------------------------------------------
    reg [7:0] r_in_q, g_in_q, b_in_q;
    reg       hs_in_q, hb_in_q, vs_in_q, vb_in_q;
    reg       hs_in_d;
    initial begin
        r_in_q = 0; g_in_q = 0; b_in_q = 0;
        hs_in_q = 0; hb_in_q = 1; vs_in_q = 0; vb_in_q = 0;
        hs_in_d = 0;
    end

    always @(posedge clk) if (pxl_cen) begin
        r_in_q   <= r_in;
        g_in_q   <= g_in;
        b_in_q   <= b_in;
        hs_in_q  <= hs_in;
        hb_in_q  <= hb_in;
        vs_in_q  <= vs_in;
        vb_in_q  <= vb_in;
        hs_in_d  <= hs_in;
    end

    wire hs_rise_in = pxl_cen && (hs_in & ~hs_in_d);

    // ------------------------------------------------------------------
    //  HSync rising edge detected at FULL clk rate, latched until the next
    //  pxl2_cen pulse consumes it. This avoids missing the edge when
    //  pxl2_cen is slow, and locks the per-line read phase deterministically.
    // ------------------------------------------------------------------
    reg hs_in_d2;
    reg hs_rise_pending;
    initial begin
        hs_in_d2        = 0;
        hs_rise_pending = 0;
    end
    always @(posedge clk) begin
        hs_in_d2 <= hs_in;
        if (hs_in & ~hs_in_d2)  hs_rise_pending <= 1'b1;
        else if (pxl2_cen)      hs_rise_pending <= 1'b0;
    end

    // ------------------------------------------------------------------
    //  Elastic FIFO storage (single clk domain, two clock enables).
    //  PUSH @ pxl_cen during active video, POP @ pxl2_cen.
    // ------------------------------------------------------------------
    (* ramstyle = "MLAB, no_rw_check" *) reg [23:0] mem [0:DEPTH-1];
    integer ii;
    initial for (ii = 0; ii < DEPTH; ii = ii + 1) mem[ii] = 24'd0;

    reg [LAW-1:0] wptr, rptr;
    reg [CW-1:0]  nactive_run;   // active pixels pushed so far in the current line
    initial begin
        wptr = 0; rptr = 0;
        nactive_run = 0;
    end

    wire active_in = ~hb_in & ~vb_in;          // source pixel is visible
    wire push      = pxl_cen & active_in;
    wire empty     = (wptr == rptr);

    // WRITE side @ pxl_cen. hs_rise_in (during sync) and push (during active)
    // are mutually exclusive, so the per-line reset and the push never collide.
    always @(posedge clk) if (pxl_cen) begin
        if (hs_rise_in) nactive_run <= {CW{1'b0}};
        if (push) begin
            mem[wptr]   <= {r_in, g_in, b_in};
            wptr        <= wptr + 1'b1;
            nactive_run <= nactive_run + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    //  READ side @ pxl2_cen. Emit pixels as the writer makes them available
    //  (gate on emit_cnt < nactive_run, the count pushed SO FAR this line),
    //  which self-paces with no dependence on the previous line — so the
    //  first visible line after vertical blank is handled correctly and the
    //  FIFO never has to hold a whole unread line. Resync rptr to wptr on
    //  each HSync so the FIFO can never drift across lines.
    // ------------------------------------------------------------------
    reg [CW-1:0] emit_cnt;
    reg [23:0]   rd_data;
    reg          out_act_d;   // a pixel was popped on the previous pxl2_cen tick;
                              // aligned with rd_data as seen by the output block
                              // (which reads rd_data with one tick of NB delay).
    initial begin
        emit_cnt = 0; rd_data = 0; out_act_d = 0;
    end

    wire pop = pxl2_cen & ~hs_rise_pending & (emit_cnt < nactive_run) & ~empty;

    always @(posedge clk) if (pxl2_cen) begin
        if (hs_rise_pending) begin
            rptr      <= wptr;                 // resync: drop any (already-emitted) tail
            emit_cnt  <= {CW{1'b0}};
            out_act_d <= 1'b0;
        end else if (pop) begin
            rd_data   <= mem[rptr];
            rptr      <= rptr + 1'b1;
            emit_cnt  <= emit_cnt + 1'b1;
            out_act_d <= 1'b1;
        end else begin
            out_act_d <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    //  Output mux. When stretch is active, outputs MUST be registered
    //  @ pxl2_cen (the DAC rate), NOT @ pxl_cen (the write rate), otherwise
    //  the fast write clock would re-sample the slow read data and break the
    //  "every pixel lasts exactly (16+hsize) clk cycles" property.
    //  In bypass mode the registers run at pxl_cen for full passthrough.
    // ------------------------------------------------------------------
    wire bypass = (hsize == 4'sd0);

    initial begin
        r_out = 0; g_out = 0; b_out = 0;
        hs_out = 0; vs_out = 0; hb_out = 1; vb_out = 0;
    end

    always @(posedge clk) begin
        if (bypass) begin
            if (pxl_cen) begin
                r_out  <= r_in_q;
                g_out  <= g_in_q;
                b_out  <= b_in_q;
                hb_out <= hb_in_q;
                hs_out <= hs_in_q;
                vs_out <= vs_in_q;
                vb_out <= vb_in_q;
            end
        end else begin
            if (pxl2_cen) begin
                if (out_act_d) begin
                    r_out <= rd_data[23:16];
                    g_out <= rd_data[15:8];
                    b_out <= rd_data[7:0];
                end else begin
                    r_out <= 8'd0;
                    g_out <= 8'd0;
                    b_out <= 8'd0;
                end
                hb_out <= ~out_act_d;
                hs_out <= hs_in_q;
                vs_out <= vs_in_q;
                vb_out <= vb_in_q;
            end
        end
    end

endmodule
