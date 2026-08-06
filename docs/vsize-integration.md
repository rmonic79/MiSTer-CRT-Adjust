# CRT V-Size — integration guide

`rtl/crt_vsize.sv` is a **self-contained companion stage** for CRT Adjust:
vertical stretch/shrink of the analog picture, driven from the OSD, with two
exclusive modes (**PVM** = line retimer, **Cabinet** = native-timing
photometric scaling). This guide shows the complete wiring, taken verbatim
from the first shipping integration
([NeoGeo_MiSTer_Streamer](https://github.com/rmonic79/NeoGeo_MiSTer_Streamer),
sys-side, HW-validated on an arcade cabinet, a 9" PVM and a Barco RGB).

All code fragments below also live in
[`examples/vsize_integration_snippet.v`](../examples/vsize_integration_snippet.v).

---

## 1. Where it goes in the chain

**BEFORE** crt_adjust, which composes per-line and is agnostic to the line
period:

```
native video stream  →  crt_vsize  →  crt_adjust(_sys)  →  OSD / DAC
```

The module is usable identically core-side (inside your `emu` wrapper) or
sys-side (inside `sys_top.v` on the analog branch, where the HDMI scaler
taps the stream upstream and never sees any of it).

## 2. Requirements

| Requirement | Why |
|---|---|
| Uniform input pixel CE | the engine measures and replays the native pixel period |
| clk-to-pixel ratio ≥ 8 | the Cabinet photometric pipeline uses 8 sub-phases per pixel |
| TRUE vertical blank input | `vb_in` must be the real VBlank, **never** the combined blank (`~DE`) — feeding combined blank black-screens the downstream stages |
| BRAM | `RING_LINES × LINE_PX × 24` bit (46 × 384 ≈ 17 M10K) |

The module is **self-measuring**: frame period, line count, pixel period,
sync widths and the DE window are all measured at runtime. No per-core
timing parameters; NTSC/PAL switches are followed automatically. Until two
consecutive stable frames are measured it forces bypass, so switch-on is
always clean.

## 3. Ports

| Port | Dir | Meaning |
|---|---|---|
| `clk`, `pxl_cen` | in | video clock + uniform pixel CE |
| `active` | in | master ON/OFF (also self-bypasses when `vsize == 0`) |
| `tube_mode` | in | 0 = PVM (retimer) · 1 = Cabinet (native timing) |
| `vsize` | in | signed [5:0], lines added to the frame total: **+N = shorter picture, −N = taller** (note the OSD decode below negates, so the user's “+” means taller) |
| `r/g/b_in`, `hs/vs/de_in`, `vb_in` | in | native stream (`vb_in` = TRUE vertical blank) |
| `r/g/b_out`, `hs/vs/de/vb_out`, `ce_out` | out | processed stream for the next stage |

Parameters: `RING_LINES` (default 46 — must be ≥ `|vsize|·2 + 4` for PVM,
≥ `|vsize| + 4` for Cabinet), `LINE_PX` (pixel slots per ring line),
`FRONT_MIN` (PVM: minimum front porch after clamping), `SLEW_FRAMES`
(frames per 1-line ramp step; 1 = one click applies in ~3 frames).

## 4. OSD entries (tested strings, remap the bits to your free ones)

```verilog
"H1P1O[107:104],CRT V-Size,0,+1,+2,+3,+4,+5,+6,+7,-7,-6,-5,-4,-3,-2,-1;",
"H1P1O[108],CRT V-Size Mode,PVM,Cabinet;",
```

## 5. Decode (emu side)

One OSD step = 3 lines (~1.1 %). The negation makes the OSD “+” mean
*taller*, matching H-Size's “+ = bigger”:

```verilog
reg signed [5:0] crt_vsize;
reg              crt_vsmode;
wire signed [5:0] crt_vsz_step = $signed(status[107:104]);
always @(posedge CLK_VIDEO) if (ce_pix) begin
    crt_vsize  <= -(crt_vsz_step + (crt_vsz_step <<< 1));  // -3 × step
    crt_vsmode <= status[108];
end
```

## 6. Instantiation (sys-side, between the scanlines stage and crt_adjust)

```verilog
wire [23:0] vga_data_vz;
wire        vga_hs_vz, vga_vs_vz, vga_de_vz, vga_vb_vz, vga_ce_vz;
crt_vsize #(
    .RING_LINES(46),
    .LINE_PX   (384)
) u_crt_vsize (
    .clk     (clk_vid),
    .pxl_cen (vga_ce_sl),          // uniform native pixel CE
    .active  (crt_on),
    .tube_mode(crt_vsmode),
    .vsize   (crt_vsize),
    .r_in    (vga_data_sl[23:16]),
    .g_in    (vga_data_sl[15:8]),
    .b_in    (vga_data_sl[7:0]),
    .hs_in   (vga_hs_sl),
    .vs_in   (vga_vs_sl),
    .de_in   (vga_de_sl),
    .vb_in   (crt_vbl),            // TRUE vertical blank from the core
    .r_out   (vga_data_vz[23:16]),
    .g_out   (vga_data_vz[15:8]),
    .b_out   (vga_data_vz[7:0]),
    .hs_out  (vga_hs_vz),
    .vs_out  (vga_vs_vz),
    .de_out  (vga_de_vz),
    .vb_out  (vga_vb_vz),
    .ce_out  (vga_ce_vz)
);
```

Then feed **everything downstream from the `_vz` signals**, including
crt_adjust's clock enable and its `vb_in`:

```verilog
crt_adjust_sys #( ... ) u_crt_adjust_sys (
    .clk      (clk_vid),
    .pxl_cen  (vga_ce_vz),         // ← from crt_vsize, not the raw CE
    ...
    .hs_in    (vga_hs_vz),
    .vs_in    (vga_vs_vz),
    .hb_in    (~vga_de_vz),
    .vb_in    (vga_vb_vz),         // ← crt_vsize regenerates the TRUE vblank
    ...
);
```

**The one rule that bites:** every stage that extends or shrinks the
vertical window must pass its OWN regenerated `vb`, never the native one —
`crt_vsize` already does this (`vb_out` follows the extended window). Wire
`vb_in` of the next stage from `vb_out` of this one, always.

## 7. Behavior notes

* **Anchoring** — enlarge grows downward from the native top edge, shrink
  retracts the top (causality: a line cannot be shown before it arrives).
  Recenter with the companion V-Shift control. On large enlargements
  Cabinet mode micro-delays the output VSync, so the extra rows escape the
  vertical retrace and the picture recenters by itself.
* **Ramp** — vsize changes are applied 1 line per `SLEW_FRAMES` frames.
* **PVM mode range** is bounded by the monitor's H-lock (±2–3 % typical on
  broadcast monitors; arcade chassis usually refuse it — that is exactly
  what Cabinet mode is for). On the “+” side (shorter) the line blanking
  shrinks; the module narrows the HSync pulse adaptively, but the physical
  limit is the tube's horizontal retrace time.
* **Cabinet mode** cannot desync anything by construction; its trade-off is
  a very slight, uniform vertical softness (gamma-correct 2-tap in linear
  light — no banding, no doubled lines, no shimmer).

## 8. Bring-up checklist

1. `CRT Adjust Off` → picture bit-identical to the untouched core.
2. `On`, V-Size `0` → still bit-identical (internal bypass).
3. PVM mode, ±1..2 → picture grows/shrinks smoothly, monitor stays locked.
4. Cabinet mode, any value → sync must never move, at any setting.
5. Slow scrolls in Cabinet mode → no banding or shimmer; at most a subtle
   uniform softness.
