# How and why it works

## The problem

Arcade cores on MiSTer produce a fixed-resolution pixel stream
(typically 256 or 320 pixels per visible line, at ~6 MHz pixel
clock). On the analog VGA output this drives a CRT at roughly
15.6 kHz horizontal sync, which is the rate vintage arcade
monitors expect.

Some users want the analog output to fill more of the screen
horizontally without rebuilding the core's timing or rerouting
through the HDMI scaler. Naively widening the image causes one
of three artifacts:

1. **Shimmering** — fractional resampling (1.25 source pixels per
   output pixel, etc.) means that at every line some source pixel
   is duplicated and some is not, and *which* one shifts every
   frame as the integer-vs-fractional boundary moves around. On
   moving graphics this looks like rapid pixel-level twinkling.
2. **Blending / blur** — averaging neighbouring source pixels to
   hide the staircase from option 1. This produces a uniform
   image but soft, blurry edges, which is unwanted on sprite art.
3. **Duplicated pixels** — repeating each source pixel an integer
   number of times. Only 1×, 2×, 3× ... are possible, with no
   intermediate stretch values.

This module avoids all three by working in a fourth, cleaner way.

## The trick: slow the read clock, keep the rate integer

The line buffer is written at the **core's pixel rate** (one source
pixel per `pxl_cen` pulse). The DAC reads it at a **slower rate**
(`pxl2_cen`), and `pxl2_cen` is generated as an integer divisor
`16 + hsize` of the system clock. Because the divisor is integer,
**every** DAC pixel lasts exactly the same `16 + hsize` clock cycles
— no pixel is repeated, no pixel is fractional, no pixel is skipped.

That means every source pixel is shown on the DAC for *the same
amount of extra time*, and there is therefore no shimmering: the
sampling is uniform along the line and stays uniform from frame to
frame because the counter resets on each rising HSync.

Mathematically, with `hsize = k` (k = 0..7) and a 96 MHz `clk_vid`:

```
core pixel period = clk_vid / 16     = 6.00 MHz       → 166.7 ns
DAC  pixel period = clk_vid / (16+k) = 6/(1+k/16) MHz → 166.7×(16+k)/16 ns
```

so for `k=4` each DAC pixel lasts `166.7 × 20/16 = 208.3 ns`, i.e.
each source pixel is held on the DAC 25% longer.

The CRT sees the same number of pixels (256), each one wider, plus
an HSync period that is correspondingly longer. HSync rate drops
from 15.6 kHz to about 12.5 kHz at `k=7`, which is comfortably
inside what 15 kHz CRTs and PVMs accept (the lower limit of those
monitors is around 12 kHz, and the front/back porches shrink to
keep the rest of the line within spec).

## Why the output register matters

There is one subtle implementation point that took some iteration
to find. When `pxl_cen ≠ pxl2_cen`, the **output registers** in the
module must be clocked by `pxl2_cen` (the slow DAC rate), not by
`pxl_cen` (the fast write rate). Otherwise the fast write clock
keeps re-latching whatever the slow read side has most recently
produced, which breaks the "every pixel lasts exactly `16+hsize`
clock cycles" property and re-introduces the very shimmering this
module exists to avoid.

In bypass mode (`hsize == 0`) the outputs are clocked at `pxl_cen`
so the module behaves as a transparent passthrough.

## Why the HSync reset matters

The divisor counter for `pxl2_cen` must be reset to 0 on each rising
edge of `hs_in` (HSync). Without this reset the counter free-runs
and its phase relative to the start of the visible line drifts a
little every frame, which the eye perceives as a small horizontal
trembling. Resetting it on HSync locks the phase, and from there
each scan line starts in exactly the same place.

These two details are what make the module produce a clean,
uniform widening of the analog image.

## Storage: a small elastic FIFO, not a whole line

The original design kept a full-line ping-pong buffer (two 1024-deep
banks of 24-bit RGB), which costs ~3 M10K block-RAMs. That is more
than is actually needed.

Because the read side is slower than the write side by the integer
ratio `(16+k)/16`, within one active line the writer can only get
*so far* ahead of the reader. With `N` active pixels per line the
maximum lead is

```
peak_occupancy = N * k / (16 + k)
```

For a 320-pixel line at maximum stretch (`k = 7`) that is about 97
pixels — roughly a tenth of a line. So instead of a whole-line buffer
we only need a small FIFO sized to that peak, and the design becomes:

- **Push** one RGB sample into the FIFO on each `pxl_cen` during active
  video.
- **Pop** one sample on each `pxl2_cen`, gated so the reader never runs
  ahead of what has been pushed *this line* (`emit_cnt < nactive_run`).
- **Resync** the read pointer to the write pointer on every rising
  HSync, so the FIFO returns to empty each line and can never drift.

Gating on the running per-line count (rather than the previous line's
total) means the first visible line after vertical blank is handled
correctly and the FIFO never has to hold an entire unread line — so a
small `DEPTH` of 128 comfortably covers every practical arcade mode
(a 320-pixel line peaks at ~97; wider lines can't stretch far enough to
get near the limit, because the stretched active still has to fit inside
the line porches). It fits in LUTRAM/MLAB (`ramstyle = "MLAB"`) with
**zero M10K**.

Both ports live in the same `clk` domain (they are just two different
clock-enables), so there is no clock-domain crossing and no gray-code
pointer machinery — an ordinary binary read/write pointer pair is
sufficient and safe.

The simulation in `rtl/tb_analog_hsize.sv` confirms the peak-occupancy
formula in practice (52/128 at `k = 4`, 79/128 at `k = 7`) and that the
output is byte-exact and correctly ordered.
