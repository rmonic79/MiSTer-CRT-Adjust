//============================================================================
//  crt_vsize.sv  —  "CRT V-Size" (vertical stretch / shrink at 15 kHz)
//
//  Vertical size control for the analog CRT output of a MiSTer FPGA core.
//  Author: rmonic79. Companion stage of crt_adjust / crt_adjust_sys.
//
//  ─── The mechanism (artifact-free, the vertical twin of H-Size) ────────────
//  The frame rate can NOT change (the game dictates it). The picture height
//  is changed by retiming the TOTAL line count per frame with the line
//  period scaled inversely — the product stays exactly one frame period.
//  With fewer lines per frame the vertical deflection advances MORE between
//  scanlines: the same source lines, each unique, simply spread apart.
//      vsize > 0  ->  more lines/frame  -> shorter lines -> SMALLER picture
//      vsize < 0  ->  fewer lines/frame -> longer lines  -> TALLER picture
//      vsize = 0  ->  pure bypass
//  NO line is ever repeated, dropped or blended — zero shimmering, zero
//  duplication artifacts, byte-exact content (same philosophy as H-Size).
//
//  THE PHYSICAL LIMIT, stated plainly: height% == HSync deviation%. VSync
//  stays native; HSync moves around ~15.6 kHz by ~0.38% per line. Pro
//  monitors (PVM/BVM) lock a wide range; arcade cabinet chassis with tight
//  AFC hold only ~1-2% -> on those the usable range is a couple of steps.
//  There is no third mechanism: real spacing costs frequency; anything at
//  native timing must duplicate lines (rejected).
//
//  ─── Quality rules ─────────────────────────────────────────────────────────
//  - 1:1 line mapping through a multi-line elastic ring buffer.
//  - Pixels replayed at the MEASURED native pixel period (integer clk),
//    perfectly uniform; only the BLANKING absorbs the line-period change.
//  - Output line cadence: Bresenham over the measured frame period —
//    exactly lines_out line-starts per frame, max 1 clk deterministic
//    jitter, re-phased on every native VSync.
//  - ADAPTIVE HSYNC: when the shortened line can no longer fit the native
//    ~4.8us pulse + porches, the pulse narrows toward ~3us. It is porch
//    compression that breaks lock first on the "+" side, not frequency.
//
//  ─── Self-measuring: NO per-core parameters ────────────────────────────────
//  Frame period, native line count, pixel CE period, HSync pulse width,
//  VSync width and DE start offset are all measured at runtime. Any core,
//  any video mode (NTSC 264 <-> PAL 312 followed automatically). Until two
//  consecutive stable frames are measured the module forces bypass.
//
//  ─── Placement ─────────────────────────────────────────────────────────────
//  BEFORE crt_adjust(_sys), which composes per-line and is agnostic to the
//  line period:   native stream -> crt_vsize -> crt_adjust -> OSD/DAC.
//  Usable identically core-side or sys-side (HDMI taps upstream: untouched).
//
//  ─── Ring sizing ───────────────────────────────────────────────────────────
//  Reading starts RING_LINES/2 native lines after VSync and drifts by up to
//  |vsize| lines within the frame: need |vsize| <= RING_LINES/2 - 2.
//  RING_LINES=46 covers vsize -21..+21.
//
//  ─── License ───────────────────────────────────────────────────────────────
//  Author: Umberto Parisi (rmonic79), 2026.  GNU GPL v3 or later.
//============================================================================

module crt_vsize #(
    parameter RING_LINES  = 46,     // ring depth in lines; |vsize| <= RING_LINES/2 - 2
    parameter LINE_PX     = 384,    // pixel slots per ring line
    parameter FRONT_MIN   = 64,     // minimum front porch left after clamping (clk)
    parameter SLEW_FRAMES = 1       // frames per 1-line step of the vsize slew
)(
    input               clk,
    input               pxl_cen,    // input pixel CE (uniform native rate)
    input               active,     // ON/OFF (module also self-bypasses when vsize==0)
    input               tube_mode,  // 0 = Timing (retimer, unique lines, HSync moves)
                                    // 1 = Tube (native timing, photometric geometry sim)

    input signed  [5:0] vsize,      // lines ADDED to the frame total (-21..+21)

    input         [7:0] r_in,
    input         [7:0] g_in,
    input         [7:0] b_in,
    input               hs_in,
    input               vs_in,
    input               de_in,      // active pixels (combined DE)
    input               vb_in,      // TRUE vertical blank (for bypass passthrough)

    output reg    [7:0] r_out,
    output reg    [7:0] g_out,
    output reg    [7:0] b_out,
    output reg          hs_out,
    output reg          vs_out,
    output reg          de_out,
    output reg          vb_out,
    output reg          ce_out      // output pixel CE (native period, retimed grid)
);

    // ------------------------------------------------------------------
    //  Input edge detection
    // ------------------------------------------------------------------
    reg hs_d, vs_d, de_d;
    initial begin hs_d = 0; vs_d = 0; de_d = 0; end
    always @(posedge clk) if (pxl_cen) begin
        hs_d <= hs_in;
        vs_d <= vs_in;
        de_d <= de_in;
    end
    wire hs_rise = pxl_cen & hs_in & ~hs_d;
    wire vs_rise = pxl_cen & vs_in & ~vs_d;
    wire de_rise = pxl_cen & de_in & ~de_d;

    // ==================================================================
    //  MEASUREMENT (always running)
    // ==================================================================

    // Frame period in clk cycles (native VSync rise to rise)
    reg [21:0] f_cnt, f_meas, f_prev;
    initial begin f_cnt = 0; f_meas = 0; f_prev = 0; end

    // Native lines per frame
    reg [9:0] l_cnt, lines_nat;
    initial begin l_cnt = 0; lines_nat = 0; end

    // Pixel CE period in clk cycles
    reg [4:0] p_cnt, p_nat;
    initial begin p_cnt = 0; p_nat = 5'd8; end
    always @(posedge clk) begin
        if (pxl_cen) begin
            p_nat <= p_cnt + 1'd1;
            p_cnt <= 0;
        end else if (~&p_cnt) p_cnt <= p_cnt + 1'd1;
    end

    // HSync pulse width in clk cycles
    reg [11:0] hw_cnt, hs_width;
    initial begin hw_cnt = 0; hs_width = 12'd256; end
    always @(posedge clk) begin
        if (hs_rise)      hw_cnt <= 12'd1;
        else if (hs_in)   begin if (~&hw_cnt) hw_cnt <= hw_cnt + 1'd1; end
        else if (hw_cnt != 0) begin hs_width <= hw_cnt; hw_cnt <= 0; end
    end

    // VSync width in lines
    reg [3:0] vw_cnt, vs_lines;
    initial begin vw_cnt = 0; vs_lines = 4'd3; end

    // DE start offset from HSync rise (clk cycles) — one value per frame
    // (raster lines are homogeneous), refreshed on every line that has DE.
    reg [11:0] c_line;          // clk since last native hs_rise
    reg        line_had_de;
    reg [11:0] de_start_nat;
    reg [9:0]  wpx;             // write pixel index in current line
    reg [9:0]  px_count_nat;    // active pixels per line (latched at DE fall)
    initial begin c_line = 0; line_had_de = 0; de_start_nat = 12'd512; wpx = 0; px_count_nat = 10'd320; end

    // Cabinet mode: active-window tracking (native line domain)
    reg [9:0] pxde_cnt;         // CE ticks since hs_rise (native pixel index)
    reg [9:0] de_start_px;      // DE start offset in CE ticks (per frame)
    reg [9:0] a_cnt, a_nat;     // active (has-DE) lines per frame
    reg [9:0] nl, nl_top;       // native line index; line of first active line
    reg [5:0] top_slot;         // ring slot holding source active line 0
    reg       seen_de;
    initial begin
        pxde_cnt = 0; de_start_px = 10'd64; a_cnt = 0; a_nat = 10'd224;
        nl = 0; nl_top = 10'd16; top_slot = 0; seen_de = 0;
    end

    // Measurement validity: two consecutive frames with equal-ish period
    reg  meas_ok, meas_ok_prev;
    initial begin meas_ok = 0; meas_ok_prev = 0; end
    wire [21:0] f_diff = (f_meas > f_prev) ? (f_meas - f_prev) : (f_prev - f_meas);

    // ==================================================================
    //  RING BUFFER — RING_LINES x LINE_PX x 24, plus per-line pixel count
    // ==================================================================
    localparam integer RAW = $clog2(RING_LINES*LINE_PX);

    (* ramstyle = "no_rw_check, M10K" *) reg [23:0] ring [0:RING_LINES*LINE_PX-1];

    reg [9:0] meta_px [0:RING_LINES-1];   // active pixel count of each ring line
    integer mi;
    initial for (mi = 0; mi < RING_LINES; mi = mi + 1) meta_px[mi] = 0;

    // line index -> base address (x384 = x<<8 + x<<7 when LINE_PX=384)
    function [RAW-1:0] line_base(input [5:0] l);
        line_base = (l * LINE_PX);
    endfunction

    // ------------------------------------------------------------------
    //  WRITE side @ native cadence
    // ------------------------------------------------------------------
    reg [5:0] wl;               // ring slot being written
    reg [5:0] frame0_slot;      // ring slot that holds native frame line 0
    initial begin wl = 0; frame0_slot = 1; end

    wire [5:0] wl_next = (wl == RING_LINES-1) ? 6'd0 : wl + 1'd1;

    always @(posedge clk) begin
        // per-line cycle counter
        if (hs_rise) c_line <= 12'd1;
        else if (~&c_line) c_line <= c_line + 1'd1;

        // per-line CE-tick counter (Cabinet pixel window)
        if (hs_rise) pxde_cnt <= 0;
        else if (pxl_cen && ~&pxde_cnt) pxde_cnt <= pxde_cnt + 1'd1;

        if (hs_rise) begin
            // close the finished line: latch its pixel count into the meta
            meta_px[wl]  <= line_had_de ? wpx : 10'd0;
            if (line_had_de) px_count_nat <= wpx;
            if (line_had_de) a_cnt <= a_cnt + 1'd1;
            wl           <= wl_next;
            wpx          <= 0;
            line_had_de  <= 0;
            l_cnt        <= l_cnt + 1'd1;
            nl           <= nl + 1'd1;
            if (vs_in) vw_cnt <= vw_cnt + 1'd1;
        end

        if (de_rise & ~line_had_de) begin
            line_had_de  <= 1;
            de_start_nat <= c_line;
            de_start_px  <= pxde_cnt;
            if (~seen_de) begin
                seen_de  <= 1;
                nl_top   <= nl;
                top_slot <= wl;    // slot being written NOW = source line 0
            end
        end

        if (pxl_cen & de_in) begin
            ring[line_base(wl) + wpx] <= {r_in, g_in, b_in};
            if (wpx != LINE_PX-1) wpx <= wpx + 1'd1;
        end

        // frame bookkeeping
        f_cnt <= f_cnt + 1'd1;
        if (vs_rise) begin
            f_meas       <= f_cnt;
            f_prev       <= f_meas;
            f_cnt        <= 0;
            lines_nat    <= l_cnt;
            // when VSync rises ON a line boundary (the usual case) that HSync
            // belongs to the NEW frame: seed the counters with 1, not 0 —
            // otherwise every frame measures one line short (off-by-one that
            // would shift the whole V-Size dial by one step)
            l_cnt        <= hs_rise ? 10'd1 : 10'd0;
            vs_lines     <= (vw_cnt != 0) ? vw_cnt : vs_lines;
            vw_cnt       <= hs_rise ? 4'd1 : 4'd0;
            frame0_slot  <= wl_next;   // next line written = frame line 0
            meas_ok_prev <= meas_ok;
            // stable when two consecutive frame periods match within 16 clk
            meas_ok      <= (f_diff < 22'd16) && (l_cnt > 10'd99) && (f_meas != 0);
            // Cabinet frame bookkeeping
            nl           <= hs_rise ? 10'd1 : 10'd0;
            a_nat        <= a_cnt;
            a_cnt        <= 0;
            seen_de      <= 0;
        end
    end

    // ==================================================================
    //  VSIZE SLEW — walk the monitor's AFC instead of hitting it
    // ==================================================================
    //  A chassis PLL has a narrow CAPTURE range but a 2-3x wider HOLD range.
    //  Applying the requested vsize as a step change hits the capture limit;
    //  moving 1 line every SLEW_FRAMES frames keeps the flywheel locked and
    //  walks it out into its hold range. All height changes (including
    //  switch-on) go through this ramp.
    reg signed [5:0] vsize_eff;
    reg  [3:0]       slew_cnt;
    initial begin vsize_eff = 0; slew_cnt = 0; end

    always @(posedge clk) if (vs_rise) begin
        if (!active) begin
            vsize_eff <= 0;
            slew_cnt  <= 0;
        end else if (vsize_eff != vsize) begin
            if (slew_cnt == SLEW_FRAMES-1) begin
                slew_cnt  <= 0;
                vsize_eff <= (vsize > vsize_eff) ? vsize_eff + 1'd1
                                                 : vsize_eff - 1'd1;
            end else slew_cnt <= slew_cnt + 1'd1;
        end else slew_cnt <= 0;
    end

    // ==================================================================
    //  PER-FRAME OUTPUT PARAMETERS
    // ==================================================================
    wire signed [10:0] lines_out_s = $signed({1'b0, lines_nat}) + vsize_eff;
    reg  [9:0]  lines_out;       // latched per frame
    reg  [21:0] f_lat;           // latched frame period for the Bresenham
    initial begin lines_out = 10'd264; f_lat = 22'd811008; end

    // Cabinet: righe attive in uscita (vsize + = piu` bassa -> meno attive)
    wire signed [10:0] a_out_ts = $signed({1'b0, a_nat}) - vsize_eff;
    wire        [9:0]  a_out_t  = a_out_ts[9:0];

    // Sequential restoring divider: period_out = f_lat / lines_out
    // (one division per frame, runs right after VSync, done in 22 clk —
    //  long before the first output line needs it)
    reg [21:0] div_rem;
    reg [21:0] div_quo;
    reg [21:0] div_num;          // dividend  (PVM: f_meas | Cabinet: a_nat << 8)
    reg [9:0]  div_den;          // divisor   (PVM: lines_out | Cabinet: a_out_t)
    reg        tube_q;           // which mode requested this division
    reg [4:0]  div_bit;
    reg        div_run, div_done;
    reg [21:0] period_out;
    reg [9:0]  step_q8;          // Cabinet: source step per output line, Q2.8
    initial begin
        div_rem = 0; div_quo = 0; div_num = 0; div_den = 10'd264; tube_q = 0;
        div_bit = 0; div_run = 0; div_done = 0; period_out = 22'd3072; step_q8 = 10'd256;
    end

    reg  [14:0] active_nom;
    reg  [11:0] hs_w_out;
    reg         hsw_stage;
    initial begin active_nom = 15'd2560; hs_w_out = 12'd256; hsw_stage = 0; end
    wire [21:0] blank_out = period_out - {7'd0, active_nom};

    always @(posedge clk) begin
        div_done <= 0;
        if (vs_rise) begin
            lines_out <= lines_out_s[9:0];
            f_lat     <= f_meas;
            div_num   <= tube_mode ? {4'd0, a_nat, 8'd0} : f_meas;
            div_den   <= tube_mode ? a_out_t : lines_out_s[9:0];
            tube_q    <= tube_mode;
            div_rem   <= 0;
            div_quo   <= 0;
            div_bit   <= 5'd21;
            div_run   <= 1;
        end else if (div_run) begin
            // shift in div_num MSB-first, standard restoring division
            if ({div_rem[20:0], div_num[div_bit]} >= {12'd0, div_den}) begin
                div_rem <= {div_rem[20:0], div_num[div_bit]} - {12'd0, div_den};
                div_quo <= {div_quo[20:0], 1'b1};
            end else begin
                div_rem <= {div_rem[20:0], div_num[div_bit]};
                div_quo <= {div_quo[20:0], 1'b0};
            end
            if (div_bit == 0) begin
                div_run  <= 0;
                div_done <= 1;   // quotient completes on THIS edge -> capture next cycle
            end else div_bit <= div_bit - 1'd1;
        end
        if (div_done) begin
            if (tube_q) step_q8  <= div_quo[9:0];
            else        period_out <= div_quo;
            active_nom <= px_count_nat * p_nat;
        end
        hsw_stage <= div_done;
        // HSync adattivo: se il blanking della riga accorciata non ha piu`
        // spazio per l'impulso nativo (~4.8us) + porch, l'impulso si
        // restringe a meta` del blanking disponibile. E` la compressione dei
        // porch sul lato "+" (immagine piu` bassa) a far perdere l'aggancio
        // per prima, non la sola deviazione di frequenza.
        if (hsw_stage) begin
            hs_w_out <= ({10'd0, hs_width} <= (blank_out >> 1)) ? hs_width : blank_out[12:1];
        end
    end

    // ==================================================================
    //  OUTPUT TIMING — Bresenham line cadence, phase-locked per frame
    // ==================================================================
    localparam [5:0] START_LINES = RING_LINES/2;

    // enable: user ON, target o rampa non a zero, misure stabili per 2 frame.
    // Con vsize_eff=0 e target !=0 il motore parte gia` (replica del timing
    // nativo) e poi la rampa lo porta al valore: partenza senza scalino.
    // PVM (retimer) e Cabinet (tube sim) sono esclusivi: seleziona tube_mode.
    wire vsize_req = (vsize != 0) || (vsize_eff != 0);
    wire engine_on = active && ~tube_mode && vsize_req
                     && meas_ok && meas_ok_prev;
    wire tube_on   = active &&  tube_mode && vsize_req
                     && meas_ok && meas_ok_prev && (a_out_t > 10'd32);

    reg  [5:0]  start_cnt;      // native hs_rise counter after vs_rise
    reg         out_running;    // output frame in progress
    reg  [21:0] bres_acc;
    reg  [9:0]  out_line;
    reg  [5:0]  rl;             // ring slot being read
    initial begin start_cnt = 0; out_running = 0; bres_acc = 0; out_line = 0; rl = 0; end

    wire [5:0] rl_next = (rl == RING_LINES-1) ? 6'd0 : rl + 1'd1;

    // line tick: first at output-frame start, then every f_lat/lines_out clk
    wire        frame_go  = (start_cnt == START_LINES) && hs_rise && engine_on;
    wire [22:0] bres_sum  = {1'b0, bres_acc} + {13'd0, lines_out};
    wire        line_tick = out_running && (bres_sum >= {1'b0, f_lat});

    always @(posedge clk) begin
        if (vs_rise)      start_cnt <= 0;
        else if (hs_rise && ~&start_cnt) start_cnt <= start_cnt + 1'd1;

        if (frame_go) begin
            out_running <= 1;
            bres_acc    <= 0;
            out_line    <= 0;
            rl          <= frame0_slot;
        end else if (out_running) begin
            bres_acc <= line_tick ? (bres_sum - {1'b0, f_lat}) : bres_sum[21:0];
            if (line_tick) begin
                if (out_line == lines_out - 1'd1) out_running <= 0;
                else begin
                    out_line <= out_line + 1'd1;
                    rl       <= rl_next;
                end
            end
        end
        if (~engine_on) out_running <= 0;
    end

    wire line_start = frame_go || (line_tick && out_running && (out_line != lines_out - 1'd1));

    // ------------------------------------------------------------------
    //  Per-output-line state: DE window placement + pixel replay
    // ------------------------------------------------------------------
    reg [21:0] o_cline;         // clk since output line start
    reg [9:0]  o_pxcnt;         // pixels of this ring line (from meta)
    reg [14:0] o_active_cyc;    // o_pxcnt * p_nat
    reg [11:0] o_de_start;      // effective DE start for this line
    reg [9:0]  o_px;            // pixels emitted
    reg [4:0]  o_ce_cnt;        // pixel CE grid counter
    reg        o_vs, o_vb;
    initial begin
        o_cline = 0; o_pxcnt = 0; o_active_cyc = 0; o_de_start = 12'd512;
        o_px = 0; o_ce_cnt = 0; o_vs = 0; o_vb = 1;
    end

    // clamp: if the native DE offset does not fit in the shortened line,
    // pull the window left leaving FRONT_MIN of front porch
    wire [21:0] need_end   = {10'd0, de_start_nat} + {7'd0, o_active_cyc} + FRONT_MIN;
    wire [21:0] clamp_left = period_out - {7'd0, o_active_cyc} - FRONT_MIN;
    wire [11:0] de_floor   = hs_w_out + 12'd16;

    // RAM read: porta unica condivisa (PVM: rd_addr / Cabinet: rd_addr_t).
    // Il mux di selezione viene REGISTRATO in rd_addr_m PRIMA di indicizzare
    // la RAM: l'M10K vede un indirizzo registrato puro — pattern sicuro per
    // l'inferenza (un mux combinatorio nell'indice puo` far decadere il ring
    // da RAM a mare di registri+mux, con sintesi che esplode).
    reg  [RAW-1:0] rd_addr;
    reg  [RAW-1:0] rd_addr_t;
    reg  [RAW-1:0] rd_addr_m;
    reg  [23:0]    ring_q;
    initial begin rd_addr = 0; rd_addr_t = 0; rd_addr_m = 0; ring_q = 0; end
    always @(posedge clk) begin
        rd_addr_m <= tube_on ? rd_addr_t : rd_addr;
        ring_q    <= ring[rd_addr_m];
    end

    wire in_window = out_running && (o_cline >= {10'd0, o_de_start}) && (o_px < o_pxcnt);
    reg  win_q;
    initial win_q = 0;

    always @(posedge clk) begin
        if (line_start) begin
            o_cline      <= 22'd1;
            o_px         <= 0;
            o_ce_cnt     <= 0;
            o_pxcnt      <= meta_px[frame_go ? frame0_slot : rl_next];
            o_vs         <= frame_go ? 1'b1 : (out_line + 1'd1 < {6'd0, vs_lines});
            win_q        <= 0;
        end else begin
            o_cline <= o_cline + 1'd1;
            if (o_ce_cnt == p_nat - 1'd1) o_ce_cnt <= 0;
            else                          o_ce_cnt <= o_ce_cnt + 1'd1;
        end

        // second cycle of the line: place the DE window (period_out ready
        // since vblank; o_pxcnt latched on line_start the cycle before)
        if (o_cline == 22'd2) begin
            o_active_cyc <= o_pxcnt * p_nat;
            o_vb         <= (o_pxcnt == 0);
        end
        if (o_cline == 22'd4)
            // clamp con pavimento: la finestra DE mai prima della fine
            // dell'impulso HSync (adattivo) + un margine di back porch
            o_de_start <= (need_end <= period_out) ? de_start_nat
                        : (clamp_left > {10'd0, de_floor}) ? clamp_left[11:0] : de_floor;

        // pixel replay on the CE grid
        if (out_running && (o_ce_cnt == 0) && (o_cline > 22'd4)) begin
            win_q <= in_window;
            if (in_window) begin
                rd_addr <= line_base(rl) + o_px;
                o_px    <= o_px + 1'd1;
            end
        end
    end

    // ==================================================================
    //  CABINET MODE — simulazione fotometrica della geometria del tubo,
    //  timing 100% NATIVO (hs/vs/ce passthrough: il desync non esiste).
    // ==================================================================
    //  Per ogni riga d'uscita si calcola la posizione frazionaria nel
    //  raster compresso/allargato (DDA Q.8) e si emette la MISCELA DI LUCE
    //  che il fascio metterebbe li`:  out = (1-a)*L[s] + a*L[s+1] in LUCE
    //  LINEARE (gamma 2: quadrato -> blend -> radice intera). Conserva
    //  l'energia per riga: niente bande, niente pattern, niente shimmer —
    //  e` cio` che fa il potenziometro V-size del telaio, calcolato.
    //  Ancoraggio: enlarge cresce in basso, shrink ritira il top
    //  (causalita`) -> ricentrare con V-Shift. Richiede clk/pixel >= 8.

    // ---- VSync ritardato: quando l'enlarge sfora il blank inferiore, il
    //      VSync d'uscita slitta di K righe -> il riavvolgimento del CRT
    //      avviene DOPO le righe extra (che diventano visibili) e l'immagine
    //      sale di K righe: la crescita si auto-ricentra. K calcolato per
    //      frame, con tetto sia sullo spazio superiore sia sul margine dal
    //      bordo alto della finestra.
    reg  [23:0] vs_shreg;
    reg  [4:0]  t_vsdel;
    initial begin vs_shreg = 0; t_vsdel = 0; end
    always @(posedge clk) if (hs_rise) vs_shreg <= {vs_shreg[22:0], vs_in};
    wire vs_del = (t_vsdel == 0) ? vs_in : vs_shreg[t_vsdel - 1'd1];

    // ---- dominio riga: finestra + DDA frazionario ----
    reg        t_active, t_vsline;
    reg [5:0]  t_slotA;
    reg [9:0]  t_src;           // indice riga sorgente (per il clamp finale)
    reg [9:0]  t_row;           // riga della finestra (fine per CONTEGGIO)
    reg [9:0]  t_pxcnt;
    reg [17:0] t_pos;           // posizione sorgente Q10.8 nella finestra
    reg [7:0]  t_alpha;         // peso frazionario della riga s+1
    initial begin
        t_active=0; t_vsline=0; t_slotA=0; t_src=0; t_row=0; t_pxcnt=0; t_pos=0; t_alpha=0;
    end

    wire [5:0] t_slotA_p1 = (t_slotA == RING_LINES-1) ? 6'd0 : t_slotA + 1'd1;
    wire [5:0] t_slotA_p2 = (t_slotA_p1 == RING_LINES-1) ? 6'd0 : t_slotA_p1 + 1'd1;
    wire [5:0] t_slotB    = t_slotA_p1;

    // shrink (vsize>0) ancorato in basso: la finestra parte |vsize| righe giu`
    wire [9:0]  t_off       = vsize_eff[5] ? 10'd0 : {4'd0, vsize_eff[5:0]};
    wire [9:0]  win_start_t = nl_top + 10'd2 + t_off;

    // K del VSync ritardato: quanto la finestra sfora il blank inferiore
    // (bordo = ultima riga utile prima del vsync nativo del frame dopo),
    // limitato dallo shreg (24) e dallo spazio sopra la finestra
    wire [9:0] t_need_end = win_start_t + a_out_t;
    wire [9:0] t_bot_lim  = lines_nat - 10'd2;
    wire [9:0] t_over     = (t_need_end > t_bot_lim) ? (t_need_end - t_bot_lim) : 10'd0;
    wire [9:0] t_cap2     = (win_start_t > {6'd0, vs_lines} + 10'd8)
                            ? (win_start_t - {6'd0, vs_lines} - 10'd4) : 10'd0;
    wire [9:0] t_k1       = (t_over > 10'd24) ? 10'd24 : t_over;
    wire [9:0] t_k        = (t_k1 > t_cap2) ? t_cap2 : t_k1;
    always @(posedge clk) if (vs_rise) t_vsdel <= tube_mode ? t_k[4:0] : 5'd0;

    wire [17:0] t_pos_n = t_pos + {8'd0, step_q8};
    wire [9:0]  t_dint  = t_pos_n[17:8] - t_pos[17:8];   // 0, 1 o 2

    // ultima riga sorgente: il vicino s+1 non esiste -> peso a zero
    wire [7:0] alpha_eff = (t_src >= a_nat - 1'd1) ? 8'd0 : t_alpha;

    always @(posedge clk) begin
        if (hs_rise) begin
            // gate di visualizzazione sul VSync SPOSTATO: durante il vsync
            // nativo (se ritardato) le righe della finestra restano visibili
            t_vsline <= vs_del;
            // NIENTE letture di meta_px qui: il Cabinet legge solo righe
            // ATTIVE (finestra s in [0,a_nat)), tutte con lo stesso conteggio
            // -> basta lo scalare px_count_nat, zero mux sull'array.
            t_pxcnt  <= px_count_nat;
            if (tube_on && seen_de && ((nl + 1'd1) == win_start_t)) begin
                t_active <= 1;
                t_slotA  <= top_slot;
                t_src    <= 0;
                t_row    <= 0;
                t_pos    <= 0;
                t_alpha  <= 0;
            end else if (t_active) begin
                // fine finestra per CONTEGGIO righe (sopravvive al confine
                // di frame quando il VSync e` ritardato), mai per posizione
                if ((t_row >= a_out_t - 1'd1) || vs_del || ~tube_on) begin
                    t_active <= 0;
                end else begin
                    t_row   <= t_row + 1'd1;
                    t_pos   <= t_pos_n;
                    t_alpha <= t_pos_n[7:0];
                    t_src   <= t_src + t_dint;
                    if      (t_dint[1:0] == 2'd2) t_slotA <= t_slotA_p2;
                    else if (t_dint[1:0] == 2'd1) t_slotA <= t_slotA_p1;
                end
            end
        end
    end

    // ---- radice quadrata intera 16->8 bit, spezzata in due stadi ----
    function [31:0] isqrt_h(input [15:0] x0);
        reg [15:0] x, res;
        begin
            x = x0; res = 0;
            if (x >= res + 16'h4000) begin x = x - (res + 16'h4000); res = (res >> 1) + 16'h4000; end else res = res >> 1;
            if (x >= res + 16'h1000) begin x = x - (res + 16'h1000); res = (res >> 1) + 16'h1000; end else res = res >> 1;
            if (x >= res + 16'h0400) begin x = x - (res + 16'h0400); res = (res >> 1) + 16'h0400; end else res = res >> 1;
            if (x >= res + 16'h0100) begin x = x - (res + 16'h0100); res = (res >> 1) + 16'h0100; end else res = res >> 1;
            isqrt_h = {x, res};
        end
    endfunction

    function [7:0] isqrt_l(input [31:0] xr);
        reg [15:0] x, res;
        begin
            x = xr[31:16]; res = xr[15:0];
            if (x >= res + 16'h0040) begin x = x - (res + 16'h0040); res = (res >> 1) + 16'h0040; end else res = res >> 1;
            if (x >= res + 16'h0010) begin x = x - (res + 16'h0010); res = (res >> 1) + 16'h0010; end else res = res >> 1;
            if (x >= res + 16'h0004) begin x = x - (res + 16'h0004); res = (res >> 1) + 16'h0004; end else res = res >> 1;
            if (x >= res + 16'h0001) begin x = x - (res + 16'h0001); res = (res >> 1) + 16'h0001; end else res = res >> 1;
            isqrt_l = res[7:0];
        end
    endfunction

    // ---- pipeline pixel a 8 sottofasi (p_cnt 0..7 tra un CE e l'altro) ----
    reg  [9:0]  t_px, t_px_l;
    reg         t_fetch;
    reg  [7:0]  t_al;
    reg  [15:0] t_sqa_r, t_sqa_g, t_sqa_b;
    reg  [15:0] t_sqb_r, t_sqb_g, t_sqb_b;
    reg  [15:0] t_bl_r, t_bl_g, t_bl_b;
    reg  [31:0] t_h1_r, t_h1_g, t_h1_b;
    reg  [23:0] t_out;
    reg         t_out_v;
    initial begin
        t_px=0; t_px_l=0; t_fetch=0; t_al=0;
        t_sqa_r=0; t_sqa_g=0; t_sqa_b=0; t_sqb_r=0; t_sqb_g=0; t_sqb_b=0;
        t_bl_r=0; t_bl_g=0; t_bl_b=0; t_h1_r=0; t_h1_g=0; t_h1_b=0;
        t_out=0; t_out_v=0;
    end

    wire t_in_win = t_active && ~t_vsline && tube_on
                    && (pxde_cnt >= de_start_px) && (t_px < t_pxcnt);

    wire [24:0] t_mix_r = ( (9'd256 - {1'b0, t_al}) * t_sqa_r ) + ( {1'b0, t_al} * t_sqb_r );
    wire [24:0] t_mix_g = ( (9'd256 - {1'b0, t_al}) * t_sqa_g ) + ( {1'b0, t_al} * t_sqb_g );
    wire [24:0] t_mix_b = ( (9'd256 - {1'b0, t_al}) * t_sqa_b ) + ( {1'b0, t_al} * t_sqb_b );

    always @(posedge clk) begin
        if (pxl_cen) begin
            if (hs_in & ~hs_d) begin
                t_px    <= 0;
                t_fetch <= 0;
            end else begin
                t_fetch <= t_in_win;
                t_px_l  <= t_px;
                t_al    <= alpha_eff;
                if (t_in_win) t_px <= t_px + 1'd1;
            end
        end
        // fasi (indirizzo registrato -> dato A in ring_q durante la fase 3,
        // dato B durante la fase 4; quadrato calcolato direttamente li`):
        case (p_cnt)
            5'd0: rd_addr_t <= line_base(t_slotA) + t_px_l;
            5'd1: rd_addr_t <= line_base(t_slotB) + t_px_l;
            5'd3: begin
                t_sqa_r <= ring_q[23:16] * ring_q[23:16];
                t_sqa_g <= ring_q[15:8]  * ring_q[15:8];
                t_sqa_b <= ring_q[7:0]   * ring_q[7:0];
            end
            5'd4: begin
                t_sqb_r <= ring_q[23:16] * ring_q[23:16];
                t_sqb_g <= ring_q[15:8]  * ring_q[15:8];
                t_sqb_b <= ring_q[7:0]   * ring_q[7:0];
            end
            5'd5: begin
                t_bl_r <= t_mix_r[23:8];
                t_bl_g <= t_mix_g[23:8];
                t_bl_b <= t_mix_b[23:8];
            end
            5'd6: begin
                t_h1_r <= isqrt_h(t_bl_r);
                t_h1_g <= isqrt_h(t_bl_g);
                t_h1_b <= isqrt_h(t_bl_b);
            end
            5'd7: begin
                t_out   <= {isqrt_l(t_h1_r), isqrt_l(t_h1_g), isqrt_l(t_h1_b)};
                t_out_v <= t_fetch;
            end
            default: ;
        endcase
    end

    // ==================================================================
    //  OUTPUT MUX — engine output vs pure bypass
    // ==================================================================
    reg [7:0] r_q, g_q, b_q;
    reg       hs_q, vs_q, de_q, vb_q;
    initial begin r_q=0; g_q=0; b_q=0; hs_q=0; vs_q=0; de_q=0; vb_q=1; end
    always @(posedge clk) if (pxl_cen) begin
        r_q <= r_in;  g_q <= g_in;  b_q <= b_in;
        hs_q <= hs_in; vs_q <= vs_in; de_q <= de_in; vb_q <= vb_in;
    end

    initial begin
        r_out=0; g_out=0; b_out=0;
        hs_out=0; vs_out=0; de_out=0; vb_out=1; ce_out=0;
    end

    always @(posedge clk) begin
        if (tube_on) begin
            // CABINET: timing nativo puro; cambia solo il contenuto.
            // vb segue la finestra ESTESA, mai il VBlank nativo (il gate
            // vb_active di crt_adjust a valle ammazzerebbe le righe extra).
            ce_out <= pxl_cen;
            if (pxl_cen) begin
                hs_out <= hs_q;
                vs_out <= vs_del;   // VSync SPOSTATO: fa spazio alle righe extra e ricentra
                vb_out <= ~t_active;
                de_out <= t_out_v;
                if (t_out_v) {r_out, g_out, b_out} <= t_out;
                else         {r_out, g_out, b_out} <= 24'd0;
            end
        end else if (engine_on) begin
            // PVM: retimed line structure, pixels on the p_nat CE grid
            ce_out <= out_running && (o_ce_cnt == 0);
            hs_out <= out_running && (o_cline <= {10'd0, hs_w_out});
            vs_out <= o_vs;
            vb_out <= o_vb;
            if (o_ce_cnt == 0) begin
                de_out <= win_q;
                if (win_q) {r_out, g_out, b_out} <= ring_q;
                else       {r_out, g_out, b_out} <= 24'd0;
            end
        end else begin
            // BYPASS: registered passthrough at the input CE
            ce_out <= pxl_cen;
            if (pxl_cen) begin
                r_out <= r_q;  g_out <= g_q;  b_out <= b_q;
                hs_out <= hs_q; vs_out <= vs_q; de_out <= de_q; vb_out <= vb_q;
            end
        end
    end

endmodule
