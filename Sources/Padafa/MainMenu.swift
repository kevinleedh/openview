import AppKit

/// Builds the app's main menu in code (no nib). Document actions (Open…, Close) use `nil` targets so
/// they travel the responder chain to `NSDocumentController` / the key window — the standard AppKit
/// document wiring. Stage 1 is viewing-only: no markup/edit menus; a Debug menu hosts the foundation
/// self-test. The toolbar, view-options, zoom, and search field arrive in Stage 2.
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenuItem())
        main.addItem(fileMenuItem())
        main.addItem(editMenuItem())
        main.addItem(viewMenuItem())
        main.addItem(windowMenuItem())
        main.addItem(debugMenuItem())
        return main
    }

    private static func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: title)
        build(menu)
        item.submenu = menu
        return item
    }

    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?,
                            _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
                            target: AnyObject? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        if let target { item.target = target }
        menu.addItem(item)
    }

    private static func appMenuItem() -> NSMenuItem {
        submenu("Padafa") { m in
            add(m, "About Padafa", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
            m.addItem(.separator())
            add(m, "Hide Padafa", #selector(NSApplication.hide(_:)), "h")
            add(m, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            add(m, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
            m.addItem(.separator())
            add(m, "Quit Padafa", #selector(NSApplication.terminate(_:)), "q")
        }
    }

    private static func fileMenuItem() -> NSMenuItem {
        submenu("File") { m in
            // openDocument: is implemented by NSDocumentController (in the document app responder chain).
            add(m, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
            let recents = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            let recentsMenu = NSMenu(title: "Open Recent")
            recents.submenu = recentsMenu
            // NSDocumentController populates this menu when its items carry the clear-menu action.
            let clear = NSMenuItem(title: "Clear Menu",
                                   action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                                   keyEquivalent: "")
            recentsMenu.addItem(clear)
            m.addItem(recents)
            m.addItem(.separator())
            // saveDocument: travels the responder chain to the NSDocument (markup edits → write into the PDF).
            add(m, "Save", Selector(("saveDocument:")), "s")
            add(m, "Close", #selector(NSWindow.performClose(_:)), "w")
        }
    }

    private static func editMenuItem() -> NSMenuItem {
        // Standard Edit menu so PDFView text selection (Copy/Select All) and future text inputs work.
        submenu("Edit") { m in
            add(m, "Undo", Selector(("undo:")), "z")
            add(m, "Redo", Selector(("redo:")), "z", [.command, .shift])
            m.addItem(.separator())
            add(m, "Cut", #selector(NSText.cut(_:)), "x")
            add(m, "Copy", #selector(NSText.copy(_:)), "c")
            add(m, "Paste", #selector(NSText.paste(_:)), "v")
            add(m, "Select All", #selector(NSText.selectAll(_:)), "a")
            m.addItem(.separator())
            // ⌘F focuses the toolbar search field (reaches the window controller via the responder chain).
            add(m, "Find", #selector(DocumentWindowController.performFind(_:)), "f")
        }
    }

    private static func viewMenuItem() -> NSMenuItem {
        // CLAUDE.md: view-options = exactly Hide Sidebar / Thumbnails / Table of Contents. Zoom + AI
        // toggle live here too (and on the toolbar). All route to the window controller via the chain.
        submenu("View") { m in
            add(m, "Show Thumbnails", #selector(DocumentWindowController.showThumbnails(_:)), "1")
            add(m, "Show Table of Contents", #selector(DocumentWindowController.showTableOfContents(_:)), "2")
            add(m, "Hide Sidebar", #selector(DocumentWindowController.hideSidebar(_:)), "0", [.command, .control])
            m.addItem(.separator())
            add(m, "Zoom In", #selector(DocumentWindowController.zoomIn(_:)), "+")
            add(m, "Zoom Out", #selector(DocumentWindowController.zoomOut(_:)), "-")
            add(m, "Actual Size", #selector(DocumentWindowController.actualSize(_:)), "0")
            m.addItem(.separator())
            add(m, "Toggle AI Panel", #selector(DocumentWindowController.toggleAIPanel(_:)), "a", [.command, .option])
        }
    }

    private static func windowMenuItem() -> NSMenuItem {
        let item = submenu("Window") { m in
            add(m, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
            add(m, "Zoom", #selector(NSWindow.performZoom(_:)))
        }
        NSApp.windowsMenu = item.submenu     // lets AppKit list/maintain document windows here
        return item
    }

    private static func debugMenuItem() -> NSMenuItem {
        // Foundation probe: confirm Keychain r/w and the on-device NLEmbedding retrieval model
        // (the migration doc's "known re-setup risks"). Removed once the real settings/AI UI lands.
        submenu("Debug") { m in
            add(m, "Run Foundation Self-Test", #selector(AppDelegate.runFoundationSelfTest(_:)),
                "t", [.command, .shift])
            // TEMPORARY F8 Stage-1 probe — replaced by the real AI-panel summarize UI in Stage 3.
            add(m, "Summarize Self-Test (Foundation Models)",
                #selector(AppDelegate.runSummarizeSelfTest(_:)), "s", [.command, .shift])
        }
    }
}
