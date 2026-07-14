//============================================================================
//  crt_adjust.sv  —  "CRT Adjust"
//
//  Core-side analog CRT geometry module for MiSTer FPGA arcade cores.
//  Author: rmonic79 (with help from Andrea Bogazzi / @asturur).
//
//  This is the evolution of the earlier core-side "Analog H-Size" module:
//  the same content-shift line-buffer idea, now grown into a full CRT
//  alignment tool exposed in the OSD as "CRT Adjust". One always-on line
//  buffer provides THREE controls:
//
//      - H-Size     : horizontal stretch / squeeze (bidirectional, integer)
//      - H-Position : horizontal content shift (does NOT move the sync)
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
//  CORE-SIDE variant: instantiate this inside the core's emu wrapper (your
//  top-level .sv) at the video-output boundary, with zero sys_top.v changes
//  (MiSTer-devel compliant — the sys/ framework is never modified). The
//  trade-off: the adjust reaches the analog DAC AND HDMI follows it too.
//  Leave CRT Adjust Off for an untouched HDMI image. For the sys-side variant
//  (HDMI stays bit-identical, but you must edit sys_top.v) use crt_adjust_sys.sv.
//  See README.md and examples/ for the exact glue.
//
//  ─── Resource cost ─────────────────────────────────────────────────────────
//  ~1 M10K (24-bit linebuffer with ping-pong banks), ~50 ALM, 0 DSP.
//
//  ─── Required external signals ─────────────────────────────────────────────
//  pxl_cen   : the core's pixel clock enable (write rate, e.g. 6 MHz pulse
//              on a 96 MHz clk).
//  pxl2_cen  : the DAC read clock enable, SLOWER than pxl_cen by an integer
//              divisor (base+hsize) of clk, generated externally for phase
//              alignment with HSync (see examples/core_side_snippet.v).
//  active    : ON/OFF. 0 = pure bypass (native passthrough). 1 = module live,
//              so H-Size / H-Position / V-Shift work even at value 0.
//  hsize     : signed 5-bit, OSD-controlled size factor (bidirectional).
//              Convention here: read period = base + hsize, so
//              hsize = 0 → no scaling (H-Position / V-Shift still apply if On)
//              hsize > 0 → slower read → WIDER pixels (enlarge)
//              hsize < 0 → faster read → NARROWER pixels (shrink)
//              (a core that prefers the opposite polarity can just negate the
//               OSD value in its glue before connecting.)
//  hoffset   : signed 9-bit, H-Position — shifts the CONTENT, not the sync.
//  voffset   : signed 6-bit, V-Shift — shifts VSync by N lines.
//
//  ─── License ───────────────────────────────────────────────────────────────
//  Author: Umberto Parisi (rmonic79), 2026.
//  Distributed under GNU GPL v3 or later.
//============================================================================

module crt_adjust #(parameter VTOTAL = 263)
(
    input              clk,
    input              pxl_cen,      // write clock enable (core pixel rate)
    input              pxl2_cen,     // read clock enable  (DAC pixel rate, slower)

    input              active,       // ON/OFF: 0 = bypass puro (nativo), 1 = modulo
                                     // attivo (H-Size / H-Pos / V-Shift funzionano
                                     // anche se i loro valori sono 0).

    input  signed [4:0] hsize,       // 0 = nessuna scala, !=0 = enlarge/shrink
    input  signed [8:0] hoffset,     // sposta il CONTENUTO orizzontale (non il sync):
                                     // >0 = a DESTRA, <0 = a SINISTRA.
                                     // Non tocca hs_out -> nessun desync CRT.
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
    wire signed [AW+1:0] rdcnt_s = $signed({2'b0, rdcnt});
    wire signed [AW+1:0] hb1_s   = $signed({2'b0, hb1});
    wire signed [AW+1:0] hb0_s   = $signed({2'b0, hb0});
    wire signed [AW+1:0] hoff_s  = $signed(hoffset);
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
                hs_out <= hs_in_q;
                vs_out <= vs_shifted;   // V-Shift interno (VSync shiftato)
                vb_out <= vb_in_q;
            end
        end
    end

endmodule
