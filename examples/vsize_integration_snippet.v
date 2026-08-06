//============================================================================
//  vsize_integration_snippet.v
//
//  Reference glue for CRT V-Size (rtl/crt_vsize.sv) — fragments taken
//  VERBATIM from the first shipping integration, NeoGeo_MiSTer_Streamer
//  (sys-side, HW-validated on arcade cabinet + 9" PVM + Barco RGB).
//  This is NOT a complete file: only the pieces to add.
//
//  Chain:  native stream -> crt_vsize -> crt_adjust(_sys) -> OSD / DAC
//  Guide:  ../docs/vsize-integration.md
//============================================================================


// ─── 1. OSD entries (CONF_STR) — remap the status bits to your free ones ────
//  V-Size: 15 values, 1 OSD step = 3 lines (~1.1%). "+" = taller.
//  Mode:   PVM (line retimer) / Cabinet (native timing, photometric).
//
//  "H1P1O[107:104],CRT V-Size,0,+1,+2,+3,+4,+5,+6,+7,-7,-6,-5,-4,-3,-2,-1;",
//  "H1P1O[108],CRT V-Size Mode,PVM,Cabinet;",


// ─── 2. Decode (emu side) ───────────────────────────────────────────────────
//  The module convention is vsize +N = SHORTER picture; the negation below
//  makes the OSD "+" mean TALLER, consistent with H-Size's "+ = bigger".
reg signed [5:0] crt_vsize;
reg              crt_vsmode;
wire signed [5:0] crt_vsz_step = $signed(status[107:104]);
always @(posedge CLK_VIDEO) if (ce_pix) begin
	crt_vsize  <= -(crt_vsz_step + (crt_vsz_step <<< 1));  // -3 x step
	crt_vsmode <= status[108];
end
//  Export crt_vsize / crt_vsmode (and the TRUE vertical blank of the core)
//  to wherever the chain lives — in the NeoGeo Streamer these travel from
//  emu to sys_top through three added ports: CRT_VSIZE, CRT_VSMODE, CRT_VBL.


// ─── 3. crt_vsize instance — FIRST stage of the CRT chain ───────────────────
//  pxl_cen must be the UNIFORM native pixel CE (clk/pixel ratio >= 8).
//  vb_in must be the TRUE vertical blank — NEVER the combined blank (~DE).
wire [23:0] vga_data_vz;
wire        vga_hs_vz, vga_vs_vz, vga_de_vz, vga_vb_vz, vga_ce_vz;
crt_vsize #(
	.RING_LINES(46),   // >= 2*|vsize|+4 (PVM) ; vsize max +/-21 -> 46
	.LINE_PX   (384)   // pixel slots per ring line
) u_crt_vsize (
	.clk     (clk_vid),
	.pxl_cen (vga_ce_sl),
	.active  (crt_on),
	.tube_mode(crt_vsmode),
	.vsize   (crt_vsize),
	.r_in    (vga_data_sl[23:16]),
	.g_in    (vga_data_sl[15:8]),
	.b_in    (vga_data_sl[7:0]),
	.hs_in   (vga_hs_sl),
	.vs_in   (vga_vs_sl),
	.de_in   (vga_de_sl),
	.vb_in   (crt_vbl),                // TRUE vblank from the core
	.r_out   (vga_data_vz[23:16]),
	.g_out   (vga_data_vz[15:8]),
	.b_out   (vga_data_vz[7:0]),
	.hs_out  (vga_hs_vz),
	.vs_out  (vga_vs_vz),
	.de_out  (vga_de_vz),
	.vb_out  (vga_vb_vz),
	.ce_out  (vga_ce_vz)
);


// ─── 4. crt_adjust(_sys) downstream — fed ENTIRELY from the _vz signals ─────
//  THE RULE THAT BITES: a stage that extends/shrinks the vertical window
//  must hand its OWN regenerated vb to the next stage. crt_vsize does this
//  (vb_out follows the extended window): wire vb_in from vga_vb_vz, never
//  from the native vblank, or the extra rows get blacked out downstream.
crt_adjust_sys #(
	.VTOTAL   (264),
	.HTOTAL   (384),
	.HPOS_MODE(1)
) u_crt_adjust_sys (
	.clk      (clk_vid),
	.pxl_cen  (vga_ce_vz),             // <- from crt_vsize, not the raw CE
	.pxl2_cen (vga_ce_sl2),            // read-rate generator, see sys_top_snippet.v
	.active   (crt_on),
	.hsize    (crt_hsize),
	.hoffset  (crt_hpos),
	.voffset  (crt_vshift),
	.r_in     (vga_data_vz[23:16]),
	.g_in     (vga_data_vz[15:8]),
	.b_in     (vga_data_vz[7:0]),
	.hs_in    (vga_hs_vz),
	.vs_in    (vga_vs_vz),
	.hb_in    (~vga_de_vz),
	.vb_in    (vga_vb_vz),             // <- regenerated TRUE vblank
	.r_out    (vga_data_hs[23:16]),
	.g_out    (vga_data_hs[15:8]),
	.b_out    (vga_data_hs[7:0]),
	.hs_out   (vga_hs_hs),
	.vs_out   (vga_vs_hs),
	.hb_out   (vga_hb_hs),
	.vb_out   (vga_vb_hs),
	.hs_ref_out(crt_hs_ref)
);
//  ...then the OSD overlay composes on vga_data_hs / vga_hs_hs / etc.
//  Complete live reference: sys/sys_top.v and NeoGeo.sv in
//  https://github.com/rmonic79/NeoGeo_MiSTer_Streamer (branch "streamer").
