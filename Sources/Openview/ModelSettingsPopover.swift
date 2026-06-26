import AppKit

/// F8 unified settings popover, shown from the AI panel's model-selector button. Level 1: the DYNAMIC model
/// list (Apple Intelligence always + each configured provider's models, checkmark on the selected one) and
/// the machine-verify switch. Level 2 ("Settings"): API key (입력/변경 → Keychain) and Ollama (local) address +
/// connect. Configuring a provider populates its models in the list (key → Claude; Ollama reachable → local
/// models). Reads/writes `Settings` directly; `onChange` lets the panel refresh its button title.
///
/// HIG: model = a checkmark LIST (selection, name only); verify = an NSSwitch (on/off). Independent controls.
final class ModelSettingsPopover: NSViewController {

    /// Called when the model selection or verify state changes, so the panel can update its button title.
    var onChange: (() -> Void)?

    private let modelListStack = NSStackView()
    private let settingsToggle = NSButton()
    private let settingsSection = NSStackView()
    private let keyStatusLabel = NSTextField(labelWithString: "")
    private let keyButton = NSButton()
    private let ollamaButton = NSButton()              // primary action (Connect / Download / Install / Retry…)
    private let ollamaSecondaryButton = NSButton()     // secondary (e.g. Connect after Install / ollama.com)
    private let ollamaProgress = NSProgressIndicator()  // pull progress + indeterminate "Starting…"
    private let ollamaStatusLabel = NSTextField(labelWithString: "")
    private let panelWidth: CGFloat = 260

    // One-click Ollama: a single state drives the whole section (see OllamaConnector).
    private let ollama = OllamaConnector()
    private var ollamaState: OllamaState = .installedNotRunning
    private enum OllamaAction { case install, detect, startServer, download, connectRunning, disconnect, none }
    private var ollamaPrimaryAction: OllamaAction = .detect
    private var ollamaSecondaryAction: OllamaAction = .none

    private var models: [ModelOption] = [ModelOption.apple]
    private lazy var checkmark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")
    private lazy var blank = NSImage(size: checkmark?.size ?? NSSize(width: 12, height: 12))  // alignment spacer

    override func loadView() {
        let root = NSView()

        let modelHeader = label("Model", size: 11, weight: .semibold, color: .secondaryLabelColor)
        modelListStack.orientation = .vertical
        modelListStack.alignment = .leading
        modelListStack.spacing = 2

        // The machine-verification (NLI) toggle was removed — verification is disabled app-wide and the answer
        // is shown as-is with no source markers (the grounding engine stays in code, just not invoked).
        let sep2 = NSBox(); sep2.boxType = .separator

        settingsToggle.title = "Settings"
        settingsToggle.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        settingsToggle.imagePosition = .imageTrailing
        settingsToggle.isBordered = false
        settingsToggle.target = self; settingsToggle.action = #selector(toggleSettings)

        // API key (cloud) UI removed per request — the cloud/Anthropic path is DEACTIVATED here (keyStatusLabel /
        // keyButton / editKey() / updateKeyStatus() kept in code but no longer built or called). The underlying
        // CloudBackend / CloudQA / fetchAnthropic remain intact, just unreachable from this menu.

        // Ollama (local): ONE-CLICK. A single OllamaState drives the title/status/button(s)/progress (detect →
        // auto-start → in-app pull → connect). Connecting points the existing provider slot at 127.0.0.1.
        let ollamaLabel = label("Local (Ollama)", size: 12, weight: .medium, color: .labelColor)
        ollamaLabel.setContentHuggingPriority(.required, for: .horizontal)
        ollamaStatusLabel.font = .systemFont(ofSize: 11)
        ollamaStatusLabel.setContentHuggingPriority(.required, for: .horizontal)
        let ollamaTop = NSStackView(views: [ollamaLabel, NSView(), ollamaStatusLabel])
        ollamaTop.orientation = .horizontal; ollamaTop.distribution = .fill; ollamaTop.alignment = .centerY
        ollamaButton.bezelStyle = .rounded; ollamaButton.controlSize = .small
        ollamaButton.target = self; ollamaButton.action = #selector(ollamaPrimaryTapped)
        ollamaButton.setContentHuggingPriority(.required, for: .horizontal)
        ollamaSecondaryButton.bezelStyle = .rounded; ollamaSecondaryButton.controlSize = .small
        ollamaSecondaryButton.target = self; ollamaSecondaryButton.action = #selector(ollamaSecondaryTapped)
        ollamaSecondaryButton.setContentHuggingPriority(.required, for: .horizontal)
        ollamaSecondaryButton.isHidden = true
        let ollamaBottom = NSStackView(views: [ollamaButton, ollamaSecondaryButton, NSView()])
        ollamaBottom.orientation = .horizontal; ollamaBottom.distribution = .fill; ollamaBottom.alignment = .centerY; ollamaBottom.spacing = 6
        ollamaProgress.style = .bar
        ollamaProgress.isIndeterminate = false
        ollamaProgress.minValue = 0; ollamaProgress.maxValue = 100
        ollamaProgress.controlSize = .small
        ollamaProgress.isHidden = true
        let ollamaRow = NSStackView(views: [ollamaTop, ollamaBottom, ollamaProgress])
        ollamaRow.orientation = .vertical; ollamaRow.alignment = .leading; ollamaRow.spacing = 4

        settingsSection.orientation = .vertical; settingsSection.alignment = .leading; settingsSection.spacing = 10
        [ollamaRow].forEach { settingsSection.addArrangedSubview($0) }
        settingsSection.isHidden = true
        ollamaTop.widthAnchor.constraint(equalTo: ollamaRow.widthAnchor).isActive = true
        ollamaBottom.widthAnchor.constraint(equalTo: ollamaRow.widthAnchor).isActive = true
        ollamaProgress.widthAnchor.constraint(equalTo: ollamaRow.widthAnchor).isActive = true

        let rows: [NSView] = [modelHeader, modelListStack, sep2, settingsToggle, settingsSection]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            root.widthAnchor.constraint(equalToConstant: panelWidth),
        ])
        for v in rows { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        ollamaRow.widthAnchor.constraint(equalTo: settingsSection.widthAnchor).isActive = true
        self.view = root
        rebuildModelList()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        detectAndRender()                                 // auto-detect Ollama → render the right one-click state
        refreshModels()                                   // pull the live provider list each time it opens
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let h = view.fittingSize.height                   // keep the popover sized to content as it expands
        if abs(preferredContentSize.height - h) > 0.5 { preferredContentSize = NSSize(width: panelWidth, height: h) }
    }

    /// Fetch the live model list and rebuild. Apple is always first, then local Ollama models (if reachable).
    /// The cloud/Anthropic fetch is DEACTIVATED (API-key UI removed) — re-enable by restoring the `cloud` lines.
    private func refreshModels() {
        Task { [weak self] in
            // async let cloud = ModelCatalog.fetchAnthropic()   // DEACTIVATED with the API-key menu removal
            async let local = ModelCatalog.fetchOllama()
            let l = await local
            await MainActor.run {
                guard let self else { return }
                self.models = [ModelOption.apple] + l
                if !self.models.contains(where: { $0.id == Settings.selectedModelId }) {
                    Settings.selectedModelId = ModelOption.appleId
                    Settings.selectedModelName = ModelOption.apple.displayName
                    Settings.selectedModelProvider = ModelProvider.apple.rawValue
                    self.onChange?()
                }
                self.rebuildModelList()                   // the Ollama section status is driven by detect/render
            }
        }
    }

    private func rebuildModelList() {
        modelListStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for m in models {
            let selected = (m.id == Settings.selectedModelId)
            let row = NSButton(title: m.displayName, target: self, action: #selector(pickModel(_:)))
            row.isBordered = false
            row.alignment = .left
            row.imagePosition = .imageLeading
            row.image = selected ? checkmark : blank
            row.contentTintColor = selected ? .controlAccentColor : .labelColor
            row.identifier = NSUserInterfaceItemIdentifier(m.id)
            modelListStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: modelListStack.widthAnchor).isActive = true
        }
    }

    @objc private func pickModel(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let m = models.first(where: { $0.id == id }) else { return }
        Settings.selectedModelId = m.id
        Settings.selectedModelName = m.displayName
        Settings.selectedModelProvider = m.provider.rawValue        // drives routing (apple/anthropic/ollama)
        rebuildModelList()
        onChange?()
    }

    // MARK: – Ollama one-click flow (detect → start → pull → connect), all driven by OllamaState

    @objc private func ollamaPrimaryTapped()   { dispatchOllama(ollamaPrimaryAction) }
    @objc private func ollamaSecondaryTapped() { dispatchOllama(ollamaSecondaryAction) }

    private func dispatchOllama(_ action: OllamaAction) {
        switch action {
        case .install:        if let u = URL(string: "https://ollama.com/download") { NSWorkspace.shared.open(u) }
        case .detect:         detectAndRender()
        case .startServer:    startServerAndConnect()
        case .download:       downloadDefaultModel()
        case .connectRunning: connectRunning()
        case .disconnect:     disconnectOllama()
        case .none:           break
        }
    }

    /// Detect the current Ollama state and render it (the passive path: open settings / Retry / after install).
    private func detectAndRender() {
        Task { [weak self] in
            guard let self else { return }
            let state = await self.ollama.detect()
            await MainActor.run { self.handleDetected(state); self.refreshModels() }
        }
    }

    /// Map a detected state to the UI — if it's already running, point the provider slot at 127.0.0.1 and show
    /// "Connected" when an Ollama model is the active one, else offer a one-click Connect.
    private func handleDetected(_ state: OllamaState) {
        if case .running(let models) = state {
            Settings.ollamaURL = OllamaConnector.base
            if Settings.selectedModelProvider == ModelProvider.ollama.rawValue, models.contains(Settings.selectedModelId) {
                renderOllama(.connected(model: Settings.selectedModelId))
            } else {
                renderOllama(.running(models: models))
            }
        } else {
            renderOllama(state)
        }
    }

    /// .installedNotRunning → start `ollama serve`, then detect again (→ connected / readyNoModel).
    private func startServerAndConnect() {
        renderOllama(.startingServer)
        Task { [weak self] in
            guard let self else { return }
            do { try await self.ollama.startServer() }
            catch { await MainActor.run { self.renderOllama(.error("Couldn't start the Ollama server.")) }; return }
            let state = await self.ollama.detect()
            await MainActor.run { self.handleDetected(state); self.refreshModels() }
        }
    }

    /// .readyNoModel → pull the default model with a progress bar, then connect to it.
    private func downloadDefaultModel() {
        renderOllama(.pullingModel(progress: 0))
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ollama.pullModel(OllamaConnector.defaultModel) { p in
                    Task { @MainActor in self.renderOllama(.pullingModel(progress: p)) }
                }
            } catch {
                await MainActor.run { self.renderOllama(.error("Couldn't download the model.")) }
                return
            }
            let state = await self.ollama.detect()
            await MainActor.run {
                if case .running(let models) = state, let m = models.first {
                    self.activateOllamaModel(m)
                } else { self.handleDetected(state); self.refreshModels() }
            }
        }
    }

    /// .running → select the first model as the active provider and show Connected (friction-0).
    private func connectRunning() {
        guard case .running(let models) = ollamaState, let model = models.first else { return }
        activateOllamaModel(model)
    }

    private func activateOllamaModel(_ model: String) {
        Settings.ollamaURL = OllamaConnector.base
        Settings.selectedModelId = model
        Settings.selectedModelName = model
        Settings.selectedModelProvider = ModelProvider.ollama.rawValue
        onChange?()
        refreshModels()                                   // populate the top model list with the Ollama models
        renderOllama(.connected(model: model))
    }

    /// Disconnect = stop using Ollama as the active model (fall back to Apple). The server is left running.
    private func disconnectOllama() {
        Settings.selectedModelId = ModelOption.appleId
        Settings.selectedModelName = ModelOption.apple.displayName
        Settings.selectedModelProvider = ModelProvider.apple.rawValue
        onChange?()
        rebuildModelList()
        detectAndRender()
    }

    /// The single place that maps OllamaState → the section's title/status/buttons/progress (one action per state).
    private func renderOllama(_ state: OllamaState) {
        ollamaState = state
        ollamaProgress.isHidden = true; ollamaProgress.stopAnimation(nil)
        ollamaSecondaryButton.isHidden = true
        ollamaButton.isHidden = false; ollamaButton.isEnabled = true
        ollamaSecondaryAction = .none
        switch state {
        case .notInstalled:
            setOllamaStatus("Not installed", .secondaryLabelColor)
            ollamaButton.title = "Install Ollama"; ollamaPrimaryAction = .install
            ollamaSecondaryButton.title = "Connect"; ollamaSecondaryAction = .detect; ollamaSecondaryButton.isHidden = false
        case .installedNotRunning:
            setOllamaStatus("Installed · not running", .secondaryLabelColor)
            ollamaButton.title = "Connect"; ollamaPrimaryAction = .startServer
        case .startingServer:
            setOllamaStatus("Starting Ollama…", .secondaryLabelColor)
            ollamaButton.isHidden = true
            ollamaProgress.isHidden = false; ollamaProgress.isIndeterminate = true; ollamaProgress.startAnimation(nil)
        case .readyNoModel:
            setOllamaStatus("No model found", .secondaryLabelColor)
            ollamaButton.title = "Download model"; ollamaPrimaryAction = .download
        case .running(let models):
            setOllamaStatus("Running · \(models.count) model\(models.count == 1 ? "" : "s")", .secondaryLabelColor)
            ollamaButton.title = "Connect"; ollamaPrimaryAction = .connectRunning
        case .pullingModel(let p):
            setOllamaStatus("Downloading \(OllamaConnector.defaultModel)… \(Int(p * 100))%", .secondaryLabelColor)
            ollamaButton.isHidden = true
            ollamaProgress.isHidden = false; ollamaProgress.isIndeterminate = false; ollamaProgress.doubleValue = p * 100
        case .connected(let model):
            setOllamaStatus("Connected · \(model)", .systemGreen)
            ollamaButton.title = "Disconnect"; ollamaPrimaryAction = .disconnect
        case .error(let msg):
            setOllamaStatus(msg, .systemRed)
            ollamaButton.title = "Retry"; ollamaPrimaryAction = .detect
            ollamaSecondaryButton.title = "ollama.com"; ollamaSecondaryAction = .install; ollamaSecondaryButton.isHidden = false
        }
        view.layoutSubtreeIfNeeded()
        viewDidLayout()                                   // resize the popover to the new content height
    }

    private func setOllamaStatus(_ text: String, _ color: NSColor) {
        ollamaStatusLabel.stringValue = text
        ollamaStatusLabel.textColor = color
    }

    @objc private func toggleSettings() {
        settingsSection.isHidden.toggle()
        settingsToggle.image = NSImage(systemSymbolName: settingsSection.isHidden ? "chevron.right" : "chevron.down",
                                       accessibilityDescription: nil)
        view.layoutSubtreeIfNeeded()
        viewDidLayout()                                   // resize the popover to fit the expanded/collapsed section
    }

    // DEACTIVATED — the API-key UI was removed from the menu. These two methods (and keyStatusLabel/keyButton)
    // are kept intact but no longer wired/called, so the cloud-key flow can be re-enabled by restoring the
    // keyRow in loadView. The Keychain/CloudBackend machinery they call is unchanged.

    /// Reuse the F8 2b key prompt (the USER types the key → Keychain). Then refresh status AND the model list:
    /// adding a key makes that provider's models appear; clearing it makes them vanish.
    @objc private func editKey() {
        _ = APIKeyPrompt.promptAndSave(message:
            "To use cloud models, enter an Anthropic API key. The key is stored only in this Mac's Keychain.")
        updateKeyStatus()
        refreshModels()
    }

    private func updateKeyStatus() {
        let has = CloudBackend.hasKey()
        keyStatusLabel.stringValue = has ? "Set" : "Not set"
        keyStatusLabel.textColor = has ? .systemGreen : .secondaryLabelColor
        keyButton.title = has ? "Change" : "Add"
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byWordWrapping; l.maximumNumberOfLines = 0
        return l
    }
}
