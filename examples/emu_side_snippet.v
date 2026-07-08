//============================================================================
//  emu_side_snippet.v
//
//  Reference glue for the EMU-SIDE integration of analog_hsize_emu.sv:
//  the module lives INSIDE the core's `emu` and sys_top.v is NOT touched.
//  This is NOT a complete file — only the fragments to add to your core's
//  top-level .sv. See ../docs/emu-side-integration.md for the full rationale.
//
//  Validated on Data East DEC0 cores (ActFancer, Trio The Punch) driving a
//  real 15 kHz CRT. clk_sys = 96 MHz, pixel = 6 MHz -> base = clk/pixel = 16.
//  Adjust the divider base to your core's clk_video/pixel ratio.
//============================================================================


// ─── 0. Signals assumed to exist in your core ──────────────────────────────
//  clk_sys                : the video clock (== CLK_VIDEO), e.g. 96 MHz
//  ce_pix                 : native pixel clock-enable (e.g. 6 MHz pulse)
//  hs, vs, hb, vb         : core's raw HSync/VSync/HBlank/VBlank
//  av_r, av_g, av_b       : the core's composed RGB, 8-bit each (e.g. after an
//                           OSD/pause overlay), taken to internal wires (NOT
//                           straight to the VGA_R/G/B pins — re-driven below).
//                           If your core is 4/5-bit per channel, expand to 8.
//  H_TOTAL_AF, V_TOTAL_AF : line/frame totals in pixels (for the shift shregs)


// ─── 1. OSD option: CRT Stretch on/off + amount ────────────────────────────
//  In CONF_STR (H<n> hides "Amount" until Stretch is On; H BEFORE P):
//    "P1O[101],CRT Stretch,Off,On;",
//    "H1P1O[100:98],CRT Stretch Amount,0,1,2,3,4,5;",
//  and .status_menumask({14'd0, ~status[101], 1'b0}) on hps_io.
wire [2:0] hsize = status[101] ? status[100:98] : 3'd0;   // 0 = bypass


// ─── 2. Analog H-Shift / V-Shift, UPSTREAM of the module ───────────────────
//  The H-Shift is applied to HS/VS BEFORE the module so it composes with the
//  stretch. IMPORTANT: because the stretch FIFO is left-anchored (it grows the
//  image rightward), you usually need MORE left travel than right. Bias the
//  OSD range accordingly, e.g. 0..+48 (left) and -15..-1 (right):
//    "P1O[97:92],Analog VGA H-Shift,0,+1,...,+48,-15,-14,...,-1;"
reg [5:0] osd_vga_hshift_d;
always @(posedge clk_sys) if (ce_pix) osd_vga_hshift_d <= status[97:92];
//  bitfield 0..48 -> delay +0..+48 (left); 49..63 -> -15..-1 (right = HTotal-|N|)
wire [8:0] hshift_tap = (osd_vga_hshift_d <= 6'd48)
    ? {3'd0, osd_vga_hshift_d}
    : (9'(H_TOTAL_AF) - (9'd64 - {3'd0, osd_vga_hshift_d}));

reg [H_TOTAL_AF-1:0] hsync_shreg;
always @(posedge clk_sys) if (ce_pix) hsync_shreg <= {hsync_shreg[H_TOTAL_AF-2:0], hs};
reg vga_hs_reg;
always @(posedge clk_sys) if (ce_pix)
    vga_hs_reg <= (hshift_tap == 9'd0) ? hs : hsync_shreg[hshift_tap - 9'd1];

reg hs_d;
always @(posedge clk_sys) if (ce_pix) hs_d <= hs;
wire line_tick = ce_pix && (hs & ~hs_d);
reg signed [5:0] osd_vga_vshift_d;
always @(posedge clk_sys) if (line_tick) osd_vga_vshift_d <= $signed(status[28:23]);
wire [8:0] vshift_tap = osd_vga_vshift_d[5]
    ? (9'(V_TOTAL_AF) + {{3{osd_vga_vshift_d[5]}}, osd_vga_vshift_d})
    : {3'd0, osd_vga_vshift_d};
reg [V_TOTAL_AF-1:0] vsync_line_shreg;
always @(posedge clk_sys) if (line_tick) vsync_line_shreg <= {vsync_line_shreg[V_TOTAL_AF-2:0], vs};
reg vga_vs_reg;
always @(posedge clk_sys) if (line_tick)
    vga_vs_reg <= (vshift_tap == 9'd0) ? vs : vsync_line_shreg[vshift_tap - 9'd1];


// ─── 3. Read-side clock enable (the divider that makes the stretch) ────────
//  Read one pixel every (base + hsize) clk_sys cycles. base = clk/pixel = 16
//  here. Reset on the (already-shifted) HSync rising for deterministic phase.
wire hsize_active = (hsize != 3'd0);
reg  vga_hs_reg_d;
always @(posedge clk_sys) vga_hs_reg_d <= vga_hs_reg;
wire shifted_hs_rise = vga_hs_reg & ~vga_hs_reg_d;

reg  [4:0] rd_div;
wire [4:0] rd_max = 5'd15 + {2'd0, hsize};   // 15 = base-1
always @(posedge clk_sys)
    if (shifted_hs_rise || rd_div == rd_max) rd_div <= 5'd0;
    else                                     rd_div <= rd_div + 5'd1;

wire              rd_ce   = (hsize == 3'd0) ? ce_pix : (rd_div == 5'd0); // 0=bypass
wire signed [3:0] hsize_s = -$signed({1'b0, hsize});   // module: <0 = wider


// ─── 4. Instantiate analog_hsize_emu (note hb_in vs vb_in) ─────────────────
wire [7:0] str_r, str_g, str_b;
wire       str_hs, str_vs, str_hb, str_vb;
analog_hsize_emu u_analog_hsize_emu (
    .clk      (clk_sys),
    .pxl_cen  (ce_pix),          // write rate (native pixel)
    .pxl2_cen (rd_ce),           // read rate (slower = stretch)
    .hsize    (hsize_s),
    .r_in     (av_r),
    .g_in     (av_g),
    .b_in     (av_b),
    .hs_in    (vga_hs_reg),      // shifted HS (H-Shift upstream)
    .vs_in    (vga_vs_reg),      // shifted VS (V-Shift upstream)
    .hb_in    (hb | vb),         // combined blank ~DE (horizontal edges)
    .vb_in    (vb),              // TRUE vertical blank -> gates pass_q so the OSD
                                 //   finds the vertical boundary (see module).
    .r_out    (str_r), .g_out (str_g), .b_out (str_b),
    .hs_out   (str_hs), .vs_out (str_vs),
    .hb_out   (str_hb), .vb_out (str_vb)
);


// ─── 5. OSD stays PUT: a DE window anchored to the NATIVE active ───────────
//  The MiSTer OSD centers itself on the RISING edge of VGA_DE. If VGA_DE
//  followed the module's (shifted) str_hb, the OSD would slide with the image
//  when H-Shift is used. To pin it: build a DE whose RISING is anchored to the
//  NATIVE active region, closing on the stretched active's end. The analog
//  image still moves (via VGA_HS = str_hs); only the OSD stays centered on the
//  physical screen.
wire str_active = ~str_hb;
reg  str_active_d;
always @(posedge clk_sys) if (rd_ce) str_active_d <= str_active;
wire str_fall = str_active_d & ~str_active;         // end of stretched active

wire native_active = ~(hb | vb);
reg  native_active_d;
always @(posedge clk_sys) if (ce_pix) native_active_d <= native_active;
wire native_rise = native_active & ~native_active_d; // start of native active

reg de_osd;
always @(posedge clk_sys) begin
    if      (native_rise) de_osd <= 1'b1;
    else if (str_fall)    de_osd <= 1'b0;
    if (vb)               de_osd <= 1'b0;
end


// ─── 6. Drive the emu output ports ─────────────────────────────────────────
//  When stretch is active: RGB/HS/VS from the module, CE_PIXEL = rd_ce.
//  VGA_DE comes from video_freak fed with `de_osd` (native-anchored window).
assign VGA_R  = hsize_active ? str_r  : av_r;
assign VGA_G  = hsize_active ? str_g  : av_g;
assign VGA_B  = hsize_active ? str_b  : av_b;
assign VGA_HS = hsize_active ? str_hs : vga_hs_reg;
assign VGA_VS = hsize_active ? str_vs : vga_vs_reg;
assign CE_PIXEL  = hsize_active ? rd_ce : ce_pix;
assign VGA_HSIZE = 3'd0;   // sys-side path unused (H-Size done here in emu)
//  In your video_freak instance, also route:
//    .CE_PIXEL  (hsize_active ? rd_ce : ce_pix),
//    .VGA_DE_IN (hsize_active ? de_osd : ~(hb | vb)),
