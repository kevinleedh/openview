# Openview

A native macOS PDF viewer with on-device AI. Read PDFs with Preview-grade
scrolling, and ask questions that are answered **from the document, entirely on
your Mac**.

## Download

Get the latest signed & notarized build from the
[**Releases**](../../releases) page — open the `.dmg` and drag **Openview** into
Applications.

## Features

- **Native PDF viewing** — PDFKit-backed continuous scroll, find (`⌘F`), zoom,
  and text markup (highlight / underline / strikethrough) saved back into the PDF
  so other viewers see it too.
- **On-device AI Q&A** — ask about the open document and get answers drawn from
  its text. Retrieval uses a bundled **e5-small-v2 Core ML** embedder
  (+ BM25 + RRF) to find the relevant passages; answering uses Apple's
  **on-device foundation model**. No document content leaves your Mac.
- **Persistent chat** — the AI conversation is kept with the document and
  restored when you reopen it (only when you save).

## Requirements

- **Viewer:** macOS 14 or later — PDF reading, text markup, and search.
- **On-device AI Q&A:** an Apple-silicon Mac running **macOS 26 (Tahoe) or later**
  with Apple Intelligence enabled (the answering uses Apple's `FoundationModels`,
  which only exists on macOS 26+). On earlier macOS the AI is unavailable and
  Openview runs as a plain PDF viewer — no crash, the AI calls are version-gated.

## Build from source

There's no Xcode project — Openview is a Swift Package built with the Command
Line Tools.

```bash
git clone https://github.com/kevinleedh/openview.git
cd openview
./make_app.sh        # swift build -c release → assemble Openview.app → ad-hoc sign → install to ~/Applications
```

Then launch it from `~/Applications`, or `open ~/Applications/Openview.app`.

### Packaging

- `tools/make_dmg.sh` — build a drag-to-Applications `.dmg` (ad-hoc signed; for
  local testing / sharing).
- `build_and_notarize.sh` — the release pipeline: Developer ID signing + hardened
  runtime → notarize → staple → a notarized `.dmg`. Requires your own *Developer
  ID Application* certificate and notary credentials (see the script header).

## Project layout

```
Package.swift           SwiftPM manifest (OpenviewKit lib + Openview app + coordcli)
Info.plist              app metadata; binds the PDF document type to OpenviewDocument
Sources/Openview/       the AppKit app — NSDocument, PDF view, AI panel, retrieval + on-device QA
Sources/OpenviewKit/    UI-independent engine helpers
tools/                  bundled Core ML model + tokenizer, and the icon / dmg build scripts
make_app.sh             dev build → ~/Applications
build_and_notarize.sh   release: Developer ID sign + notarize + dmg
```

## License

Released under the [MIT License](LICENSE).
