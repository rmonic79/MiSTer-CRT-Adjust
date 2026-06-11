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
- **HDMI output is untouched** — the module sits only on the analog
  branch, after the core's video composition and before the analog
  DAC pins.

The trade-off is a slightly lower analog horizontal sync rate (the
extra time is absorbed by shortened front and back porches), which
remains well within the tolerance of vintage 15 kHz CRTs and PVMs.

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
│   └── analog_hsize.sv      The standalone module
├── docs/
│   └── theory.md               Why and how it works
└── examples/
    └── sys_top_snippet.v       Reference glue logic for sys_top.v
```

---

# Integration into a MiSTer arcade core

This guide walks through adding `analog_hsize.sv` to an existing
MiSTer arcade core. The integration is done entirely on the analog VGA
path inside `sys_top.v`; the HDMI scaler path is not modified.

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
(`pxl_cen`) by an integer divisor `(16 + hsize)` of `clk_vid`. The
counter must reset on the rising edge of HSync so that every line
starts in a deterministic phase (this is what eliminates the
frame-to-frame "trembling" you would otherwise see).

```verilog
reg vga_hs_sl_d;
always @(posedge clk_vid) vga_hs_sl_d <= vga_hs_sl;
wire vga_hs_rise = vga_hs_sl & ~vga_hs_sl_d;

reg  [4:0] vga_ce_div;
wire [4:0] vga_ce_max = 5'd15 + {2'd0, hsize_emu};
always @(posedge clk_vid) begin
    if      (vga_hs_rise)              vga_ce_div <= 5'd0;
    else if (vga_ce_div == vga_ce_max) vga_ce_div <= 5'd0;
    else                                vga_ce_div <= vga_ce_div + 5'd1;
end
wire vga_ce_sl2 = (hsize_emu == 3'd0) ? vga_ce_sl : (vga_ce_div == 5'd0);
```

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
while HDMI stays exactly the same.

If you see **trembling that drifts frame-to-frame**, the counter
reset on HSync is not wired correctly (step 3). If you see **moving
shimmer on scrolling content**, the outputs are being registered at
the wrong rate inside the module — verify that the build is using
the up-to-date `analog_hsize.sv` and that no other code is
re-clocking the outputs at the write rate after the module.

---

## License

GNU GPL v3 or later. Compatible with the MiSTer framework license.

Author: Umberto Parisi ([rmonic79](https://github.com/rmonic79)), 2026.
