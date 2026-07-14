//============================================================================
//  sys_top_snippet.v
//
//  Reference glue for integrating crt_adjust_sys into a MiSTer core's
//  sys_top.v. This is NOT a complete file — only the fragments to add or
//  modify. HDMI stays bit-identical because the module sits only on the
//  analog VGA branch (the scaler taps the stream above this point).
//
//  See the README ("Integration (sys-side)") for the procedure and
//  ../docs/theory.md for how each control works.
//
//  NOTE: crt_adjust_sys exposes all three controls (H-Size, H-Position,
//  V-Shift). Drive them from OSD status bits forwarded into sys_top (via spare
//  VGA_* hint ports, or your own wires). The engine is identical to the
//  core-side crt_adjust.sv — only the insertion point differs.
//============================================================================


// ─── 1. OSD values forwarded from the core (decode to signed) ──────────────
//  crt_on / hsize / hpos / vshift are forwarded from the core's CONF_STR into
//  sys_top (through spare hint ports or added wires). Decode like the core-side
//  snippet:
wire              crt_on;                 // On/Off
wire signed [4:0] hsize_s;                // signed 5-bit: 0 native, +1..+15 enlarge, -1..-16 shrink
wire signed [8:0] hpos_off;               // H-Position (0..48 right, -48..-1 left)
wire signed [5:0] vshift_off;             // V-Shift lines


// ─── 2. Read-side clock enable: quarter-cycle stepped, reset on HSync ──────
//  Read one pixel every (base + hsize) QUARTERS of clk_vid. base = 64 quarters
//  (= 16 whole cycles) on a 96 MHz / 6 MHz DEC0-style path. Reset on the rising
//  HSync of the slot-line stream for deterministic per-line phase.
reg vga_hs_sl_d;
always @(posedge clk_vid) vga_hs_sl_d <= vga_hs_sl;
wire vga_hs_rise = vga_hs_sl & ~vga_hs_sl_d;

wire [7:0] rd_period = 8'd64 + {{3{hsize_s[4]}}, hsize_s};  // -16..+15 -> 48..79
reg  [7:0] rd_acc;
wire rd_tick = (rd_acc + 8'd4) >= {1'b0, rd_period};
always @(posedge clk_vid) begin
    if      (vga_hs_rise) rd_acc <= 8'd0;
    else if (rd_tick)     rd_acc <= rd_acc + 8'd4 - {1'b0, rd_period};
    else                  rd_acc <= rd_acc + 8'd4;
end
wire vga_ce_sl2 = crt_on ? rd_tick : vga_ce_sl;


// ─── 3. True vertical blank for vb_in ──────────────────────────────────────
//  hb_in gets the COMBINED blank (~vga_de_sl); vb_in needs the TRUE vertical
//  blank so the OSD keeps a valid vertical boundary. Derive true VBlank from
//  the slot-line VSync/DE as your framework version allows (a common way:
//  latch ~DE across a whole line and treat all-blank lines as VBlank).
wire vga_vb_true;   // = true vertical blank (framework-specific derivation)


// ─── 4. Instantiate crt_adjust_sys on the analog VGA branch ────────────────
wire [23:0] vga_data_hs;
wire        vga_hs_hs, vga_vs_hs, vga_de_hs, vga_hb_hs, vga_vb_hs;

crt_adjust_sys #(.VTOTAL(263)) u_crt_adjust_sys (
    .clk      (clk_vid),
    .pxl_cen  (vga_ce_sl),
    .pxl2_cen (vga_ce_sl2),
    .active   (crt_on),
    .hsize    (hsize_s),
    .hoffset  (hpos_off),
    .voffset  (vshift_off),
    .r_in     (vga_data_sl[23:16]),
    .g_in     (vga_data_sl[15:8]),
    .b_in     (vga_data_sl[7:0]),
    .hs_in    (vga_hs_sl),                // NATIVE slot-line HSync
    .vs_in    (vga_vs_sl),
    .hb_in    (~vga_de_sl),               // combined blank on horizontal edges
    .vb_in    (vga_vb_true),              // TRUE vertical blank -> OSD stays visible
    .r_out    (vga_data_hs[23:16]),
    .g_out    (vga_data_hs[15:8]),
    .b_out    (vga_data_hs[7:0]),
    .hs_out   (vga_hs_hs),
    .vs_out   (vga_vs_hs),
    .hb_out   (vga_hb_hs),
    .vb_out   (vga_vb_hs)
);
assign vga_de_hs = ~vga_hb_hs & ~vga_vb_hs;


// ─── 5. Continue with the OSD overlay using vga_data_hs / vga_hs_hs / ... ──
//  Rewire the existing OSD instance from vga_data_sl -> vga_data_hs, etc.
//  The HDMI scaler taps the stream ABOVE this point (from vga_data_sl), so the
//  HDMI path is completely unaffected by CRT Adjust.
