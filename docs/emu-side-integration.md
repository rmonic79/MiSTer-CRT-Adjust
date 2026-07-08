# Emu-side integration (no `sys_top` edits)

The reference integration (`analog_hsize.sv`) inserts the stretch module inside
`sys_top.v`, at the DAC stage. That is the cleanest place and keeps HDMI
bit-identical, but it means editing framework code — which is vendored from the
template, clobbered on updates, and off-limits under many project rules.

This variant (`analog_hsize_emu.sv` + `examples/emu_side_snippet.v`) runs the
same stretch engine **entirely from the core's `emu`**, at the video-output
boundary, with **zero `sys_top` changes**. Validated on Data East DEC0 cores
(ActFancer, Trio The Punch) on a real 15 kHz CRT.

---

## Why it works from `emu`

The core hands `sys_top` one video stream (`CLK_VIDEO`, `CE_PIXEL`,
`VGA_R/G/B/HS/VS/DE`), which `sys_top` splits two ways:

```
emu ── VGA_* / CE_PIXEL ──┬──▶ HDMI scaler   (normalizes to a fixed target)
                          └──▶ scanlines ─▶ OSD ─▶ vga_out ─▶ analog DAC
```

Two facts make the emu-side insertion viable:

1. **The analog chain passes `VGA_DE` through.** `scanlines`, `sync_fix`,
   `osd`, `vga_out` do not regenerate the active window — the DAC's window *is*
   whatever the core outputs. Widen `DE` in the core and the analog window
   widens.
2. **The HDMI scaler normalizes pixel *duration*.** It captures N active pixels
   (counted on `CE_PIXEL`) and fits them to the target size, so a per-pixel
   duration change is invisible on HDMI. The analog DAC holds each pixel for its
   real duration, so the same change *is* the stretch.

Trade-off vs the sys-side module: here HDMI is **not** bit-identical — the
stretched stream also reaches the scaler, and very wide lines can exceed the
HDMI target. Treat this as an analog/CRT feature. If you need HDMI untouched,
use the sys-side module instead.

---

## The three things that took a while

### 1. `vb_in` — keeping the OSD visible (vertical)

At the emu boundary the on-screen OSD is composited **downstream** (in
`sys_top`, after the pin). For it to find the vertical frame boundary, `VGA_DE`
must drop during vertical blanking.

`analog_hsize_emu.sv` gates `pass_q` with a latched **true vertical blank**
(`vb_in` = the core's real VBlank, **not** the combined `~DE`): `pass_q` is
forced low on vblank lines, so `VGA_DE` goes low and the OSD stays visible.
Crucially it gates **only** `pass_q`, never the horizontal edges `hb0/hb1`, so
it does not re-clamp the widened window.

> The "vb_in gotcha" — feeding the *combined* blank into `vb_in`, which
> re-clamps the output window to the original width ("image looks stretched but
> clipped at the old right edge") — was diagnosed by **Andrea Bogazzi
> (@asturur)** while integrating this module core-side into a Deco16 / Caveman
> Ninja JTFRAME core. His fix tied `vb_in` low; this module keeps the OSD
> working by passing the true vertical blank and gating only `pass_q`.

### 2. `de_osd` — keeping the OSD PUT (horizontal, with H-Shift)

The MiSTer OSD centers itself on the **rising edge of `VGA_DE`**. If `VGA_DE`
follows the module's `str_hb` (which is anchored to the *shifted* HSync when
H-Shift is used), the OSD slides together with the image.

To pin it, the glue builds a separate DE window (`de_osd`) whose **rising is
anchored to the NATIVE active region** and which closes on the stretched
active's end (`str_fall`). Feed `de_osd` to `video_freak`'s `VGA_DE_IN`. The
analog image still moves (via `VGA_HS = str_hs`); only the OSD stays centered on
the physical screen. RGB, stretch, `CE_PIXEL` and bypass are untouched.

### 3. H-Shift range — the stretch is left-anchored

The line-buffer read is left-anchored: the stretch grows the image **rightward**
into the front porch. To re-center after stretching you need more LEFT travel
than right. Bias the H-Shift OSD range accordingly, e.g. `0..+48` (left) and
`-15..-1` (right), instead of a symmetric `-32..+31`. The glue re-maps the
6-bit field: `0..48 -> delay +0..+48`, `49..63 -> -15..-1` (= `HTotal-|N|`).

Apply H-Shift/V-Shift **upstream** of the module (shift the HS/VS fed in), so it
composes with the stretch and the read divider resets on the already-shifted HS.

---

## Reference clock

You need a video clock that is an integer multiple `base = clk_video/pixel` of
the pixel rate; each `+1` of the OSD adds one `clk_video` per pixel, i.e. a step
of `1/base`. DEC0 here: 96 MHz / 6 MHz = 16 -> 6.25% steps. On a JTFRAME core
with `clk_video = 48 MHz` and a 6 MHz pixel, `base = 8` -> 12.5% steps — do NOT
hardcode 16; size the divider from your own ratio (or measure it at run time by
counting `clk_video` cycles between `ce_pix` pulses).

---

## vs. the sys-side insertion

| | sys-side (`analog_hsize.sv`) | emu-side (`analog_hsize_emu.sv`) |
|---|---|---|
| Placement | DAC stage in `sys_top.v` | core video-output boundary |
| Framework edits | yes (`sys_top.v`) | **none** |
| HDMI | bit-identical | follows the stretch |
| OSD | naturally on the stretched stream | needs the `vb_in` + `de_osd` glue |
| Best when | you can edit `sys_top` | `sys_top` is off-limits |

See `examples/emu_side_snippet.v` for the complete glue. The *shape* transfers
to any MiSTer arcade core; the exact wiring (clock ratio, mixer/overlay names)
is core-specific.
