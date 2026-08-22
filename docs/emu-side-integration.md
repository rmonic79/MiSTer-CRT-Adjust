# Core-side integration (no `sys_top` edits)

The reference integration inserts `analog_hsize` inside `sys_top.v`, at the DAC
stage. That's the cleanest place, but it means editing framework code — which
many MiSTer cores (and project rules) treat as off-limits: `sys_top` is vendored
from the template and gets clobbered on updates.

This note shows the module working **entirely from the core's `emu`**, at the
video-output boundary, with **zero `sys_top` changes**. It was validated on a
jtframe-based arcade core (Data East DECO-16 / Caveman Ninja) driving a real
15 kHz CRT.

---

## Why it works from `emu` at all

The core hands `sys_top` one video stream: `CLK_VIDEO`, `CE_PIXEL`,
`VGA_R/G/B/HS/VS/DE`. `sys_top` then splits it two ways:

```
emu ── VGA_* / CE_PIXEL ──▶ sys_top ──┬──▶ HDMI scaler   (normalizes)
                                       └──▶ scanlines ─▶ OSD ─▶ vga_out ─▶ DAC
```

Two facts make the core-side insertion viable:

1. **The whole analog chain just passes `VGA_DE` through.** `scanlines`,
   `sync_fix`, `osd`, `vga_out` do not regenerate the active window — the DAC's
   window *is* whatever the core outputs. So if the core widens `DE`, the analog
   window widens.
2. **The HDMI scaler normalizes pixel *duration*, the analog DAC preserves it.**
   The scaler captures N active pixels (counted on `CE_PIXEL`) and fits them to
   the target size, so a duration change is invisible on HDMI. The analog DAC
   holds each pixel for its real duration, so the same change *is* the stretch.

So a transform that **keeps the pixel count but widens each pixel's duration**
stretches analog and leaves HDMI untouched — which is exactly what
`analog_hsize` does. It just has to run at the core's video-output boundary and
hand `sys_top` the already-stretched stream.

---

## The gotcha that cost us a day: `vb_in`

The first attempt stretched the *pixels* but the active window stayed pinned to
the original width — the image looked stretched and clipped at the old right
edge. It looked like the emu placement simply couldn't widen the window.

It was a wiring bug, not a placement limit. The mistake:

```verilog
// WRONG — re-clamps the output window to the original width
.hb_in ( ~av_de ),
.vb_in ( ~av_de ),          // av_de is the COMBINED active: ~(hblank | vblank)
...
assign VGA_DE = ~str_hb & ~str_vb;
```

`av_de` (a typical core's `DE`) is high only during active video, i.e. it already
carries **both** blanks. Feeding `~av_de` into `vb_in` makes `vb_out` rise the
instant the *input* active ends — the original right edge — while the FIFO is
still emitting the stretched tail. Since `VGA_DE = ~hb_out & ~vb_out`, that
`vb_out` chops the output `DE` back to the original width. Pixels widen; window
doesn't.

The fix is a single line: **do not put the horizontal blank into `vb_in`.**
Vertical blanking is already covered by `hb_out` (no pixels are pushed on vblank
lines, so `hb_out` stays high → `DE` low). Tie `vb_in` low:

```verilog
.hb_in ( ~av_de ),
.vb_in ( 1'b0    ),          // vertical blank is covered by hb_out
...
assign VGA_DE = ~str_hb & ~str_vb;   // vb_out is 0, so DE follows the widened hb
```

> **Suggested upstream doc change:** the `examples/sys_top_snippet.v` uses
> `.hb_in(~vga_de_sl), .vb_in(~vga_de_sl)`. That happens to work there only
> because of how the OSD stage consumes the stream; at the core-output boundary
> it re-clamps the window. Worth a one-line warning that `vb_in` must carry the
> *vertical* blank only.

---

## The integration

Insert the module after the core's video mixer (here jtframe's `arcade_video`),
between it and the `emu` output ports.

### 1. Route the mixer into internal wires

```verilog
wire        av_ce, av_hs, av_vs, av_de;
wire [23:0] av_rgb;
wire [ 1:0] av_sl;

arcade_video #(.WIDTH(256), .DW(24)) u_arcade_video (
    .clk_video          ( clk48        ),
    .ce_pix             ( pxl_cen      ),
    .RGB_in             ( game_rgb     ),
    .HBlank             ( ~LHBL        ),
    .VBlank             ( ~LVBL        ),
    .HSync              ( hs           ),
    .VSync              ( vs           ),
    .CLK_VIDEO          (              ),   // unused; we drive CLK_VIDEO below
    .CE_PIXEL           ( av_ce        ),
    .VGA_R              ( av_rgb[23:16]),
    .VGA_G              ( av_rgb[15:8] ),
    .VGA_B              ( av_rgb[7:0]  ),
    .VGA_HS             ( av_hs        ),
    .VGA_VS             ( av_vs        ),
    .VGA_DE             ( av_de        ),
    .VGA_SL             ( av_sl        ),
    .fx                 ( status[5:3]  ),
    .forced_scandoubler ( forced_scandoubler ),
    .gamma_bus          ( gamma_bus    )
);
```

### 2. Generate the read clock-enable on a 16×-pixel clock

Run the module on a clock that is **16× the pixel rate** (here `clk96`, with a
6 MHz pixel = 16 cycles). The read divider base is then 16, so every H-Size step
is `1/16 = 6.25%` — small and perfectly uniform (no per-pixel dithering, so no
shimmer). A slower read = wider pixels.

```verilog
wire [2:0] hsize = status[34:32];             // OSD 0..7

// arcade_video's CE_PIXEL is a clk48 pulse; edge-detect it into a 1-cycle
// write pulse on clk96 (clk96 = 2*clk48, same PLL -> synchronous).
reg  av_ce_d; always @(posedge clk96) av_ce_d <= av_ce;
wire av_wr = av_ce & ~av_ce_d;

// HSync rising locks the read phase per line.
reg  av_hs_d; always @(posedge clk96) av_hs_d <= av_hs;
wire av_hs_rise = av_hs & ~av_hs_d;

// Read one pixel every (16 + hsize) clk96 cycles.
reg  [4:0] rd_div;
wire [4:0] rd_max = 5'd15 + {2'd0, hsize};
always @(posedge clk96)
    if (av_hs_rise || rd_div == rd_max) rd_div <= 5'd0;
    else                                rd_div <= rd_div + 5'd1;

wire              rd_ce   = (hsize == 3'd0) ? av_wr : (rd_div == 5'd0); // 0 = bypass
wire signed [3:0] hsize_s = -$signed({1'b0, hsize});                    // module: <0 = wider
```

### 3. Instantiate `analog_hsize` (note `vb_in`)

```verilog
wire [23:0] str_rgb;
wire        str_hs, str_vs, str_hb, str_vb;

analog_hsize u_analog_hsize (
    .clk     ( clk96          ),
    .pxl_cen ( av_wr          ),   // write rate  (native pixel)
    .pxl2_cen( rd_ce          ),   // read rate   (slower = stretch)
    .hsize   ( hsize_s        ),
    .r_in    ( av_rgb[23:16]  ),
    .g_in    ( av_rgb[15:8]   ),
    .b_in    ( av_rgb[7:0]    ),
    .hs_in   ( av_hs          ),
    .vs_in   ( av_vs          ),
    .hb_in   ( ~av_de         ),
    .vb_in   ( 1'b0           ),   // <-- NOT ~av_de (see "The gotcha")
    .r_out   ( str_rgb[23:16] ),
    .g_out   ( str_rgb[15:8]  ),
    .b_out   ( str_rgb[7:0]   ),
    .hs_out  ( str_hs         ),
    .vs_out  ( str_vs         ),
    .hb_out  ( str_hb         ),
    .vb_out  ( str_vb         )
);
```

### 4. Drive the `emu` output ports

```verilog
assign CLK_VIDEO = clk96;                 // 16x pixel; CE_PIXEL gates the real rate
assign CE_PIXEL  = rd_ce;
assign VGA_R     = str_rgb[23:16];
assign VGA_G     = str_rgb[15:8];
assign VGA_B     = str_rgb[7:0];
assign VGA_HS    = str_hs;
assign VGA_VS    = str_vs;
assign VGA_DE    = ~str_hb & ~str_vb;      // follows the widened active
assign VGA_SL    = av_sl;
```

That's the whole thing. HDMI stays clean (the scaler normalizes), analog
stretches, and `sys_top` is untouched.

---

## Recentering: don't — shift HSync upstream instead

The FIFO is **left-anchored**: it grows the active rightward into the
front porch. You can auto-recenter by delaying the HSync fed to the module, but
it needs per-core constants (front/back-porch sizes) and CRT trimming — a lot of
fragile glue.

We removed it. If your core already has an **analog H-position** control
(e.g. jtframe's `jtframe_resync`) *upstream* of the mixer, that offset shifts the
same HSync `analog_hsize` resyncs on. So one manual H-Pos knob gives you both the
recentering **and** the extra headroom, for free:

```
game ─▶ jtframe_resync (H-Pos) ─▶ arcade_video ─▶ analog_hsize ─▶ emu out
                 └── shifts HS, which is the HS analog_hsize resyncs on ──┘
```

---

## Caveats / trade-offs

- **Reference clock.** You need a clock ≥ 16× the pixel rate for 6.25% steps
  (8× → the smallest usable step rounds to ~12.5%; 32× → 3.125%). This is a
  clock choice, not a per-core tuning number.
- **Stretch ceiling.** Left-anchored growth uses the front porch; beyond it the
  FIFO drops the tail (right-edge clip). Nudge H-Pos, or cap the OSD range to the
  blanking budget. You can never stretch past total blanking — the CRT line
  period is fixed.
- **Scandoubler.** The base assumes the native pixel rate (scandoubler off — the
  analog/CRT case). With a scandoubler doubling `CE_PIXEL`, the base changes;
  treat this as a direct-video / CRT feature or derive the base from the measured
  `CE_PIXEL` period.
- **Not a drop-in.** The glue above is jtframe/MiSTer-arcade flavored
  (`arcade_video`, `clk96`, the pixel-ce structure). The *shape* transfers to any
  core; the exact wiring doesn't.

## vs. the `sys_top` insertion

Neither strictly wins:

| | `sys_top` insertion (reference) | core-side (`emu`) |
|---|---|---|
| Placement | DAC stage, cleanest | video-output boundary |
| Framework edits | yes | **none** |
| Per-core glue | minimal | some (clock/ce/mixer) |
| Best when | you can edit `sys_top` | `sys_top` is off-limits |

Use this core-side path when editing `sys_top` isn't an option; otherwise the
DAC-stage insertion is simpler.
