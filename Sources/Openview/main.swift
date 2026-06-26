import AppKit

// Programmatic AppKit entry point (no storyboard/nib — SwiftPM executable).
// Stage 1 of the AppKit/NSDocument rewrite: a minimal document app whose ONLY job is to open,
// render, and scroll a PDF so native trackpad momentum can be verified in a pure-AppKit host
// (files/migration_appkit.md, Stage 1 — the BLOCKING gate for the whole rewrite).

// Ignore SIGPIPE process-wide: a socket whose peer closed (e.g. an interrupted Ollama/cloud HTTP stream)
// would otherwise deliver SIGPIPE and kill the whole app. With it ignored, the write surfaces as a
// recoverable error that URLSession reports normally. (Kept as hygiene; the Python sidecar that first
// motivated this is gone.)
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared

// `delegate` is held by this top-level constant for the program's lifetime (NSApplication.delegate
// is a weak reference — a local would deallocate immediately).
let delegate = AppDelegate()
app.delegate = delegate

app.setActivationPolicy(.regular)            // a normal Dock app (menus, window, focus)
app.mainMenu = MainMenu.make()               // File ▸ Open… etc. wired through the responder chain
app.run()
