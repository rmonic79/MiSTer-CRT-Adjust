# V-Size — roadmap anti-desync (chassis arcade AFC stretto)

2026-08-05. Obiettivo: estendere il range utile del retimer V-Size sui
monitor arcade che oggi perdono l'aggancio a ~1-2% di deviazione HSync.
Vincoli fermi: frame rate del gioco intoccabile; niente righe duplicate,
saltate o pattern (filosofia del modulo); il retimer resta il meccanismo.

## Dimostrazioni chiuse (non ritentare)

- A timing nativo l'artifact-free e` impossibile (pigeonhole: scanline =
  griglia rigida di posizioni-tempo; N righe uniche su >N posizioni
  obbligano ripetizioni o righe nere).
- Il contenuto non puo` evadere la griglia sync (il pennello orizzontale
  segue l'oscillatore AFC'd: contenuto fuori grid = tearing, non shift
  verticale).
- Rate diverso solo nel vblank non cambia l'altezza (altezza = tempo delle
  righe attive; per allungarla DEVONO rallentare loro).
- Content-scale nearest-neighbor (v3): provato su HW, artefatti visibili,
  SCARTATO dall'utente.

## Leve, in ordine di resa/rischio

### 1. SLEW LIMITER sul vsize (subito, costo ~zero)
Un AFC ha capture range stretto e HOLD range 2-3x piu` largo. Oggi il
cambio V-Size e` a scalino: il flywheel lo prende in faccia e molla al
limite di CAPTURE. Slew automatico interno al modulo (1 riga ogni N frame,
N~8-15) = si "cammina" l'AFC dentro il suo hold range.
RTL: contatore + registro vsize_eff che insegue vsize a passi di 1.
Attenzione: anche il POWER-ON/attivazione deve partire da 0 e slewarsi.

### 1b. STATO: slew IMPLEMENTATO (2026-08-06) — parametro SLEW_FRAMES=8
Rampa interna vsize_eff: 1 riga ogni 8 frame (~7.5 righe/s), attiva anche
all'accensione. Ogni cambio di altezza "cammina" l'AFC invece di colpirlo.

### 2. CSYNC serration/equalization — RIDIMENSIONATA (verifica codice 2026-08-06)
Il csync del framework NON e` cieco nel vsync: sys_top `module csync` rigenera
gli impulsi H (h_cnt==line_len) durante il vsync -> un riferimento per riga
arriva gia`. La serration 2xH broadcast aggiungerebbe poco su segnale
progressivo. NON implementata: beneficio marginale, non giustifica il rischio.
Il cab aggancia sul csync; il csync MiSTer e` un XOR semplice: durante le
~3 righe di VSync l'AFC e` cieco e va per inerzia — con l'AFC gia` in
tensione (deviazione retimer) e` li` che perde il filo. Lo standard
broadcast prevede: 6 impulsi di equalization a 2xH prima del vsync, 
serration a 2xH dentro il vsync, 6 equalization dopo. Mantengono il
riferimento H DENTRO il vblank. Il retimer rigenera gia` tutto il timing:
puo` emettere la struttura completa (parametrico on/off per sicurezza).
Nota: agisce sul ramo csync (csync_vga in sys_top usa hs/vs post-modulo);
da valutare se generare il csync completo direttamente nel modulo ed
esportarlo, bypassando il csync XOR del framework sul ramo analogico.

### 3. H-HOLD del telaio (operativo, moltiplicatore di 1+2)
A V-Size fisso il retimer emette una frequenza perfettamente stabile: il
caso ideale per ritarare il trimmer H-hold del chassis (progettati per
15.0-16.5 kHz, si faceva a ogni cambio board). Procedura utente:
fissare V-Size, ritoccare H-hold. Documentare nel README del core.

### 4. RESAMPLING OTTICO gamma-corretto (solo se 1+2+3 non bastano — "cab mode")
NON e` il doubling: e` il 2-tap lineare in LUCE LINEARE (decode gamma 2.4,
pesi (1-a)/a sulla coppia di scanline, encode). Fase lineare = zero
shimmer per costruzione; niente bande luminose (quelle nascono dai pesi
applicati in gamma-space); costo: leggera morbidezza SOLO sulle righe di
transizione. Timing nativo puro -> nessun limite AFC. E` come il fascio
CRT sovrappone i fosfori. LUT lineari ~2 M10K. Modalita` OSD separata,
il retimer resta il default qualita`.

### 5. (ricerca) Ibrido: retimer entro il budget AFC + resto in ottico
Split automatico della richiesta: prima i gradi "gratis" in frequenza,
il resto col resampler. Solo dopo che 1-4 sono maturi.

## Ordine di esecuzione proposto
1 (slew) -> 2 (serration) -> test cab -> 3 (procedura H-hold) -> se serve, 4.
