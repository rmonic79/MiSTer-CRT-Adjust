# How and why it works

> This document explains the **CRT Adjust** engine. The module exposes three
> controls — **H-Size**, **H-Position** and **V-Shift** — from one line buffer.
> The common principle behind all three: **the picture is repositioned through
> the line buffer, and every part of the engine restarts on one shared line
> reference.** That is why the CRT never loses lock, no matter how far you push
> a control. The sections below explain each in turn, starting with H-Size (the
> original engine).
>
> Numbers here use a DEC0-style core (`clk_video` 96 MHz / 6 MHz pixel), where
> one pixel = 16 clock cycles. That ratio is **not universal**: the general
> form is `base = clk_video / pixel`. Size everything from your own ratio.
>
> The same engine integrates two ways: core-side (recommended — no framework
> edits, stays within the MiSTer-devel rules) or inside `sys_top.v` (keeps HDMI
> bit-identical for H-Size, but edits framework code). For the core-side variant
> see [core-side-integration.md](core-side-integration.md).

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
accumulator resets on each rise of the engine's line reference
(`hs_ref_out` — see the H-Position section).

Mathematically, taking a widening of `k` whole cycles on a 96 MHz
`clk_vid` (the signed `hsize` counts quarters; `k = hsize/4`):

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

In bypass mode (`active == 0`) the outputs are clocked at `pxl_cen`
so the module behaves as a transparent passthrough. Note that bypass
is tied to the On/Off control, not to `hsize == 0`: with the module
On the buffer stays live even at size 0, so H-Position and V-Shift
still work.

## Why the line-reference reset matters

The accumulator generating `pxl2_cen` must be reset to 0 once per
line. Without that reset it free-runs and its phase relative to the
start of the visible line drifts a little every frame, which the eye
perceives as a small horizontal trembling.

It must be reset on the **same** edge the module's own engine uses —
the reference the module publishes as `hs_ref_out` — and not on the
raw `hs_in`. In `HPOS_CONTENTSHIFT` the two are the same signal, so
either works; in `HPOS_SYNCSHIFT` they are not, and using the raw
HSync leaves the read rate running out of phase with the read
counter. That mismatch is what made the old upstream scheme drift
and lose sync when shrinking.

These two details are what make the module produce a clean,
uniform resizing of the analog image. The rest of the H-Size design
is a straightforward ping-pong line buffer.

## H-Position — two mechanisms, selected by `HPOS_MODE`

H-Position slides the picture left/right. There are two ways to do it and
**both are in the module**; the `HPOS_MODE` parameter picks which one is
built. They do not differ in whether they desync (neither does) — they
differ in **how they fail at the extremes**, which is why the right one
depends on the game's geometry.

### `HPOS_CONTENTSHIFT` (1) — shift the content

Offsets only the **read address** into the line buffer,

```
rd_addr = rdcnt - hoffset
```

and shifts the active-window compare (`pass_q`) by the same `hoffset`.
The visible content moves; **`hs_out` is never touched**, so it stays
byte-for-byte the native HSync, and the whole engine keeps restarting on
that native edge — which is why this mode stays rock-solid even while
H-Size is *shrinking* the picture.

Its limit: the content can only move as far as the line buffer window
allows. On a **narrow game anchored to one side** of the line (say 256
active pixels with a wide asymmetric back porch), pushing toward the
short-margin side walks the content out of the window and a **black
block** appears at that edge.

### `HPOS_SYNCSHIFT` (0) — shift the sync

The original mechanism, kept. A line-length shift register delays
`hs_in` by N pixels and that **shifted HSync becomes the output sync**;
the content stays where it natively is. Nothing has to move inside a
window, so there is no black block — this is the mode for narrow,
side-anchored games.

The subtlety is phase. In this mode the module restarts its *entire*
engine — write pointer, bank flip, blanking capture, read counter — on
the **shifted** HSync, and exposes that reference as `hs_ref_out`:

```
hs_read_ref = (HPOS_MODE == HPOS_SYNCSHIFT) ? hs_shifted : hs_in;
```

The external read-rate generator (`pxl2_cen`) **must** reset on that same
`hs_ref_out` edge. When all three restart together the enlarged content
stays aligned with the read window. Resetting the read rate on the *raw*
HSync while the engine restarts on the shifted one is precisely the phase
mismatch that made the old upstream scheme drift and desync when
shrinking.

In both modes: positive `hoffset` moves the picture right, negative left.

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
