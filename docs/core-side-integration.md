# Core-side integration (no `sys_top` edits)

The sys-side module (`crt_adjust_sys.sv`) inserts CRT Adjust inside `sys_top.v`
at the DAC stage — cleanest for HDMI (stays bit-identical), but it edits
framework code that is vendored, clobbered on updates, and off-limits under many
project rules.

This variant (`crt_adjust.sv` + `examples/core_side_snippet.v`) runs the **same
engine entirely from the core's `emu` wrapper**, at the video-output boundary,
with **zero `sys_top` changes**. Validated on Seibu D-Con (GundamSD) and Data
East DEC0 cores (ActFancer, Trio The Punch) on a real 15 kHz CRT.

The key difference from the old H-Size-only module: **H-Position and V-Shift are
now inside the module.** You no longer shift the sync upstream by hand — you
decode the OSD values, generate the read clock-enable, and hand the module the
**native** sync. The module shifts the content and leaves the sync alone.

---

## Why it works from `emu`

The core hands `sys_top` one video stream (`CLK_VIDEO`, `CE_PIXEL`,
`VGA_R/G/B/HS/VS/DE`), which `sys_top` splits two ways:

```
emu ── VGA_* / CE_PIXEL ──┬──▶ HDMI scaler   (normalizes to a fixed target)
                          └──▶ scanlines ─▶ OSD ─▶ vga_out ─▶ analog DAC
```

Two facts make the core-side insertion viable:

1. **The analog chain passes `VGA_DE` through.** `scanlines`, `sync_fix`,
   `osd`, `vga_out` do not regenerate the active window — the DAC's window *is*
   whatever the core outputs. Widen `DE` in the core and the analog window
   widens.
2. **The HDMI scaler normalizes pixel *duration*.** It captures N active pixels
   (counted on `CE_PIXEL`) and fits them to the target size, so a per-pixel
   duration change is invisible on HDMI. The analog DAC holds each pixel for its
   real duration, so the same change *is* the stretch.

Trade-off vs the sys-side module: here HDMI is **not** bit-identical — the
adjusted stream also reaches the scaler. Treat this as an analog/CRT feature;
leave CRT Adjust Off for untouched HDMI.

---

## The three controls, all content-shift

The rule the whole design follows: **change what the viewer sees, leave the
sync the core generates as-is.** That is why the CRT never desyncs.

- **H-Size** — the read clock-enable (`pxl2_cen`) runs at a different rate than
  the write (`pxl_cen`), stepped in quarter cycles. Slower read = wider, faster
  = narrower. `hs_out` is never touched.
- **H-Position** — the module offsets its own read address
  (`rd_addr = rdcnt - hoffset`) and the active-window compare. Content slides;
  sync stays native. **No upstream sync shifting needed** — just pass `hoffset`
  in.
- **V-Shift** — a per-line shift register inside the module delays `VSync` by N
  lines. Vertical tolerance on a CRT is wide, so this never desyncs.

---

## The two things that took a while

### 1. `vb_in` — keeping the OSD visible (vertical)

At the emu boundary the on-screen OSD is composited **downstream** (in
`sys_top`, after the pin). For it to find the vertical frame boundary, `VGA_DE`
must drop during vertical blanking.

`crt_adjust.sv` gates `pass_q` with a latched **true vertical blank** (`vb_in` =
the core's real VBlank, **not** the combined `~DE`): `pass_q` is forced low on
vblank lines, so `VGA_DE` goes low and the OSD stays visible. Crucially it gates
**only** `pass_q`, never the horizontal edges `hb0/hb1`, so it does not re-clamp
the widened window. (There is also a one-line delay on `vb_active`, because the
read side emits the *previous* line — without it the last active line gets
eaten.)

> The "vb_in gotcha" — feeding the *combined* blank into `vb_in`, which
> re-clamps the output window to the original width ("image looks stretched but
> clipped at the old right edge") — was diagnosed by **Andrea Bogazzi
> (@asturur)** while integrating this core-side into a Deco16 / Caveman Ninja
> JTFRAME core. This module keeps the OSD working by passing the true vertical
> blank and gating only `pass_q`.

### 2. `de_osd` — keeping the OSD PUT (horizontal, with H-Position)

The MiSTer OSD centers itself on the **rising edge of `VGA_DE`**. If `VGA_DE`
follows the module's `str_hb` (which moves when H-Position moves the content),
the OSD slides together with the image.

To pin it, the glue builds a separate DE window (`de_osd`) whose **rising is
anchored to the NATIVE active region** and which closes on the stretched
active's end (`str_fall`). Feed `de_osd` to `video_freak`'s `VGA_DE_IN`. The
analog image still moves; only the OSD stays centered on the physical screen.

---

## Reference clock

The read period is stepped in **quarter cycles** of `clk_video`. On a DEC0-style
core (`clk_video` 96 MHz / 6 MHz pixel) one pixel = 16 whole cycles = 64
quarters, so the base period is `64 + hsize` quarters and each H-Size step is one
quarter ≈ **1.5%**. That ratio is **not universal**: `base = clk_video / pixel`
(in whole cycles) × 4 (in quarters). Do NOT hardcode 64 — size it from your own
ratio (or measure it at run time by counting `clk_video` cycles between `ce_pix`
pulses).

---

## vs. the sys-side insertion

| | sys-side (`crt_adjust_sys.sv`) | core-side (`crt_adjust.sv`) |
|---|---|---|
| Placement | DAC stage in `sys_top.v` | core video-output boundary |
| Framework edits | yes (`sys_top.v`) | **none** |
| HDMI | bit-identical | follows the adjust |
| OSD | naturally on the adjusted stream | needs the `vb_in` + `de_osd` glue |
| Best when | you can edit `sys_top` | `sys_top` is off-limits |

See `examples/core_side_snippet.v` for the complete glue. The *shape* transfers
to any MiSTer arcade core; the exact wiring (clock ratio, mixer/overlay names)
is core-specific.
