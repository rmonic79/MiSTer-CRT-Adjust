//============================================================================
//  crt_adjust_sys.sv  —  "CRT Adjust" (SYS-SIDE variant)
//
//  Analog CRT geometry module for MiSTer FPGA arcade cores.
//  Author: rmonic79 (with help from Andrea Bogazzi / @asturur).
//
//  Same engine as the core-side crt_adjust.sv — the ONLY difference is where
//  you hook it up. Here it goes INSIDE sys_top.v, on the analog VGA branch
//  only, so the HDMI scaler (which taps the stream above that point) is left
//  BIT-IDENTICAL for the H-SIZE stretch. That is this variant's whole point.
//
//  IMPORTANT: only H-Size stays off HDMI here. The module's H-Position and
//  V-Shift move the sync, which the HDMI path DOES follow — so in the sys-side
//  use case, drive H-Size from this module and do H-Position / V-Shift with the
//  framework's own external shift controls (analog-DAC only). Otherwise you lose
//  the bit-identical HDMI image that is the only reason to go sys-side.
//
//  The cost of this path: you must edit sys_top.v (vendored framework code),
//  which steps outside the MiSTer-devel rule against touching sys/. The
//  rule-compliant, recommended choice is the core-side crt_adjust.sv.
//
//  This is the evolution of the earlier core-side "Analog H-Size" module:
//  the same content-shift line-buffer idea, now grown into a full CRT
//  alignment tool exposed in the OSD as "CRT Adjust". One always-on line
//  buffer provides THREE controls:
//
//      - H-Size     : horizontal stretch / squeeze (bidirectional, integer)
//      - H-Position : horizontal slide — two mechanisms, see HPOS_MODE below
//      - V-Shift    : vertical line shift
//
//  ─── Why it never desyncs the CRT ──────────────────────────────────────────
//  The picture CONTENT is shifted/resized through the line buffer while the
//  horizontal/vertical SYNC signals stay NATIVE. The CRT keeps its lock at
//  all times, so you can slide and resize the image live without the screen
//  rolling or losing hold — unlike moving the blanking/sync windows.
//
//  Every source pixel is emitted for an integer-uniform number of pixel-clock
//  periods (no fractional ratio, no per-pixel nearest-neighbor), so there is:
//      - NO shimmering on moving content
//      - NO blending / blur (output = source pixel, byte-exact)
//      - NO line buffer mismatch (1-line ping-pong, deterministic phase)
//
//  SYS-SIDE variant: insert this INSIDE sys_top.v, between the framework's
//  slot-line stream (vga_*_sl) and the OSD overlay that drives the analog DAC
//  pins. HDMI taps the stream ABOVE that point, so it stays BIT-IDENTICAL no
//  matter how you adjust the CRT — you get a clean HDMI picture and a fitted
//  CRT picture at the same time. The cost is editing sys/sys_top.v, which is
//  vendored framework code (not upstreamed; clobbered when you resync sys/).
//  If sys/ is off-limits in your project, use the core-side crt_adjust.sv
//  instead. See README.md and examples/sys_top_snippet.v for the exact glue.
//
//  ─── Resource cost ─────────────────────────────────────────────────────────
//  ~1 M10K (24-bit linebuffer with ping-pong banks), ~50 ALM, 0 DSP.
//
//  ─── Required external signals ─────────────────────────────────────────────
//  pxl_cen   : the core's pixel clock enable (write rate, e.g. 6 MHz pulse
//              on a 96 MHz clk).
//  pxl2_cen  : the DAC read clock enable, generated externally as
//              (base + hsize) quarter-cycles of clk. IMPORTANT: reset its
//              generator on the RISE of `hs_ref_out` (NOT on the raw HSync), so
//              the read rate and the module's internal read counter restart on
//              the same edge in BOTH HPOS modes. See core_side_snippet.v.
//  active    : ON/OFF. 0 = pure bypass (native passthrough). 1 = module live,
//              so H-Size / H-Position / V-Shift work even at value 0.
//  hsize     : signed 5-bit, OSD-controlled size factor (bidirectional).
//              Convention here: read period = base + hsize, so
//              hsize = 0 → no scaling (H-Position / V-Shift still apply if On)
//              hsize > 0 → slower read → WIDER pixels (enlarge)
//              hsize < 0 → faster read → NARROWER pixels (shrink)
//  hoffset   : signed 9-bit, H-Position — mechanism selected by HPOS_MODE.
//  voffset   : signed 6-bit, V-Shift — shifts VSync by N lines.
//
//  ─── License ───────────────────────────────────────────────────────────────
//  Author: Umberto Parisi (rmonic79), 2026.
//  Distributed under GNU GPL v3 or later.
//============================================================================

// ----------------------------------------------------------------------------
//  HPOS_MODE — how the H-Position control moves the image horizontally.
//
//  Two independent mechanisms, pick one per core at compile time. Both are
//  driven by the same OSD "H-Position" value (`hoffset`); the difference is
//  WHAT gets moved.
//
//  Both generations of H-Position live in this one file; the parameter picks
//  which one is built. Neither desyncs the CRT — but they fail differently at
//  the extremes, so the right choice depends on the GAME's geometry.
//
//    HPOS_CONTENTSHIFT (1) — the newer mechanism.
//        Shifts the CONTENT inside the line buffer; HSync out stays byte-for-byte
//        native. The whole engine (write + read) keeps restarting on the native
//        HSync, so it stays rock-solid even while H-Size SHRINKS the image.
//        Downside: on a NARROW game whose active area is anchored to one side of
//        the line (large asymmetric blanking), pushing the content toward the
//        short-margin side runs it out of the buffer window and a black block
//        appears at the screen edge.
//        USE FOR: wide / centered games (e.g. 320px active on a 384px line).
//
//    HPOS_SYNCSHIFT (0) — the original upstream mechanism, kept.
//        Shifts the HSYNC out by N pixels through a line-length shift register;
//        the content stays anchored natively. The picture slides on the CRT with
//        no buffer window to fall out of -> no black block on narrow anchored
//        games. In this mode the ENTIRE engine (write side, read counter) and the
//        external read-rate generator all restart on the SHIFTED HSync, exposed
//        as `hs_ref_out`. That shared reference is what keeps everything in phase;
//        it is also why the glue must reset pxl2_cen on `hs_ref_out` and not on
//        the raw HSync (doing the latter is what desynced the old upstream
//        scheme when shrinking).
//        USE FOR: narrow / side-anchored games (e.g. 256px active with a wide
//        asymmetric H back-porch).
// ----------------------------------------------------------------------------
// Guarded so that including both crt_adjust.sv and crt_adjust_sys.sv in the
// same project does not raise a macro-redefinition warning.
`ifndef HPOS_SYNCSHIFT
`define HPOS_SYNCSHIFT    0
`define HPOS_CONTENTSHIFT 1
`endif

module crt_adjust_sys #(
    parameter VTOTAL   = 263,
    parameter HTOTAL   = 384,               // line length in pixels (for the HSync shreg)
    parameter HPOS_MODE = `HPOS_CONTENTSHIFT // see HPOS_MODE block above
)
(
    input              clk,
    input              pxl_cen,      // write clock enable (core pixel rate)
    input              pxl2_cen,     // read clock enable  (DAC pixel rate, slower)

    input              active,       // ON/OFF: 0 = bypass puro (nativo), 1 = modulo
                                     // attivo (H-Size / H-Pos / V-Shift funzionano
                                     // anche se i loro valori sono 0).

    input  signed [4:0] hsize,       // 0 = nessuna scala, !=0 = enlarge/shrink
    input  signed [8:0] hoffset,     // H-Position value from the OSD.
                                     // HPOS_CONTENTSHIFT: shifts the CONTENT in the
                                     //   line buffer (>0 right, <0 left), sync native.
                                     // HPOS_SYNCSHIFT: delays HSync by N pixels, content
                                     //   stays native (>0 right, <0 left). See HPOS_MODE.
    input  signed [5:0] voffset,     // V-Shift: sposta il VSync di N righe (signed).
                                     // >0 = giu`, <0 = su. Verticale non desincronizza.

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
    output reg         vb_out,
    // Shifted HSync reference (HPOS_SYNCSHIFT): the glue must reset its read-rate
    // generator (pxl2_cen) on the RISE of this signal so the read-rate and the
    // module's read counter restart on the same edge (like the upstream scheme).
    // In HPOS_CONTENTSHIFT it equals the native HSync.
    output wire        hs_ref_out
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

    // Native HSync rise (used only for the shift register that produces the
    // shifted reference below).
    wire hs_rise_native = pxl_cen && (hs_in & ~hs_in_d);

    // ------------------------------------------------------------------
    //  H-Shift shift register (HPOS_SYNCSHIFT). Delays HSync by N pixels
    //  (hoffset signed). Declared BEFORE the read side because in
    //  HPOS_SYNCSHIFT the read counter (rdcnt) resets on this SHIFTED HSync,
    //  exactly like the reference upstream scheme (analog_hsize + h-shift):
    //  there the read divisor and the read counter both restart on the shifted
    //  HSync, so the enlarged content stays aligned with the read window and
    //  never runs off into the right-edge black. Clocked @ pxl_cen (native px).
    //  hoffset >0 = right (delay HSync), <0 = left (advance = HTOTAL-|N| tap).
    // ------------------------------------------------------------------
    wire signed [9:0] hshift_tap = hoffset[8]
        ? (10'(HTOTAL) + {{1{hoffset[8]}}, hoffset})  // negativo -> HTOTAL - |N|
        : {1'd0, hoffset};                            // positivo -> N
    reg [HTOTAL-1:0] hsync_pix_shreg;
    initial hsync_pix_shreg = 0;
    always @(posedge clk) if (pxl_cen)
        hsync_pix_shreg <= {hsync_pix_shreg[HTOTAL-2:0], hs_in};
    reg hs_shifted;
    initial hs_shifted = 0;
    always @(posedge clk) if (pxl_cen)
        hs_shifted <= (hshift_tap == 10'd0) ? hs_in : hsync_pix_shreg[hshift_tap - 10'd1];

    // HSync reference for the WHOLE line-buffer engine: the shifted HSync in
    // HPOS_SYNCSHIFT, the native HSync otherwise. Like the reference upstream
    // scheme (analog_hsize fed the already-shifted HSync), BOTH the write side
    // (wrp/bank/hb0/hb1 capture) and the read side restart on this same edge, so
    // write and read stay on the same bank/phase and the enlarged content is not
    // disaligned at the right edge.
    wire hs_read_ref = (HPOS_MODE == `HPOS_SYNCSHIFT) ? hs_shifted : hs_in;
    assign hs_ref_out = hs_read_ref;   // exposed so the glue aligns pxl2_cen to it
    reg  hs_ref_d1;
    initial hs_ref_d1 = 0;
    always @(posedge clk) if (pxl_cen) hs_ref_d1 <= hs_read_ref;
    wire hs_rise_in = pxl_cen && (hs_read_ref & ~hs_ref_d1);

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
        hs_in_d2 <= hs_read_ref;
        if (hs_read_ref & ~hs_in_d2)  hs_rise_pending <= 1'b1;
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

    // vb_active: VBlank verticale vero, allineato al READ side.
    // Serve a spegnere pass_q durante le righe di VBlank -> VGA_DE torna basso
    // nel VBlank -> l'OSD trova il confine verticale del frame e resta visibile.
    // NON tocca hb0/hb1 (bordi orizzontali) -> nessun re-clamp del "gotcha".
    //
    // FIX pixel tagliati in basso: il read side emette la riga PRECEDENTE
    // (~bank), quindi e` in ritardo di 1 riga rispetto al write/vb_in nativo.
    // Se vb_active seguisse vb_in al write rate, spegnerebbe pass_q mentre il
    // read sta ancora emettendo l'ultima riga attiva -> ultima riga mangiata.
    // Campiono vb_in una volta per riga (hs_rise) e lo ritardo di 1 riga cosi`
    // vb_active si allinea a cio` che il read sta effettivamente emettendo.
    reg vb_line, vb_active;
    initial begin vb_line = 0; vb_active = 0; end
    always @(posedge clk) if (hs_rise_in) begin
        vb_line   <= vb_in;
        vb_active <= vb_line;
    end

    // hoffset (signed) sposta la finestra attiva: >0 = contenuto a DESTRA, <0 a
    // SINISTRA. rd_addr compensa per leggere il pixel sorgente giusto. hs_out NON
    // e' toccato -> HSync intatto -> no desync, qualunque sia l'entita' del shift.
    //
    // In HPOS_SYNCSHIFT the horizontal offset is applied to HSync out (see below),
    // NOT to the read window: the content stays anchored natively, so the read
    // offset is forced to 0 here and hb1/hb0 keep gating the native active area.
    wire signed [AW+1:0] hoff_s  = (HPOS_MODE == `HPOS_CONTENTSHIFT)
                                   ? $signed(hoffset)
                                   : {(AW+2){1'b0}};
    wire signed [AW+1:0] rdcnt_s = $signed({2'b0, rdcnt});
    wire signed [AW+1:0] hb1_s   = $signed({2'b0, hb1});
    wire signed [AW+1:0] hb0_s   = $signed({2'b0, hb0});
    wire [AW-1:0] rd_addr = (rdcnt_s - hoff_s);
    always @(posedge clk) if (pxl2_cen) begin
        rd_data <= mem[{~bank, rd_addr[AW-2:0]}];
        pass_q  <= (rdcnt_s >= (hb1_s + hoff_s)) && (rdcnt_s < (hb0_s + hoff_s)) && ~vb_active;
    end

    // ------------------------------------------------------------------
    //  V-Shift INTERNO: ritarda il VSync di N righe via shift register per
    //  linea (voffset signed). Sposta il VSync, non il contenuto: verticalmente
    //  il CRT ha ampia tolleranza -> nessun desync. hs_rise_in = fine riga.
    // ------------------------------------------------------------------
    wire signed [8:0] vshift_tap = voffset[5]
        ? (9'(VTOTAL) + {{3{voffset[5]}}, voffset})   // negativo -> VTOTAL - |N|
        : {3'd0, voffset};                            // positivo -> N
    reg [VTOTAL-1:0] vsync_line_shreg;
    initial vsync_line_shreg = 0;
    always @(posedge clk) if (hs_rise_in)
        vsync_line_shreg <= {vsync_line_shreg[VTOTAL-2:0], vs_in};
    reg vs_shifted;
    initial vs_shifted = 0;
    always @(posedge clk) if (hs_rise_in)
        vs_shifted <= (vshift_tap == 9'd0) ? vs_in : vsync_line_shreg[vshift_tap - 9'd1];

    // HSync emitted by the module: shifted only in HPOS_SYNCSHIFT, else native.
    // (hsync_pix_shreg / hs_shifted are computed above, before the read side.)
    wire hs_pos_out = (HPOS_MODE == `HPOS_SYNCSHIFT) ? hs_shifted : hs_in_q;

    // ------------------------------------------------------------------
    //  Output mux. CRITICAL: when stretch is active, outputs MUST be
    //  registered @ pxl2_cen (the DAC rate), NOT @ pxl_cen (the write
    //  rate). Otherwise the fast write clock would re-sample the slow
    //  read data at write rate, breaking the "every pixel lasts exactly
    //  (16+hsize) clk cycles" property and re-introducing shimmering.
    //  In bypass mode, registers run at pxl_cen for full passthrough.
    // ------------------------------------------------------------------
    // Bypass controllato dall'ON/OFF: OFF -> passthrough nativo puro.
    // ON -> modulo sempre attivo (anche con hsize=0/hoffset=0), cosi` H-Position
    // e V-Shift funzionano anche senza scala.
    wire bypass = ~active;

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
                hs_out <= hs_pos_out;   // HPOS_SYNCSHIFT -> shifted HSync, else native
                vs_out <= vs_shifted;   // V-Shift interno (VSync shiftato)
                vb_out <= vb_in_q;
            end
        end
    end

endmodule
