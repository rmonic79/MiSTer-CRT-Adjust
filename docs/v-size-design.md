# V-Size — vertical stretch/shrink at 15 kHz (design)

> **DECISIONE FINALE (2026-08-05, dopo entrambi i test HW):** il RETIMER e` il
> meccanismo definitivo. La variante "content-scale a timing nativo" (v3,
> dup/skip righe) e` stata provata e SCARTATA: gli artefatti di duplicazione
> sono visibili e violano la filosofia del modulo. Dimostrazione che a timing
> nativo non si puo` fare meglio (pigeonhole): le scanline sono una griglia
> rigida di posizioni = tempo dal VSync; N righe uniche su piu` di N posizioni
> obbligano ripetizioni o buchi neri. L'altezza pulita costa frequenza, punto.
> Limite AFC dei chassis arcade (~1-2%): si estende REGOLANDO L'H-HOLD del
> monitor — i chassis sono progettati per essere ritarati su 15.0-16.5 kHz e
> il retimer a V-Size fisso emette una frequenza perfettamente stabile, il
> caso ideale per il trimmer. Procedura: fissare V-Size, ritoccare H-hold.

Status: **IMPLEMENTED** (2026-08-05) as `rtl/crt_vsize.sv` — statically
reviewed, NOT yet built/HW-tested. **General module feature**, core-agnostic;
NeoGeo_MiSTer_Streamer is the first testbed (sys-side; the module is equally
instantiable core-side).

Implementation decisions (v1):
- **Separate stage, placed BEFORE crt_adjust(_sys)**: the retimer receives
  the uniform native pixel CE and re-emits the same pixel structure;
  crt_adjust composes per-line downstream, agnostic to the line period.
  Chain: native -> crt_vsize -> crt_adjust -> OSD.
- **Native pixel period inside the retimed line, blanking absorbs** the
  period change (uniform pixels, zero fractional artifacts); width change is
  compensated with H-Size.
- **Step = 2 lines = ~0.76%**, range ±14 lines (~±5.3%), RING_LINES=32.
  (v1 shipped 1 line/±7: HW test on CRT confirmed the mechanism works but
  the effect was too subtle — the CRT locked fine, so both step and range
  were doubled. 4-bit OSD field, "+" = taller via negate+shift at decode.)
- One frame-rate division per frame (22-cycle sequential divider in vblank)
  places the DE window when the shortened line cannot fit the native offset.
- Known compose limit: crt_adjust's V-Shift negative taps assume the native
  VTOTAL; with V-Size active the tap is off by |vsize| lines. Cosmetic.

## Design principle: SELF-MEASURING, no per-core parameters

The retimer measures its own input at runtime:

- **frame_cycles**: clk cycles between two native VSync rises
- **lines_native**: HSync count per frame

From these it derives everything (`line_period_out = frame_cycles /
(lines_native + vsize)`). No VTOTAL/HTOTAL parameters, no per-core tuning:
drop-in for any core, and it follows video-mode switches by itself (e.g.
NeoGeo NTSC 264 <-> PAL 312). Same approach as the auto-measured base
Andrea Bogazzi added to the legacy module — proven lineage.

## The physical constraint

The frame rate cannot change (the game dictates it, e.g. NeoGeo ~59.19 Hz).
On a CRT the picture height is the fraction of the FRAME PERIOD occupied by
the active lines: the vertical sweep spans the whole frame period, always.

So the ONLY lever for vertical size is: **change the total line count per
frame, scaling the line period inversely** so that
`lines_out x line_period_out = frame_period` stays exact.
VSync stays at the native frame rate; HSync moves AROUND the native 15.7 kHz.

NeoGeo REAL numbers (verified in core + MAME: 6 MHz pixel clock, 384 px/line
= 64 us/line EXACT, 264 lines NTSC, frame 16.896 ms = 59.186 Hz; at
clk_vid 48 MHz: frame = 811,008 cycles, native line = 3072 cycles exact):

| V-Size | lines_out | line rate | active height |
|---|---|---|---|
| -12 (taller) | 252 | **14.92 kHz** | +4.8 % |
| -8 | 256 | 15.15 kHz | +3.1 % |
| 0 | 264 | **15.625 kHz** (native — NOT 15.734: NeoGeo line is 64 us) | — |
| +8 (shorter) | 272 | 16.10 kHz | -2.9 % |
| +12 | 276 | 16.34 kHz | -4.3 % |

Standard 15 kHz CRTs lock ~15.0-16.5 kHz. Starting from 15.625 kHz the
TALLER side hits 15 kHz first: **safe symmetric range is +/-8..10 lines**
(15.15-16.10 kHz); +/-12 is the "try it, back off if it rolls" zone,
exposed but not default. Ring cost at +/-8..10: ~10-12 lines => ~10-12 M10K.
811,008 / 252 = 3218.3 cycles: NOT integer => the line generator must be
accumulator-based (same quarter/fraction trick as the H read rate) so the
frame period stays exact and the VSync lock never slips.

## Mechanism — a retimer, same philosophy as H-Size one level up

1. **Own output timing generator**: `HTOTAL_out = frame_cycles / lines_out`
   in clk cycles; HSync/VSync regenerated; phase-locked to the NATIVE VSync
   rise once per frame => no drift, deterministic phase.
2. **Elastic multi-line ring buffer** (~16-32 lines instead of the current
   single ping-pong line): written at the native line rate, read at the new
   one. Every source line maps to EXACTLY one output line — 1:1, no
   interpolation, no repeated or dropped lines => byte-exact, zero
   shimmering, the vertical twin of the H-Size property.
3. Skew handling: taller (fewer lines_out) => read falls behind write up to
   ~N lines through the frame, absorbed by the ring; shorter (more
   lines_out) => read runs ahead, so reading starts N lines late (fixed
   latency). Max added latency ~1.5 ms, analog branch only.
4. **Pixel read rate scales with the line period** => width is preserved
   automatically; the existing H-Size composes on top as an independent
   width control. H-Pos/V-Shift compose unchanged.

## Cost

~1 M10K per ring line (320 px x 24 bit ~= 7.7 kbit/line): the ring must hold
the max write/read skew ~= |vsize| lines + margin, so cost scales linearly
with the exposed range. Default +/-8..10 range => 12-14 line ring => ~10-14
M10K. Extended ring (32 lines, ~25 M10K) only if a wider range is exposed.
NeoGeo_Streamer after the CRT Adjust build: 421/553 M10K used => 132 free.

## Why sys-side makes this free for HDMI

The HDMI scaler taps the slot-line stream ABOVE the insertion point (see the
field note in README), so even a full output retiming leaves HDMI
bit-identical. Core-side this feature would be impossible without wrecking
the HDMI picture — the sys-side insertion is what unlocks it.

## Open points

- YC/CVBS at non-standard line rates: the per-line colorburst phase changes;
  RGB is unaffected in principle. To verify on HW per-TV.
- OSD downstream composes on the retimed stream (works: it uses whatever
  DE/syncs it receives), but the OSD vertical anchor at the extremes is to
  verify on HW.
- Rounding: frame_cycles/lines_out is not integer; accumulator-based HTOTAL
  (same quarter-cycle trick as the H read rate) keeps the frame period exact
  over the frame so the VSync lock never slips.
