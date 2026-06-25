# Padafa — Mac PDF AI viewer (AppKit rebuild)

Pure-AppKit, `NSDocument`-based rewrite of Padafa (migrating off SwiftUI). The product, principles,
and feature set are unchanged — only the UI framework. See the spec docs in [`files/`](files/):
`CLAUDE.md` (constitution), `prd_padafa_dev.md` (features), `spec_core_loop_ux.md` (core loop),
`migration_appkit.md` (this rewrite's plan), `open_decisions.md` (decisions).

## Status — Stage 1 (minimal NSDocument + PDFView shell)

Stage 1's only goal is the **BLOCKING native-scroll gate**: open/render/scroll a PDF with `PDFView`
hosted *directly* in an `NSViewController` (no `NSViewRepresentable`, no SwiftUI in the path), so
trackpad momentum can be verified as Preview-grade in a pure-AppKit host.

Foundation checks (the migration doc's "known re-setup risks") — all verified ✅:

| Check | Result |
|---|---|
| `swift build -c release` (Command Line Tools only, no Xcode) | ✅ builds |
| `make_app.sh` → `.app` bundle + ad-hoc `codesign` + `lsregister` | ✅ signed, registered (claims `com.adobe.pdf`) |
| App launch + PDF load | ✅ no crash |
| Keychain **survives relaunch** of the same signed binary (read-first probe) | ✅ PASS (seeded → survived) |
| Python sidecar launch + **`warmup` loads the real ML stack** (docling/MLX/torch) → `ok:true` | ✅ PASS (~20s) |

## Layout

```
Package.swift            SwiftPM (macOS 14 floor); PadafaKit lib + Padafa app target
Info.plist               CFBundleDocumentTypes → PDF, bound to PadafaDocument
make_app.sh              swift build → assemble Padafa.app → ad-hoc sign → lsregister
Sources/
  PadafaKit/             ported as-is (UI-independent engine logic)
    CoordinateAdapter.swift   Docling/PyMuPDF bbox → PDFKit page-point (the y-flip; IoU 0.931)
    SidecarClient.swift       Swift ↔ Python sidecar, JSON-lines over stdin/stdout
  Padafa/                the AppKit app shell (Stage 1)
    main.swift                NSApplication bootstrap (programmatic, no nib)
    MainMenu.swift            File ▸ Open… etc., wired through the responder chain
    AppDelegate.swift         open flow + Preview-style empty-launch panel
    PadafaDocument.swift      NSDocument wrapping PDFDocument (read-only viewer)
    DocumentWindowController.swift   window + frame autosave (single doc, no tabs)
    PDFViewController.swift   hosts PDFView directly (.singlePageContinuous, autoScales)
    FoundationCheck.swift     Stage-1 Keychain + sidecar probes
sidecar/                 ported Python sidecar (parse → window → embed → retrieve → ground)
benchmark/               ported harnesses (coord_accuracy.py, memory_fit.py)
PDF Samples/             test PDFs
```

## Build & run

```bash
./make_app.sh                                  # build + bundle + sign + register (release)
open Padafa.app --args "$PWD/PDF Samples/1706.03762v7.pdf"   # open a specific PDF
open Padafa.app                                # launch → Preview-style open panel
```

- `⌘O` opens a PDF; Finder **Open With → Padafa** works (Launch Services registered). Closing the
  PDF (`⌘W`) then clicking the Dock icon re-presents the open panel (never a dead-end blank state).
- **Debug ▸ Run Foundation Self-Test** (`⌘⇧T`) runs the Keychain persistence check and the sidecar
  probe. The sidecar probe sends a real `warmup` (loads the ML models, ~20–30s) so a PASS proves the
  whole stack runs — not just that the process launches.
- Sidecar interpreter defaults to the miniforge base Python; override with `PADAFA_PYTHON=/path/to/python3`.

## The BLOCKING verification (do this on the trackpad)

Per `files/migration_appkit.md` Stage 1 — open a PDF and scroll with the **trackpad**:

> Does the PDF scroll with true native, Preview-grade momentum **and mid-glide chain-in** (flick,
> then flick again before it stops — the second flick should add to the glide), in this pure-AppKit host?

- **YES** → the rewrite is justified; proceed to Stage 2 (split layout + `NSToolbar`).
- **NO / same as the old build** → **STOP**. The scroll issue was never the SwiftUI host, so rewriting
  the rest won't fix it. Re-evaluate before spending more.

## Progress

- **Stage 1** ✅ — minimal NSDocument + PDFView-direct shell; native scroll confirmed.
- **Stage 2** ✅ — `NSSplitViewController` (center PDF | right AI, on-demand left sidebar) + `NSToolbar`
  (view-options / page / zoom / `⌘F` find / ✦ AI toggle); in-document search.
- **Stage 3** ✅ — AI panel reconnected to the ported grounding engine (`SidecarBridge` + `DocumentEngine`):
  ingest on open → ask → grounded answer with inline `[p.N]` citation chips → click → jump + highlight (F4);
  honest not-found. **Local MLX backend (no API key).** First answer is slow (~30–40s, cold model load),
  then ~4s; the per-document index is cached in `~/Library/Application Support/Padafa/index/`.

### Not yet built (later stages, per the spec)
Stage 4 — model selector + settings (7 providers, dynamic `/models`, Keychain) to supply the cloud
BYO-key backend (the `answer(backend:)` slot is ready). Then: F7 area selection, multi-turn chat UI,
out-of-document answers, F6 local-model download (all Planned).
