//============================================================================
//  sys_top_snippet.v
//
//  Reference glue logic for integrating analog_hsize into a MiSTer
//  core's sys_top.v. This is NOT a complete file — only the relevant
//  fragments that need to be added or modified are shown.
//
//  See ../docs/integration.md for the full step-by-step procedure.
//============================================================================


// ─── 1. Generate the read-side clock enable ────────────────────────────────
//
// The read pixel must last (base + hsize_emu) clk_vid cycles, where `base` is
// the core's NATIVE clk_vid-per-pixel period (i.e. how many clk_vid ticks
// elapse between two vga_ce_sl pulses). Each +1 of the OSD then adds exactly
// one clk_vid per pixel, a small uniform step.
//
// IMPORTANT: do NOT hardcode base = 16. It is core-specific:
//     base = clk_vid_freq / pixel_clock
//   e.g. a JTFRAME core with clk_vid = 48 MHz and a 6 MHz pixel clock has
//   base = 8, so a hardcoded 16 would make even "+1" roughly DOUBLE the image
//   (17/8 ≈ 2.1×) instead of the intended ~1.12×.
//
// To stay correct on any core we MEASURE the base at run time by counting
// clk_vid cycles between vga_ce_sl pulses. (If you prefer, replace vga_base
// with a constant equal to your core's clk_vid/pixel ratio and drop the
// measuring block.)

reg  [5:0] vga_base = 6'd16;   // auto-measured clk_vid-per-pixel period
reg  [5:0] vga_pcnt = 6'd0;
always @(posedge clk_vid) begin
    if (vga_ce_sl) begin
        vga_base <= vga_pcnt + 6'd1;
        vga_pcnt <= 6'd0;
    end else begin
        vga_pcnt <= vga_pcnt + 6'd1;
    end
end

// Counter modulo (base + hsize_emu) on clk_vid, reset on rising HSync for
// deterministic per-line phase. This is what guarantees uniform stretch
// without trembling.
reg vga_hs_sl_d;
always @(posedge clk_vid) vga_hs_sl_d <= vga_hs_sl;
wire vga_hs_rise = vga_hs_sl & ~vga_hs_sl_d;

reg  [5:0] vga_ce_div;
wire [5:0] vga_ce_max = vga_base - 6'd1 + {3'd0, hsize_emu};
always @(posedge clk_vid) begin
    if      (vga_hs_rise)               vga_ce_div <= 6'd0;
    else if (vga_ce_div >= vga_ce_max)  vga_ce_div <= 6'd0;
    else                                vga_ce_div <= vga_ce_div + 6'd1;
end

// When hsize_emu == 0 we want true bypass at write rate.
wire vga_ce_sl2 = (hsize_emu == 3'd0) ? vga_ce_sl : (vga_ce_div == 6'd0);


// ─── 2. Sign-convert the OSD value ─────────────────────────────────────────
//
// The OSD exposes 0..7 (unsigned). The module convention is that wider
// pixels correspond to negative hsize values. The framework already
// drives `hsize_emu` from the core's VGA_HSIZE port.

wire  [2:0] hsize_emu;             // unsigned, from VGA_HSIZE
wire signed [3:0] hsize_emu_s = -$signed({1'b0, hsize_emu});


// ─── 3. Instantiate the module on the analog VGA branch ────────────────────

wire [23:0] vga_data_hs;
wire        vga_hs_hs, vga_vs_hs, vga_de_hs, vga_hb_hs, vga_vb_hs;

analog_hsize u_analog_hsize (
    .clk      (clk_vid),
    .pxl_cen  (vga_ce_sl),
    .pxl2_cen (vga_ce_sl2),
    .hsize    (hsize_emu_s),
    .r_in     (vga_data_sl[23:16]),
    .g_in     (vga_data_sl[15:8]),
    .b_in     (vga_data_sl[7:0]),
    .hs_in    (vga_hs_sl),
    .vs_in    (vga_vs_sl),
    .hb_in    (~vga_de_sl),
    .vb_in    (~vga_de_sl),
    .r_out    (vga_data_hs[23:16]),
    .g_out    (vga_data_hs[15:8]),
    .b_out    (vga_data_hs[7:0]),
    .hs_out   (vga_hs_hs),
    .vs_out   (vga_vs_hs),
    .hb_out   (vga_hb_hs),
    .vb_out   (vga_vb_hs)
);
assign vga_de_hs = ~vga_hb_hs & ~vga_vb_hs;


// ─── 4. Continue with the OSD overlay using vga_data_hs / vga_hs_hs / ... ──
//
// The HDMI scaler taps the stream ABOVE this point (from vga_data_sl), so
// the HDMI path is completely unaffected by the H-Size stretch.
