# MiSTer-AnalogHSize

A small SystemVerilog module that horizontally stretches the **analog VGA**
output of a [MiSTer FPGA](https://github.com/MiSTer-devel) arcade core
without introducing shimmering, blending, or duplicated pixels.

## What it does

Every source pixel is emitted to the analog DAC for the same
**integer-uniform** number of pixel-clock periods. Because the stretch
factor is identical for every pixel on every line, the module produces
a perfectly uniform widening of the image:

- **No shimmering** on moving content (no fractional resampling).
- **No blending / blur** (the output value is byte-exact, identical
  to the source pixel).
- **No duplicated pixels** (each source pixel maps to exactly one
  DAC pixel, just held for a longer time).

The trade-off is a slightly lower analog horizontal sync rate (the
extra time is absorbed by shortened front and back porches), which
remains well within the tolerance of vintage 15 kHz CRTs and PVMs.

## Why two integration paths

The module was first written as a **sys-side** insertion: the stretch sits on
the analog DAC branch *inside* `sys_top.v`, so HDMI (which taps the stream
above that point) stays bit-identical. That is the cleanest result — but it
means editing `sys/sys_top.v`, which is framework code vendored from the
MiSTer template. Sorgelig does not accept that change upstream, and many
project rules forbid touching `sys/` at all (it gets clobbered on template
updates). So a core that must stay framework-clean cannot ship the sys-side
version.

That is why the **emu-side** variant exists: it runs the same stretch engine
entirely inside the core's `emu` wrapper, at the video-output boundary, with
**zero `sys_top.v` edits**. The core hands `sys_top` an already-stretched
stream. The catch is that this stream also reaches the HDMI scaler, so on
emu-side HDMI is **not** bit-identical — it follows the stretch (a fair
trade-off for a CRT/analog feature; leave it Off for untouched HDMI). Getting
the OSD to survive this required a specific fix on the vertical-blank input —
see [Acknowledgements](#acknowledgements).

Pick by whether you may edit `sys/sys_top.v` and whether HDMI must stay
untouched:

| | **sys-side** (`analog_hsize.sv`) | **emu-side** (`analog_hsize_emu.sv`) |
|---|---|---|
| Where | DAC stage inside `sys_top.v` | core's video-output boundary (`emu`) |
| Framework edits | yes (small, local to your repo) | **none** — `sys_top` untouched |
| HDMI | **bit-identical** (untouched) | follows the stretch (analog/CRT feature) |
| Best when | you can edit `sys_top` | `sys_top` is off-limits / vendored |

- **sys-side**: cleanest, HDMI stays exactly the same. See the guide below and
  [`examples/sys_top_snippet.v`](examples/sys_top_snippet.v).
- **emu-side**: zero framework edits. See
  [`docs/emu-side-integration.md`](docs/emu-side-integration.md) and
  [`examples/emu_side_snippet.v`](examples/emu_side_snippet.v).

## Resource cost

| Resource | Amount |
|---|---|
| M10K BRAM | ~1 |
| ALM | ~50 |
| DSP | 0 |

## Repository layout

```
MiSTer-AnalogHSize/
├── rtl/
│   ├── analog_hsize.sv         The module — sys-side variant
│   └── analog_hsize_emu.sv     The module — emu-side variant (vb_in fix)
├── docs/
│   ├── theory.md               Why and how it works
│   └── emu-side-integration.md Core-side integration (no sys_top edits)
└── examples/
    ├── sys_top_snippet.v       Reference glue for sys-side (sys_top.v)
    └── emu_side_snippet.v      Reference glue for emu-side (core .sv)
```

---

# Integration into a MiSTer arcade core

This guide covers the **sys-side** integration (`analog_hsize.sv`). It is done
entirely on the analog VGA path inside `sys_top.v`; on this path the HDMI scaler
path is not modified, so HDMI stays bit-identical. (For the emu-side variant,
which touches no framework code but does let the stretch reach HDMI, see
[`docs/emu-side-integration.md`](docs/emu-side-integration.md).)

> **Heads up**: this integration involves editing `sys/sys_top.v`,
> which is a file from the upstream MiSTer framework. The edits are
> small and local to your core repository, but they are not part of
> the framework upstream — keep them in mind when syncing `sys/`
> from upstream MiSTer-devel.

## 1. Add the module to the project

Copy `rtl/analog_hsize.sv` into your core's `sys/` directory (next
to `sys_top.v`) and add it to your `.qsf`:

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE sys/analog_hsize.sv
```

## 2. Expose an OSD option

In your top-level `.sv`, add a new entry to `CONF_STR`:

```verilog
"P1O[100:98],Analog VGA H-Size,0,+1,+2,+3,+4,+5,+6,+7;",
```

Forward the value to the framework via the `VGA_HSIZE` port (the same
slot that MiSTer already uses for analog video size hints):

```verilog
output  [2:0] VGA_HSIZE,
...
assign VGA_HSIZE = status[100:98];
```

## 3. Generate the read clock-enable inside sys_top.v

All the edits in this step go into `sys/sys_top.v`. The signal
`hsize_emu` is already declared and driven inside the stock
framework — it is the 3-bit unsigned value forwarded from the
core's `VGA_HSIZE` port via the `emu` instantiation:

```verilog
wire  [2:0] hsize_emu;
...
emu emu (
    ...
    .VGA_HSIZE(hsize_emu),
    ...
);
```

If your `sys_top.v` does not yet wire `VGA_HSIZE` into `emu`, add
the line above (the port already exists on the framework side).

The read rate (`pxl2_cen`) must be slower than the write rate
(`pxl_cen`): the read pixel lasts `(base + hsize)` cycles of `clk_vid`,
where **`base` is the core's native `clk_vid`-per-pixel period** — the
number of `clk_vid` ticks between two `vga_ce_sl` pulses:

```
base = clk_vid_freq / pixel_clock
```

> ⚠️ **Do not hardcode `base = 16`.** It is core-specific. For example a
> JTFRAME core with `clk_vid = 48 MHz` and a 6 MHz pixel clock has
> `base = 8`, so a hardcoded 16 makes even **+1** roughly *double* the
> image (`17/8 ≈ 2.1×`) instead of the intended `9/8 ≈ 1.12×`. This is
> the single most common integration mistake.

The counter must also reset on the rising edge of HSync so that every
line starts in a deterministic phase (this is what eliminates the
frame-to-frame "trembling" you would otherwise see).

To stay correct on **any** core, measure `base` at run time by counting
`clk_vid` cycles between `vga_ce_sl` pulses:

```verilog
// Auto-measure the core's native clk_vid-per-pixel period.
reg  [5:0] vga_base = 6'd16;
reg  [5:0] vga_pcnt = 6'd0;
always @(posedge clk_vid) begin
    if (vga_ce_sl) begin vga_base <= vga_pcnt + 6'd1; vga_pcnt <= 6'd0; end
    else                 vga_pcnt <= vga_pcnt + 6'd1;
end

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
wire vga_ce_sl2 = (hsize_emu == 3'd0) ? vga_ce_sl : (vga_ce_div == 6'd0);
```

(If you'd rather keep it simple, replace `vga_base` with a constant equal
to your core's `clk_vid/pixel` ratio and drop the measuring block — e.g.
`localparam [5:0] vga_base = 6'd8;` for the 48 MHz / 6 MHz case.)

`hsize_emu` is the 3-bit unsigned value coming from the OSD (the
`VGA_HSIZE` port). The module input is signed and the convention is
that *positive widening* corresponds to *negative `hsize`*; sys_top
already does the sign conversion:

```verilog
wire signed [3:0] hsize_emu_s = -$signed({1'b0, hsize_emu});
```

## 4. Insert the module on the analog branch

The stock MiSTer `sys_top.v` produces a slot-line ("`_sl`") stream
(`vga_data_sl`, `vga_hs_sl`, `vga_vs_sl`, `vga_de_sl`) and then
feeds it directly into the OSD overlay (`vga_osd`), whose output
drives the analog DAC pins. The HDMI scaler taps the stream
*above* this point, so it is unaffected by anything we add here.

Insert the H-Size module **between the slot-line stream and the
OSD**: take `vga_data_sl` / `vga_hs_sl` / `vga_vs_sl` / `vga_de_sl`
as inputs to the module, and feed its outputs (`vga_data_hs`,
`vga_hs_hs`, ...) into the OSD's inputs instead.

You will need to rewire the existing OSD instantiation: the line
that previously read `.din(vga_data_sl)` / `.hs_in(vga_hs_sl)` /
etc. should now read `.din(vga_data_hs)` / `.hs_in(vga_hs_hs)` /
etc. (names depend on your specific framework version).

```verilog
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
```

Then feed `vga_data_hs`, `vga_hs_hs`, `vga_vs_hs`, `vga_de_hs` into
the OSD overlay block and then to the analog DAC pin assignments
exactly as your core already does for the unmodified slot-line
stream.

## 5. Rebuild and test

Rebuild the core. With H-Size = 0 the analog output should be
bit-identical to the original (the module is in bypass mode). At
higher values the image gradually widens on the analog VGA output
while HDMI stays exactly the same (this HDMI-untouched property is
specific to the sys-side insertion described here).

If you see **trembling that drifts frame-to-frame**, the counter
reset on HSync is not wired correctly (step 3). If you see **moving
shimmer on scrolling content**, the outputs are being registered at
the wrong rate inside the module — verify that the build is using
the up-to-date `analog_hsize.sv` and that no other code is
re-clocking the outputs at the write rate after the module.

---

# Integration into a MiSTer arcade core (emu-side)

This is the **emu-side** integration (`analog_hsize_emu.sv`). The module runs
entirely inside the core's `emu` wrapper, at the video-output boundary, with
**zero `sys/sys_top.v` edits** — use this when the framework is off-limits or
vendored. The trade-off vs the sys-side path above: the stretched stream also
reaches the HDMI scaler, so **HDMI is not bit-identical — it follows the
stretch** (treat it as an analog/CRT feature; leave H-Size Off for untouched
HDMI). The full rationale and the non-obvious gotchas are in
[`docs/emu-side-integration.md`](docs/emu-side-integration.md); the complete
glue is in [`examples/emu_side_snippet.v`](examples/emu_side_snippet.v). The
steps below are the summary.

## 1. Add the module to the project

Copy `rtl/analog_hsize_emu.sv` into your core's RTL (e.g. `rtl/`) and add it
to your `.qip` / `.qsf`:

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE rtl/analog_hsize_emu.sv
```

Nothing goes into `sys/` and nothing in `sys_top.v` changes.

## 2. Expose the OSD option

In your top-level `.sv` `CONF_STR`, add an On/Off toggle plus an amount
(`H<n>` hides the amount until it is On; put `H` before `P`):

```verilog
"P1O[101],CRT Stretch,Off,On;",
"H1P1O[100:98],CRT Stretch Amount,0,1,2,3,4,5;",
```

and drive the menumask so the amount is hidden while off:

```verilog
.status_menumask({14'd0, ~status[101], 1'b0}),
...
wire [2:0] hsize = status[101] ? status[100:98] : 3'd0;   // 0 = bypass
```

## 3. Generate the read clock-enable

The read rate (`pxl2_cen`) is slower than the write rate (`pxl_cen`) by an
integer divisor `base + hsize` of the video clock, where
`base = clk_video / pixel` (16 on a 96 MHz / 6 MHz DEC0 core — **size it from
your own ratio**). Reset the counter on the HSync rising edge so every line
starts in a deterministic phase:

```verilog
reg  vga_hs_d;
always @(posedge clk_sys) vga_hs_d <= hs;
wire hs_rise = hs & ~vga_hs_d;

reg  [4:0] rd_div;
wire [4:0] rd_max = 5'd15 + {2'd0, hsize};   // 15 = base-1
always @(posedge clk_sys)
    if (hs_rise || rd_div == rd_max) rd_div <= 5'd0;
    else                             rd_div <= rd_div + 5'd1;

wire              rd_ce   = (hsize == 3'd0) ? ce_pix : (rd_div == 5'd0);
wire signed [3:0] hsize_s = -$signed({1'b0, hsize});   // module: <0 = wider
```

## 4. Instantiate the module — note `hb_in` vs `vb_in`

Feed the module the core's composed RGB (e.g. after your OSD/pause overlay).
The critical detail: `hb_in` gets the **combined** blank (`hb | vb`), but
`vb_in` gets the **TRUE vertical blank** (`vb`) — this is what lets the
downstream OSD find the vertical frame boundary while the horizontal window
still widens (see the doc, "the `vb_in` fix").

```verilog
analog_hsize_emu u_analog_hsize_emu (
    .clk(clk_sys), .pxl_cen(ce_pix), .pxl2_cen(rd_ce), .hsize(hsize_s),
    .r_in(av_r), .g_in(av_g), .b_in(av_b),
    .hs_in(hs), .vs_in(vs),
    .hb_in(hb | vb),   // combined blank on the horizontal edges
    .vb_in(vb),        // TRUE vertical blank -> OSD stays visible
    .r_out(str_r), .g_out(str_g), .b_out(str_b),
    .hs_out(str_hs), .vs_out(str_vs), .hb_out(str_hb), .vb_out(str_vb)
);
```

## 5. Drive the emu outputs and keep the OSD put

Mux the module outputs onto `VGA_*` when the stretch is active, and set
`CE_PIXEL = rd_ce`. To stop the OSD sliding when H-Shift moves the image,
build a `de_osd` window whose **rising is anchored to the native active
region** and feed it to `video_freak`'s `VGA_DE_IN`. See
[`examples/emu_side_snippet.v`](examples/emu_side_snippet.v) for the exact
wiring (H-Shift/V-Shift applied upstream, `de_osd`, bypass handling).

## 6. Rebuild and test

With CRT Stretch Off the output is bit-identical (bypass). At higher amounts
the analog image widens; HDMI follows the stretch too (expected for this
path). Same trembling/shimmer troubleshooting as the sys-side guide applies.

---

## Acknowledgements

- **Andrea Bogazzi** ([@asturur](https://github.com/asturur)) — diagnosed the
  **`vb_in` gotcha** while integrating this module core-side into a Deco16 /
  Caveman Ninja JTFRAME core. Feeding the *combined* blank into `vb_in`
  re-clamps the output window to the original width (the image looks stretched
  but clipped at the old right edge). His insight is what made the emu-side
  variant keep a working OSD: `analog_hsize_emu.sv` passes the **true** vertical
  blank and gates only `pass_q`, never the horizontal edges. He also wrote the
  elastic-FIFO and the auto-measured base fixes on the module.

---

## License

GNU GPL v3 or later. Compatible with the MiSTer framework license.

Author: Umberto Parisi ([rmonic79](https://github.com/rmonic79)), 2026.
