//============================================================================
//  core_side_snippet.v
//
//  Reference glue for the CORE-SIDE integration of crt_adjust.sv:
//  the module lives INSIDE the core's `emu` wrapper and sys_top.v is NOT
//  touched. This is NOT a complete file — only the fragments to add to your
//  core's top-level .sv. See ../docs/core-side-integration.md for the rationale.
//
//  With crt_adjust ALL THREE controls (H-Size, H-Position, V-Shift) live inside
//  the module — you no longer shift the sync upstream by hand. You just decode
//  the OSD values, generate the read clock-enable, and wire the native sync in.
//
//  Validated on Seibu D-Con (GundamSD) and Data East DEC0 cores driving a real
//  15 kHz CRT. clk_sys = 96 MHz, pixel = 6 MHz -> base = 64 quarters (= 16 whole
//  cycles). Size the read period from your own clk_video/pixel ratio.
//============================================================================


// ─── 0. Signals assumed to exist in your core ──────────────────────────────
//  clk_sys                    : the video clock (== CLK_VIDEO), e.g. 96 MHz
//  ce_pix                     : native pixel clock-enable (e.g. 6 MHz pulse)
//  HSync, VSync, HBlank, VBlank : the core's NATIVE raw sync/blank
//  av_r, av_g, av_b           : the core's composed RGB, 8-bit each (e.g. after
//                               an OSD/pause overlay), on internal wires (NOT
//                               straight to VGA_R/G/B — re-driven below).
//  timing_hpos                : the core's horizontal pixel counter (for line_tick)
//  H_TOTAL, V_TOTAL           : line / frame totals (V_TOTAL sizes the V-Shift shreg)


// ─── 1. OSD options: On/Off + the three amounts ────────────────────────────
//  In CONF_STR (H1 hides the amounts until On; H BEFORE P):
//    "P1O[101],CRT Adjust,Off,On;",
//    "H1P1O[100:96],CRT H-Size,0,+1,...,+15,-16,...,-1;",     // signed 5-bit
//    "H1P1O[85:79],CRT H-Position,0,+1,...,+48,-48,...,-1;",  // 7-bit wrap-encoded
//    "H1P1O[78:74],CRT V-Shift,0,+1,...,+15,-16,...,-1;",     // signed 5-bit
//  and .status_menumask({14'd0, ~status[101], 1'b0}) on hps_io.


// ─── 2. Decode the OSD values ──────────────────────────────────────────────
reg crt_on;
always @(posedge clk_sys) if (ce_pix) crt_on <= status[101];

// H-Size: signed 5-bit. 0 = native, +1..+15 enlarge, -1..-16 shrink.
reg signed [4:0] hsize_s;
always @(posedge clk_sys) if (ce_pix) hsize_s <= $signed(status[100:96]);

// H-Position: 7-bit wrap. 0..48 = +0..+48 (right), 79..127 = -48..-1 (left).
reg [6:0] hpos_d;
always @(posedge clk_sys) if (ce_pix) hpos_d <= status[85:79];
wire signed [8:0] hpos_off = (hpos_d <= 7'd48)
    ? $signed({2'b0, hpos_d})
    : $signed({2'b0, hpos_d}) - 9'sd128;

// V-Shift: signed 5-bit, -16..+15 lines.
reg signed [5:0] vshift_off;
always @(posedge clk_sys) if (ce_pix) vshift_off <= $signed(status[78:74]);


// ─── 3. Read clock-enable: quarter-cycle stepped, reset on NATIVE HSync ─────
//  Read one pixel every (base + hsize) QUARTERS of clk_sys. base = 64 quarters
//  (= 16 whole cycles) here. Quarter stepping makes each H-Size step ~1.5%.
//  Reset the accumulator on the NATIVE HSync rise -> deterministic phase/line.
reg HSync_d;
always @(posedge clk_sys) HSync_d <= HSync;
wire native_hs_rise = HSync & ~HSync_d;

wire [7:0] rd_period = 8'd64 + {{3{hsize_s[4]}}, hsize_s};  // -16..+15 -> 48..79
reg  [7:0] rd_acc;
wire rd_tick = (rd_acc + 8'd4) >= {1'b0, rd_period};
always @(posedge clk_sys) begin
    if      (native_hs_rise) rd_acc <= 8'd0;
    else if (rd_tick)        rd_acc <= rd_acc + 8'd4 - {1'b0, rd_period};
    else                     rd_acc <= rd_acc + 8'd4;
end
wire rd_ce = crt_on ? rd_tick : ce_pix;


// ─── 4. Instantiate crt_adjust — feed it the NATIVE sync ───────────────────
//  hs_in/vs_in are the core's raw HSync/VSync. The module shifts CONTENT only,
//  so passing native sync in is what keeps the CRT locked.
wire [7:0] str_r, str_g, str_b;
wire       str_hs, str_vs, str_hb, str_vb;
crt_adjust #(.VTOTAL(V_TOTAL)) u_crt_adjust (
    .clk      (clk_sys),
    .pxl_cen  (ce_pix),          // write rate (native pixel)
    .pxl2_cen (rd_ce),           // read rate (H-Size)
    .active   (crt_on),
    .hsize    (hsize_s),
    .hoffset  (hpos_off),        // H-Position (content shift, sync untouched)
    .voffset  (vshift_off),      // V-Shift (VSync delayed N lines)
    .r_in     (av_r), .g_in (av_g), .b_in (av_b),
    .hs_in    (HSync),           // NATIVE HSync -> no desync
    .vs_in    (VSync),
    .hb_in    (HBlank | VBlank),
    .vb_in    (VBlank),
    .r_out    (str_r), .g_out (str_g), .b_out (str_b),
    .hs_out   (str_hs), .vs_out (str_vs),
    .hb_out   (str_hb), .vb_out (str_vb)
);


// ─── 5. OSD stays PUT: a DE window anchored to the NATIVE active ────────────
//  The MiSTer OSD centers on the RISING edge of VGA_DE. If VGA_DE followed the
//  module's (shifted) str_hb, the OSD would slide with the image when
//  H-Position is used. Pin it: rising anchored to the NATIVE active region,
//  falling on the stretched active's end. The image still moves (VGA_HS =
//  str_hs); only the OSD stays centered on the physical screen.
wire line_tick = ce_pix && (timing_hpos == 10'(H_TOTAL - 1));
reg vblank_1l;
always @(posedge clk_sys) if (line_tick) vblank_1l <= VBlank;
wire native_active = ~(HBlank | vblank_1l);
reg  native_active_d;
always @(posedge clk_sys) if (ce_pix) native_active_d <= native_active;
wire native_rise = native_active & ~native_active_d;   // start of native active

wire str_active = ~str_hb;
reg  str_active_d;
always @(posedge clk_sys) if (rd_ce) str_active_d <= str_active;
wire str_fall = str_active_d & ~str_active;            // end of stretched active

reg de_osd;
always @(posedge clk_sys) begin
    if      (native_rise) de_osd <= 1'b1;
    else if (str_fall)    de_osd <= 1'b0;
end


// ─── 6. Drive the emu output ports ─────────────────────────────────────────
//  On: RGB/HS/VS from the module, CE_PIXEL = rd_ce. Off: native passthrough.
assign VGA_R  = crt_on ? str_r  : av_r;
assign VGA_G  = crt_on ? str_g  : av_g;
assign VGA_B  = crt_on ? str_b  : av_b;
assign VGA_HS = crt_on ? str_hs : HSync;
assign VGA_VS = crt_on ? str_vs : VSync;
//  In your video_freak instance, also route:
//    .CE_PIXEL  (crt_on ? rd_ce : ce_pix),
//    .VGA_DE_IN (crt_on ? de_osd : ~(HBlank | VBlank)),
