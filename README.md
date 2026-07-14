# CRT Adjust — analog CRT geometry for MiSTer arcade cores

*(formerly "MiSTer-AnalogHSize")*

A small SystemVerilog module that lets a [MiSTer FPGA](https://github.com/MiSTer-devel)
arcade core **resize and reposition its analog VGA picture from the OSD**, so it
fits your CRT perfectly — **without ever making the CRT lose sync**, and without
shimmering, blur, or duplicated pixels.

It started life as a horizontal-stretch-only module ("Analog H-Size"). It has
since grown into a full alignment tool exposed in the OSD as **CRT Adjust**,
with three controls driven from one always-on line buffer:

| Control | What it does | Range (typical) |
|---|---|---|
| **H-Size** | stretch **or** squeeze the image horizontally | −16 … +15 |
| **H-Position** | slide the picture left / right | −48 … +48 px |
| **V-Shift** | move the picture up / down | −16 … +15 lines |

The old H-Size-only modules are still in [`rtl/old/`](rtl/old/) for anyone who
wants just that — but new cores should use **CRT Adjust**.

---

## The idea in one sentence

**It moves the picture *content* through a line buffer while the sync signals
stay exactly as the core produced them** — so the CRT keeps its lock at all
times, and you can slide and resize the image *live* without the screen rolling,
tearing, or losing hold.

That is the whole trick, and it is what separates this from the usual way of
"moving the image" (shoving the blanking/sync windows around), which makes a
real CRT drop sync the moment you push it far enough.

### Why it looks clean

Each source pixel is emitted to the DAC for an **integer-uniform** number of
pixel-clock periods — the same hold time for every pixel on every line. Because
nothing is resampled fractionally and no pixel is ever blended or dropped:

- **No shimmering** on moving/scrolling content
- **No blur** — the output value is byte-exact, identical to the source pixel
- **No trembling** — the read counter is reset on the **native HSync**, so every
  line starts in a deterministic phase

### How each control works (and why it never desyncs)

- **H-Size** changes the **read rate** out of the line buffer. Reading slower
  than you wrote makes each pixel last longer → the image widens (`hsize > 0`,
  enlarge); reading faster narrows it (`hsize < 0`, shrink). The read rate is
  stepped in **quarter-cycle** increments via an accumulator, so the size steps
  are fine (~1.5 % each), not coarse. `HSync` is never touched.
- **H-Position** offsets the **read address** (`rd_addr = rdcnt − hoffset`) and
  the active-window compare. The visible content slides left/right; `HSync`
  stays native → no horizontal desync, at any offset.
- **V-Shift** delays `VSync` by N whole lines through a per-line shift register.
  It moves the sync a few lines, which a CRT tolerates easily → no vertical
  desync. The picture content is untouched.

`Off` is a pure passthrough. When `On`, the line buffer is always live, so
H-Position and V-Shift work even with H-Size at 0.

---

## Two variants — pick by *where you can wire it*

The engine is identical in both files. They are separate only because the
**hook-up point is different**, and that changes what happens to HDMI.

| | **core-side** — [`rtl/crt_adjust.sv`](rtl/crt_adjust.sv) | **sys-side** — [`rtl/crt_adjust_sys.sv`](rtl/crt_adjust_sys.sv) |
|---|---|---|
| Where you insert it | inside your core's `emu` wrapper, at the video-output boundary | inside `sys_top.v`, on the analog DAC branch only |
| `sys_top.v` edits | **none** — framework untouched | **yes** (small, local to your repo) |
| HDMI | **follows the adjust** (whole video path is resized) | **bit-identical** (HDMI taps the stream above the insertion point) |
| Use it when | you must not / cannot edit `sys/` (the usual case) | you *can* edit `sys_top.v` and want HDMI left untouched |

**Recommended: core-side** (`crt_adjust.sv`). It needs zero framework changes,
so it stays fully MiSTer-devel compliant and survives `sys/` template updates.
The only trade-off is that HDMI follows the stretch while CRT Adjust is `On`
(leave it `Off` for an untouched HDMI image). This is the variant shipping in
real cores today.

**sys-side** (`crt_adjust_sys.sv`) keeps HDMI perfectly bit-identical, because
the stretch sits only on the analog DAC path — but it requires editing
`sys_top.v`, which is vendored framework code (not accepted upstream, clobbered
when you resync `sys/`). Functionally the two are the same three controls.

> **Legacy:** the original stretch-only modules live in
> [`rtl/old/`](rtl/old/) — `analog_hsize.sv` (sys-side) and
> `analog_hsize_emu.sv` (core-side). They still work; they just don't have
> H-Position / V-Shift. Prefer `crt_adjust*` for new work.

---

## Resource cost

| Resource | Amount |
|---|---|
| M10K BRAM | ~1 (24-bit line buffer, ping-pong banks) |
| ALM | ~50 |
| DSP | 0 |

---

## Integration (core-side, recommended)

Full walkthrough in
[`docs/core-side-integration.md`](docs/core-side-integration.md); complete glue
in [`examples/core_side_snippet.v`](examples/core_side_snippet.v). Summary:

### 1. Add the module

```tcl
set_global_assignment -name SYSTEMVERILOG_FILE rtl/crt_adjust.sv
```

Nothing goes into `sys/`; `sys_top.v` is not touched.

### 2. OSD options

In your top-level `CONF_STR`, add an On/Off toggle plus the three amounts. Put
`H1` before `P1` so the amounts stay hidden until CRT Adjust is On:

```verilog
"P1O[101],CRT Adjust,Off,On;",
"H1P1O[100:96],CRT H-Size,0,+1,...,+15,-16,...,-1;",     // signed 5-bit
"H1P1O[85:79],CRT H-Position,0,+1,...,+48,-48,...,-1;",  // 7-bit, wrap-encoded
"H1P1O[78:74],CRT V-Shift,0,+1,...,+15,-16,...,-1;",     // signed 5-bit
```

and hide the amounts while Off:

```verilog
.status_menumask({14'd0, ~status[101], 1'b0}),   // H1 hidden unless On
```

### 3. Decode the OSD values

```verilog
reg  crt_on;   always @(posedge clk_sys) if (ce_pix) crt_on   <= status[101];
reg signed [4:0] hsize_s;  always @(posedge clk_sys) if (ce_pix) hsize_s <= $signed(status[100:96]);
reg signed [5:0] vshift_s; always @(posedge clk_sys) if (ce_pix) vshift_s <= $signed(status[78:74]);

// H-Position: 0..48 = right (+), 79..127 = left (-)
reg [6:0] hpos_d; always @(posedge clk_sys) if (ce_pix) hpos_d <= status[85:79];
wire signed [8:0] hpos_off = (hpos_d <= 7'd48)
    ? $signed({2'b0, hpos_d})
    : $signed({2'b0, hpos_d}) - 9'sd128;
```

### 4. Generate the read clock-enable

The read rate is slower/faster than the write rate by an integer amount, stepped
in **quarter cycles** so the H-Size steps are fine. `base` is your
`clk / pixel_clock` ratio (64 quarters = 16 whole cycles on a 96 MHz / 6 MHz
core — **size it from your own ratio**). Reset the accumulator on the **native**
HSync so every line starts in the same phase:

```verilog
reg HSync_d; always @(posedge clk_sys) HSync_d <= HSync;
wire native_hs_rise = HSync & ~HSync_d;

wire [7:0] rd_period = 8'd64 + {{3{hsize_s[4]}}, hsize_s};  // -16..+15 -> 48..79 quarters
reg  [7:0] rd_acc;
wire rd_tick = (rd_acc + 8'd4) >= {1'b0, rd_period};
always @(posedge clk_sys) begin
    if      (native_hs_rise) rd_acc <= 8'd0;
    else if (rd_tick)        rd_acc <= rd_acc + 8'd4 - {1'b0, rd_period};
    else                     rd_acc <= rd_acc + 8'd4;
end
wire rd_ce = crt_on ? rd_tick : ce_pix;
```

### 5. Instantiate — feed it the NATIVE sync

`VTOTAL` is your core's total lines per frame (needed by the V-Shift shift
register). Pass the **native** `HSync` / `VSync` in — that is what keeps the CRT
locked.

```verilog
crt_adjust #(.VTOTAL(263)) u_crt_adjust (
    .clk(clk_sys), .pxl_cen(ce_pix), .pxl2_cen(rd_ce),
    .active(crt_on),
    .hsize(hsize_s), .hoffset(hpos_off), .voffset(vshift_s),
    .r_in(av_r), .g_in(av_g), .b_in(av_b),
    .hs_in(HSync),            // NATIVE HSync -> no desync
    .vs_in(VSync),
    .hb_in(HBlank | VBlank),
    .vb_in(VBlank),
    .r_out(str_r), .g_out(str_g), .b_out(str_b),
    .hs_out(str_hs), .vs_out(str_vs), .hb_out(str_hb), .vb_out(str_vb)
);
```

### 6. Mux outputs and keep the OSD anchored

Drive `VGA_*` from the module when `crt_on`, from the native signals when Off,
and set `CE_PIXEL = rd_ce`. So the OSD does not slide when H-Position moves the
image, build a `de_osd` window whose **rising edge is anchored to the native
active region** (and whose falling edge follows the stretched width), and feed
it to `video_freak`'s `VGA_DE_IN`. The exact wiring is in
[`examples/core_side_snippet.v`](examples/core_side_snippet.v).

### 7. Rebuild and test

With CRT Adjust **Off** the output is bit-identical (pure bypass). **On**, the
picture resizes/moves live and the CRT stays locked. Two classic symptoms if
something is miswired:

- **Trembling that drifts frame-to-frame** → the read counter is not reset on
  the native HSync (step 4).
- **Shimmer on scrolling content** → the module outputs are being re-clocked at
  the write rate somewhere after the module; they must stay at the read rate.

---

## Integration (sys-side, HDMI stays bit-identical)

Use `rtl/crt_adjust_sys.sv` and insert it inside `sys_top.v`, between the
framework's slot-line stream (`vga_*_sl`) and the OSD overlay that drives the
analog DAC pins. HDMI taps the stream above that point, so it stays untouched.
The OSD decode and read-clock-enable logic are the same three controls as
core-side; the only difference is you generate them inside `sys_top.v` and wire
the module between `vga_*_sl` and the OSD. Reference glue:
[`examples/sys_top_snippet.v`](examples/sys_top_snippet.v).

> **Heads up:** this edits `sys/sys_top.v`, upstream framework code. The change
> is small and local to your repo, but it is not upstreamed and will be clobbered
> if you resync `sys/` from MiSTer-devel. If `sys/` is off-limits, use the
> core-side variant instead.

---

## Repository layout

```
CRT-Adjust/  (repo: MiSTer-AnalogHSize)
├── rtl/
│   ├── crt_adjust.sv          CRT Adjust — core-side (recommended)
│   ├── crt_adjust_sys.sv      CRT Adjust — sys-side (HDMI bit-identical)
│   └── old/
│       ├── analog_hsize.sv        legacy H-Size only — sys-side
│       └── analog_hsize_emu.sv    legacy H-Size only — core-side
├── docs/
│   ├── theory.md                  Why and how it works
│   └── core-side-integration.md   Core-side integration (no sys_top edits)
└── examples/
    ├── core_side_snippet.v        Reference glue for core-side (your core .sv)
    └── sys_top_snippet.v          Reference glue for sys-side (sys_top.v)
```

---

## Acknowledgements

- **Andrea Bogazzi** ([@asturur](https://github.com/asturur)) — help along the
  way, including the original core-side integration and the `vb_in` insight (feed
  the module the **true** vertical blank, not the combined blank, so the
  downstream OSD keeps a valid vertical frame boundary while the horizontal
  window still widens). He also contributed the elastic-FIFO and auto-measured
  base fixes on the earlier module.

The **CRT Adjust** module (H-Size + H-Position + V-Shift, content-shift design)
is by **rmonic79**.

---

## License

GNU GPL v3 or later. Compatible with the MiSTer framework license.

Author: Umberto Parisi ([rmonic79](https://github.com/rmonic79)), 2026.
