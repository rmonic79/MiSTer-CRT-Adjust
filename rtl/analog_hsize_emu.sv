//============================================================================
//  analog_hsize_emu.sv
//
//  EMU-SIDE variant of analog_hsize: instantiated INSIDE the core's `emu`
//  module (rtl/), NOT in sys_top.v. Adds analog H-Size with ZERO edits to the
//  MiSTer framework (sys_top is vendored from the template and clobbered on
//  updates; many project rules forbid touching it).
//
//  ─── What it does ──────────────────────────────────────────────────────────
//  Same pixel-stretch engine as analog_hsize.sv (linebuffer ping-pong, read
//  slower than write by an integer divisor -> every pixel lasts exactly
//  (base+hsize) clk cycles, no shimmering, byte-exact).
//
//  Placed at the core's video-output boundary, it hands sys_top an already-
//  stretched stream. The analog chain in sys_top (scanlines/osd/vga_out)
//  passes the active window through, so the DAC widens with it. The HDMI
//  scaler normalizes pixel *duration* (counts N active pixels on CE_PIXEL and
//  fits them to the target), so on HDMI the image follows the stretch too
//  (line widths can exceed the HDMI target — treat this as an analog/CRT
//  feature). See docs/emu-side-integration.md.
//
//  ─── The `vb_in` fix (vs the plain sys-side module) ─────────────────────────
//  At the emu boundary the on-screen OSD is composited DOWNSTREAM (in sys_top,
//  after the pin). For the OSD to find the vertical frame boundary, VGA_DE must
//  drop during vertical blanking. This module gates `pass_q` with a latched
//  TRUE vertical blank (`vb_in` = the core's real VBlank, NOT the combined
//  ~DE): pass_q is forced low on vblank lines -> VGA_DE goes low -> the OSD
//  stays visible with stretch active.
//
//  Crucially `vb_in` gates ONLY pass_q, never the horizontal edges hb0/hb1,
//  so it does NOT re-clamp the widened horizontal window. (The "vb_in gotcha"
//  — feeding the *combined* blank into vb_in and re-clamping the window to the
//  original width — was diagnosed by Andrea Bogazzi / @asturur while
//  integrating this module core-side into a Deco16 / Caveman Ninja JTFRAME
//  core; his fix tied vb_in low. This module keeps the OSD working by passing
//  the true vertical blank and gating only pass_q.)
//
//  ─── Resource cost ─────────────────────────────────────────────────────────
//  ~1 M10K (24-bit linebuffer with ping-pong banks), ~50 ALM, 0 DSP.
//
//  ─── Required external signals ─────────────────────────────────────────────
//  pxl_cen   : the core's pixel clock enable (write rate, e.g. 6 MHz pulse
//              on a 96 MHz clk).
//  pxl2_cen  : the DAC read clock enable, SLOWER than pxl_cen by an integer
//              divisor (base+hsize) of clk, generated in the core; drive
//              CE_PIXEL from it. See examples/emu_side_snippet.v.
//  hsize     : signed 4-bit, OSD-controlled stretch factor.
//              hsize = 0 → bypass (passthrough at pxl_cen rate)
//              hsize < 0 → progressively wider pixels (the OSD usually exposes
//                          0..N unsigned and the glue negates it before connecting).
//  hb_in     : combined blank ~(HBlank|VBlank) — delimits the horizontal
//              active region for the linebuffer edges (hb0/hb1).
//  vb_in     : the core's TRUE vertical blank (VBlank only). Gates pass_q so
//              VGA_DE drops on vblank lines -> OSD stays visible.
//
//  ─── License ───────────────────────────────────────────────────────────────
//  Author: Umberto Parisi (rmonic79), 2026.
//  vb_in gotcha diagnosed by Andrea Bogazzi (@asturur).
//  Distributed under GNU GPL v3 or later.
//============================================================================

module analog_hsize_emu
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

    localparam integer AW = 10;  // 1024 samples per line (ping-pong banks)

    // ------------------------------------------------------------------
    //  Input pipeline @ pxl_cen (for latency matching in bypass mode)
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
    //  Linebuffer ping-pong (24-bit RGB, single M10K, two banks).
    //  Written @ pxl_cen by the core, read @ pxl2_cen by the DAC.
    //  Two banks (selected by `bank` flipped on each HSync rise) avoid
    //  read/write collisions: write current line into `bank`, read the
    //  previous line (`~bank`) which is already complete.
    // ------------------------------------------------------------------
    (* ramstyle = "no_rw_check, M10K" *) reg [23:0] mem [0:(1<<AW)-1];
    integer ii;
    initial for (ii = 0; ii < (1<<AW); ii = ii + 1) mem[ii] = 24'd0;

    // ------------------------------------------------------------------
    //  WRITE side @ pxl_cen
    // ------------------------------------------------------------------
    reg [AW-1:0] wrp;
    reg [AW-1:0] hmax;
    reg [AW-1:0] hb0, hb1;
    reg          lhb_l;
    reg          bank;
    initial begin
        wrp = 0; hmax = 0;
        hb0 = 0; hb1 = 0;
        lhb_l = 0;
        bank = 0;
    end

    wire lhb = ~hb_in;

    always @(posedge clk) if (pxl_cen) begin
        lhb_l <= lhb;
        mem[{bank, wrp[AW-2:0]}] <= {r_in, g_in, b_in};
        if (hs_rise_in) begin
            wrp  <= {AW{1'b0}};
            hmax <= wrp;
            bank <= ~bank;
        end else begin
            wrp <= wrp + 1'b1;
        end
        if (lhb   & ~lhb_l) hb1 <= wrp;  // start of active region (wrp value)
        if (~lhb  &  lhb_l) hb0 <= wrp;  // end of active region   (wrp value)
    end

    // ------------------------------------------------------------------
    //  READ side @ pxl2_cen.
    //  rdcnt increments by 1 at each pxl2_cen pulse -> exactly one source
    //  pixel is emitted to the DAC per read tick. Reset is triggered by
    //  the rising edge of HSync, detected at FULL clk rate to avoid
    //  missing edges when pxl2_cen is slow.
    // ------------------------------------------------------------------
    reg [AW-1:0] rdcnt;
    reg          hs_in_d2;
    reg          hs_rise_pending;
    initial begin
        rdcnt = 0;
        hs_in_d2 = 0;
        hs_rise_pending = 0;
    end

    always @(posedge clk) begin
        hs_in_d2 <= hs_in;
        if (hs_in & ~hs_in_d2)        hs_rise_pending <= 1'b1;
        else if (pxl2_cen)            hs_rise_pending <= 1'b0;
    end

    always @(posedge clk) if (pxl2_cen) begin
        if (hs_rise_pending) begin
            rdcnt <= {AW{1'b0}};
        end else begin
            rdcnt <= rdcnt + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    //  Read from the linebuffer @ pxl2_cen, on the OPPOSITE bank to the
    //  one currently being written (so the previous fully-written line).
    //  pass_q gates active video against blanking, in linebuffer units.
    // ------------------------------------------------------------------
    reg [23:0] rd_data;
    reg        pass_q;
    initial begin
        rd_data = 0;
        pass_q = 0;
    end

    // vb_active: the core's TRUE vertical blank, latched per line (@ pxl_cen).
    // Gates pass_q OFF on vblank lines so VGA_DE drops during vertical blanking
    // -> the downstream OSD finds the vertical frame boundary and stays visible
    // with stretch active. Gates ONLY pass_q, never hb0/hb1 -> no re-clamp of
    // the widened horizontal window (see header, "vb_in fix").
    reg vb_active;
    always @(posedge clk) if (pxl_cen) vb_active <= vb_in;

    always @(posedge clk) if (pxl2_cen) begin
        rd_data <= mem[{~bank, rdcnt[AW-2:0]}];
        pass_q  <= (rdcnt >= hb1) && (rdcnt < hb0) && ~vb_active;
    end

    // ------------------------------------------------------------------
    //  Output mux. CRITICAL: when stretch is active, outputs MUST be
    //  registered @ pxl2_cen (the DAC rate), NOT @ pxl_cen (the write
    //  rate). Otherwise the fast write clock would re-sample the slow
    //  read data at write rate, breaking the "every pixel lasts exactly
    //  (base+hsize) clk cycles" property and re-introducing shimmering.
    //  In bypass mode, registers run at pxl_cen for full passthrough.
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
                if (pass_q) begin
                    r_out <= rd_data[23:16];
                    g_out <= rd_data[15:8];
                    b_out <= rd_data[7:0];
                end else begin
                    r_out <= 8'd0;
                    g_out <= 8'd0;
                    b_out <= 8'd0;
                end
                hb_out <= ~pass_q;
                hs_out <= hs_in_q;
                vs_out <= vs_in_q;
                vb_out <= vb_in_q;
            end
        end
    end

endmodule
