# How and why it works

> This document explains the **CRT Adjust** engine. The module exposes three
> controls — **H-Size**, **H-Position** and **V-Shift** — from one line buffer.
> The common principle behind all three: **the picture *content* is
> shifted/resized, the sync signals stay native.** That is why the CRT never
> loses lock, no matter how far you push a control. The sections below explain
> each in turn, starting with H-Size (the original engine).
>
> Numbers here use a DEC0-style core (`clk_video` 96 MHz / 6 MHz pixel), where
> one pixel = 16 clock cycles. That ratio is **not universal**: the general
> form is `base = clk_video / pixel`. Size everything from your own ratio.
>
> The same engine integrates two ways — inside `sys_top.v` (HDMI stays
> bit-identical) or entirely core-side (no framework edits). For the core-side
> variant see [core-side-integration.md](core-side-integration.md).

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

## H-Size — the trick: change the read rate, keep the hold uniform

The line buffer is written at the **core's pixel rate** (one source
pixel per `pxl_cen` pulse). The DAC reads it at a **different rate**
(`pxl2_cen`): read *slower* than you wrote and each pixel lasts longer
→ the image **widens**; read *faster* and it **narrows**. H-Size is
therefore bidirectional (stretch *and* squeeze), unlike the original
widen-only module.

The read rate is stepped in **quarter cycles** through a small
accumulator, not in whole-cycle divisor steps. On a `base = 64`
quarters (= 16 whole cycles) core the period is `64 + hsize` quarters,
so each H-Size step is one quarter cycle ≈ **1.5 %** — fine enough to
land the width exactly where you want it, instead of the coarse jumps
a whole-cycle divisor gives you. The hold time is still uniform for
every pixel on the line, so there is **no shimmering**: the sampling is
uniform along the line and stays uniform frame to frame because the
accumulator resets on each rising **native** HSync.

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
uniform resizing of the analog image. The rest of the H-Size design
is a straightforward ping-pong line buffer.

## H-Position — shift the content, not the sync

H-Position slides the picture left/right. The naive way — moving the
blanking/sync window — makes a CRT drop horizontal lock once you push
it far enough. This module does it the safe way: it offsets only the
**read address** into the line buffer,

```
rd_addr = rdcnt - hoffset
```

and shifts the active-window compare (`pass_q`) by the same `hoffset`.
The visible content moves; **`hs_out` is never touched**, so it stays
byte-for-byte the native HSync. The CRT sees an unchanged sync and a
moved picture → the image slides with **no horizontal desync at any
offset**. Positive `hoffset` moves right, negative moves left.

## V-Shift — delay the sync a few lines

V-Shift moves the picture up/down. Vertically a CRT has plenty of
tolerance, so here it is fine to move the sync itself — by a few whole
lines. A per-line shift register captures `vs_in` once per line (on the
native HSync edge) and taps it `|voffset|` lines back (or forward),
producing a `VSync` delayed/advanced by N lines:

```
vsync_line_shreg <= {vsync_line_shreg[VTOTAL-2:0], vs_in};   // once per line
vs_shifted       <= vsync_line_shreg[vshift_tap - 1];
```

`VTOTAL` (total lines per frame) sizes the shift register. The picture
content is untouched; only the vertical sync position changes, which
the monitor absorbs → **no vertical desync**. Positive moves down,
negative up.

## The common thread

All three controls obey the same rule: **change what the viewer sees,
leave the sync the core generates as-is** (H-Size via read rate,
H-Position via read address, V-Shift via a few lines of VSync delay).
That is the entire reason the CRT stays locked while you adjust the
picture live.
