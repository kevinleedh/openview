import AppKit

/// An NSTextView that reports its laid-out height as its intrinsic content size, so it can live in an
/// Auto Layout stack and wrap/grow with its content (used for question + grounded-answer rendering).
final class SelfSizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else { return super.intrinsicContentSize }
        manager.ensureLayout(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(manager.usedRect(for: container).height))
    }
    override func didChangeText() { super.didChangeText(); invalidateIntrinsicContentSize() }
    override func layout() { super.layout(); invalidateIntrinsicContentSize() }
}

/// A flipped container so the chat thread grows top-to-bottom inside the scroll view.
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// The composer's multi-line input (Apple Messages-style). Reports focus changes so its rounded container can
/// show an accent border while editing. New symbol; behaviour is a plain NSTextView otherwise.
final class ComposerTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder(); if ok { onFocusChange?(true) }; return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder(); if ok { onFocusChange?(false) }; return ok
    }
}

/// iMessage-style bubble for the USER's question: rounded, a subtle tinted fill, padded, right-aligned by its
/// row. The fill is a CGColor (the dynamic-color trap), so it re-resolves on Light↔Dark like PanelBackgroundView.
/// Hugs its content (short questions = compact); the row caps its max width so long ones wrap.
private final class BubbleView: NSView {
    private let textField = NSTextField(wrappingLabelWithString: "")
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 13
        textField.stringValue = text
        textField.font = .systemFont(ofSize: 13)
        textField.textColor = .labelColor
        textField.isSelectable = true
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.setContentHuggingPriority(.defaultHigh, for: .horizontal)         // short → compact bubble
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)  // long → wrap at the cap
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        }
    }
}

/// The panel's opaque backing surface. Its layer `backgroundColor` is a CGColor — a concrete, already
/// resolved color that does NOT re-resolve a dynamic system color on a Light↔Dark switch (the same trap
/// as PDFView's cached `backgroundColor`, see `CanvasPDFView` in PDFViewController.swift). So the controller
/// re-applies it here. `viewDidChangeEffectiveAppearance` is an NSView method (not on NSViewController),
/// hence this thin subclass.
private final class PanelBackgroundView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// The right-hand AI panel — Stage 3 makes it functional and wires it to the ported grounding engine.
/// It renders the spec's core-loop states (S0 analyzing · S1 ready · S2 thinking · S3 grounded/partial/
/// not-found · S5 error). Answers are shown as flowing text with inline, clickable `[p.N]` / `[p.N +k]`
/// citation chips; a chip click calls `onCitationClick` (→ the PDF jumps + highlights, F4). The grounding
/// contract is unchanged — every sentence shown already passed the per-sentence check in the sidecar.
final class AIPanelViewController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate, NSPopoverDelegate {

    /// Wired by DocumentEngine: send a question, and handle a citation chip click.
    var onAsk: ((String) -> Void)?
    var onCitationClick: ((Citation) -> Void)?
    private let notFoundCopy = "Couldn't find supporting evidence in this document."

    private enum State { case analyzing, ready, thinking }
    private var state: State = .analyzing { didSet { applyState() } }

    private let statusBanner = NSTextField(labelWithString: "")
    private let threadStack = NSStackView()
    private let bottomAnchorSpacer = NSView()   // flexible top filler → messages collect at the BOTTOM
    private let scrollView = NSScrollView()
    // Composer = a Messages-style rounded container around a growing multi-line text view + a bottom-aligned
    // Send. (Replaces the old single-line NSTextField — HIG: more text → a text view.)
    private let inputContainer = NSView()
    private let inputScroll = NSScrollView()
    private let inputTextView = ComposerTextView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private var inputHeightConstraint: NSLayoutConstraint!
    private var inputFocused = false
    private let inputMinHeight: CGFloat = 36
    private let inputMaxHeight: CGFloat = 120          // ~5 lines, then the inner scroll takes over
    private let sendButton = NSButton()

    /// Per-turn grounded sentences, kept so a chip click can resolve turnIndex:sentenceIndex → Citation.
    private var turns: [[GroundedSentence]] = []
    private weak var pendingAnswerHost: NSStackView?
    private weak var pendingStreamView: SelfSizingTextView?   // the in-flight streamed (unverified) answer body

    // Chat persistence: completed Q&A turns kept as a serializable model. The document writes them to a sidecar
    // on SAVE (so Don't Save discards them); `onChatChanged` marks the document dirty so the Save/Don't-Save
    // prompt governs the chat. `pendingQuestion`/`pendingStreamRaw` pair the in-flight question with its answer.
    private var savedChat: [ChatTurn] = []
    private var pendingQuestion: String?
    private var pendingStreamRaw = ""
    var onChatChanged: (() -> Void)?
    private var citationPopover: NSPopover?

    // MARK: – Layout

    override func loadView() {
        let root = PanelBackgroundView()
        root.wantsLayer = true                                                 // opaque — answers are a reading surface
        root.onAppearanceChange = { [weak self] in self?.applyPanelBackground() }  // re-resolve on Light↔Dark

        statusBanner.font = .systemFont(ofSize: 11)
        statusBanner.textColor = .secondaryLabelColor
        statusBanner.isHidden = true

        // Chat thread inside a flipped, vertically-scrolling document view.
        threadStack.orientation = .vertical
        threadStack.alignment = .leading
        threadStack.distribution = .fill
        threadStack.spacing = 10
        // Top/bottom breathing room so the first/last message isn't flush against the toolbar / input.
        threadStack.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        threadStack.translatesAutoresizingMaskIntoConstraints = false
        // BOTTOM-ANCHORED chat: a flexible top spacer absorbs any slack so a few messages collect at the
        // BOTTOM (iMessage/ChatGPT-style) instead of sticking to the ceiling; it collapses to 0 once the
        // thread overflows. Stays the first arranged subview — turns/cards are appended after it.
        bottomAnchorSpacer.translatesAutoresizingMaskIntoConstraints = false
        bottomAnchorSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        bottomAnchorSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        threadStack.addArrangedSubview(bottomAnchorSpacer)
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(threadStack)
        scrollView.documentView = doc
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true        // only show the scroller when the thread actually overflows
        // The panel content lives BELOW the toolbar (the stack pins to the safe area), so don't let the scroll
        // view add an automatic top inset for the toolbar — that inset made the documentView taller than the
        // visible area, so an EMPTY thread was already "scrollable" and showed a phantom scroller.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            // Document is AT LEAST the visible height → with the bottom-pinned stack + top spacer, content
            // sits at the bottom when short and scrolls normally once it overflows.
            doc.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            threadStack.topAnchor.constraint(equalTo: doc.topAnchor),
            threadStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            threadStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            threadStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        // Composer — a growing multi-line text view inside a rounded container, Send pinned to its bottom-right.
        inputTextView.isRichText = false
        inputTextView.font = .systemFont(ofSize: NSFont.systemFontSize)
        inputTextView.textColor = .labelColor
        inputTextView.insertionPointColor = .labelColor
        inputTextView.drawsBackground = false
        inputTextView.isVerticallyResizable = true
        inputTextView.isHorizontallyResizable = false
        inputTextView.minSize = NSSize(width: 0, height: 0)
        inputTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        inputTextView.autoresizingMask = [.width]                   // track the scroll/clip width
        inputTextView.textContainerInset = NSSize(width: 2, height: 6)
        inputTextView.textContainer?.lineFragmentPadding = 4
        inputTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        inputTextView.textContainer?.widthTracksTextView = true     // wrap long lines instead of scrolling sideways
        inputTextView.allowsUndo = true
        inputTextView.delegate = self
        inputTextView.onFocusChange = { [weak self] focused in self?.inputFocused = focused; self?.refreshInputBorder() }

        inputScroll.documentView = inputTextView
        inputScroll.borderType = .noBorder
        inputScroll.drawsBackground = false
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.translatesAutoresizingMaskIntoConstraints = false

        inputContainer.wantsLayer = true
        inputContainer.layer?.cornerRadius = 8
        inputContainer.layer?.borderWidth = 1
        inputContainer.translatesAutoresizingMaskIntoConstraints = false
        inputContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inputContainer.addSubview(inputScroll)

        placeholderLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.stringValue = "Ask about this document"
        placeholderLabel.isEditable = false
        placeholderLabel.isSelectable = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        // BEHIND the (transparent) text view, so a click on the placeholder text reaches the text view and
        // focuses it — otherwise the non-interactive label swallows the click and typing never starts.
        inputContainer.addSubview(placeholderLabel, positioned: .below, relativeTo: inputScroll)

        inputHeightConstraint = inputContainer.heightAnchor.constraint(equalToConstant: inputMinHeight)
        NSLayoutConstraint.activate([
            inputHeightConstraint,
            inputScroll.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 8),
            inputScroll.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -8),
            inputScroll.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 2),
            inputScroll.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor, constant: -2),
            placeholderLabel.leadingAnchor.constraint(equalTo: inputScroll.leadingAnchor, constant: 6),
            placeholderLabel.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 8),
        ])

        sendButton.title = "Send"
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"      // default (blue) button; its mask is 0 so it matches PLAIN Return only
        sendButton.target = self
        sendButton.action = #selector(handleSend)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        // Plain Return → Send (the default-button key equivalent); Shift+Return → newline (its modifier doesn't
        // match the button's mask, so it falls through to the text view). Every message is a normal Q&A question —
        // there is no separate summarize path (a "summarize this document" request is just answered like any other).
        let composer = NSStackView(views: [inputContainer, sendButton])
        composer.orientation = .horizontal
        composer.spacing = 8
        composer.alignment = .bottom         // Send tracks the LAST line as the input grows upward

        // Hairline divider above the composer — separates the chat thread from the input area. (The former
        // model-selector chip was removed: generation is a single Apple Intelligence path, so a 1-item
        // dropdown was meaningless.)
        let composerDivider = NSBox()
        composerDivider.boxType = .separator

        let stack = NSStackView(views: [statusBanner, scrollView, composerDivider, composer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            // Pin the content to the SAFE AREA top (below the unified toolbar), not root.top — the toolbar was
            // occluding the panel's top AND the scroll view's auto content-inset for it created a phantom scroller.
            stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // Children fill the panel width.
            composerDivider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            statusBanner.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            composer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        view = root
        applyPanelBackground()                                                 // initial fill under the current appearance
        applyState()
        refreshInputBorder()
        updatePlaceholderVisibility()
        updateInputHeight()
        updateSendEnabled()                                                    // initial: empty → Send disabled
    }

    /// Opaque reading surface behind the answers. The layer `backgroundColor` is a CGColor (a concrete
    /// color), so a plain one-time `= NSColor.controlBackgroundColor.cgColor` sticks at whatever appearance
    /// was active when first assigned and never updates on a live Light↔Dark switch. Resolve the semantic
    /// color under the view's CURRENT effective appearance and re-assign — mirrors `applyCanvasBackground`
    /// in PDFViewController.swift.
    private func applyPanelBackground() {
        guard let layer = view.layer else { return }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
        refreshInputBorder()                                                   // re-resolve the input border CGColor too
    }

    /// The composer container's 1px border — accent while editing, separator otherwise. Re-resolved under the
    /// current appearance because it's a CGColor (the dynamic-color trap, like applyPanelBackground).
    private func refreshInputBorder() {
        guard let layer = inputContainer.layer else { return }
        inputContainer.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = (inputFocused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
    }

    // MARK: – Public API (called by DocumentEngine, main thread)

    func setAnalyzing() { state = .analyzing }
    func setReady()     { state = .ready }

    /// Ingestion failed — keep send disabled and surface the reason (spec S0 "parse failed").
    func setDocumentError(_ message: String) {
        setInputEnabled(true)
        sendButton.isEnabled = false
        setInputPlaceholder("Analysis failed")
        statusBanner.stringValue = message
        statusBanner.textColor = .systemRed
        statusBanner.isHidden = false
    }

    /// Show the question immediately and a "thinking" placeholder; the engine then fills the answer.
    /// Put PDF-selected text into the composer as a quotation and focus it, so the user types their own
    /// question (mirrors Claude's "quote selection" — NOT auto-sent). REPLACES the field with just `"<selection>"`
    /// (no accumulation across clicks); the caret lands right after the quote so the question follows it.
    func insertQuotation(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let quoted = "\"\(cleaned)\" "
        inputTextView.string = quoted
        view.window?.makeFirstResponder(inputTextView)
        inputTextView.setSelectedRange(NSRange(location: (quoted as NSString).length, length: 0))   // caret at end
        // A programmatic edit does NOT auto-fire textDidChange, so force it AND update directly: this is what
        // turns Send blue right after an Ask insertion, and grows the box to fit a long quote.
        inputTextView.didChangeText()
        updatePlaceholderVisibility()
        updateInputHeight()
        updateSendEnabled()
    }

    func beginQuestion(_ question: String) {
        turns.append([])
        pendingQuestion = question
        pendingStreamRaw = ""
        let (container, answerHost) = makeTurnView(question: question)
        threadStack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: threadStack.widthAnchor).isActive = true
        addText(to: answerHost, attributed: styled("Generating…", color: .secondaryLabelColor))
        pendingAnswerHost = answerHost
        state = .thinking
        scrollToBottom(force: true)        // user just sent a question → always snap to it
    }

    func completeAnswer(_ response: AnswerResponse) {
        guard let host = pendingAnswerHost else { state = .ready; return }
        host.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let index = turns.count - 1
        let sentences = response.answer ?? []
        turns[index] = sentences

        if let err = response.error {
            addText(to: host, attributed: styled("Couldn't get an answer: \(err)", color: .systemRed))
        } else if sentences.isEmpty {
            addText(to: host, attributed: styled(notFoundCopy, color: .secondaryLabelColor))   // honest not-found
        } else {
            addText(to: host, attributed: answerAttributedString(sentences, turnIndex: index))
            if response.status == "partial" {
                addText(to: host, attributed: styled("Answered only the parts confirmed in the document.",
                                                     color: .systemOrange, size: 11))
            }
        }
        pendingAnswerHost = nil
        state = .ready
        scrollToBottom()
    }

    func completeError(_ message: String) {
        guard let host = pendingAnswerHost else { state = .ready; return }
        host.arrangedSubviews.forEach { $0.removeFromSuperview() }
        addText(to: host, attributed: styled("Couldn't get an answer: \(message)", color: .systemRed))
        pendingAnswerHost = nil
        pendingStreamView = nil          // an error can interrupt a stream mid-flight; clear the stale view
        state = .ready
        scrollToBottom()
    }

    /// Fill the pending answer with the AI answer text ONLY — no source cue, no verification, no citation chip.
    /// (A "From page N" hint was tried and removed: with off-topic questions answered freely (raw mode), the
    /// retrieval-ranked page is often NOT where the answer came from, so the hint advertised a FALSE source. No
    /// source beats a wrong one.) The NLI grounding engine + verified blue-chip path are preserved in code
    /// (`completeAnswer`/`answerAttributedString`), simply not invoked here.
    func completeUnverifiedAnswer(_ text: String) {
        guard let host = pendingAnswerHost else { state = .ready; return }
        host.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributed = body.isEmpty
            ? styled("(empty response)", color: .labelColor, size: 13)
            : Markdown.attributed(body, size: 13, color: .labelColor)
        addText(to: host, attributed: attributed)
        recordTurn(answer: text)
        pendingAnswerHost = nil
        state = .ready
        scrollToBottom()
    }

    /// Verified mode + off-topic (gate rejected) → honest not-found, same copy as a dropped-all grounded answer.
    func completeNotFound() {
        guard let host = pendingAnswerHost else { state = .ready; return }
        host.arrangedSubviews.forEach { $0.removeFromSuperview() }
        addText(to: host, attributed: styled(notFoundCopy, color: .secondaryLabelColor))
        pendingAnswerHost = nil
        state = .ready
        scrollToBottom()
    }

    /// Progressive streamed answer. `cumulative` is the whole answer so far — replace the "Generating…"
    /// placeholder on the first chunk, then keep updating ONE text view. ``finishStreamedAnswer`` finalizes.
    func streamAnswer(_ cumulative: String) {
        guard let host = pendingAnswerHost else { return }
        pendingStreamRaw = cumulative       // keep the raw markdown so the finished turn persists with formatting
        // Render Markdown on every snapshot so **bold** / *italic* / bullets appear as the answer flows.
        let attributed = cumulative.isEmpty
            ? styled("…", color: .secondaryLabelColor)
            : Markdown.attributed(cumulative, size: 13, color: .labelColor)
        if let tv = pendingStreamView {
            tv.textStorage?.setAttributedString(attributed)
            tv.invalidateIntrinsicContentSize()
        } else {
            host.arrangedSubviews.forEach { $0.removeFromSuperview() }   // drop the placeholder
            let tv = makeTextView(attributed)
            host.addArrangedSubview(tv)
            tv.widthAnchor.constraint(equalTo: host.widthAnchor).isActive = true
            pendingStreamView = tv
        }
        scrollToBottom()
    }

    /// Streaming finished — the body is already on screen; just finalize. No source cue / verification marker.
    func finishStreamedAnswer() {
        guard let host = pendingAnswerHost else { state = .ready; return }
        if pendingStreamView == nil {                                    // empty stream → show something
            addText(to: host, attributed: styled("(empty response)", color: .labelColor, size: 13))
        }
        recordTurn(answer: pendingStreamRaw)
        pendingStreamView = nil
        pendingAnswerHost = nil
        state = .ready
        scrollToBottom()
    }

    /// Non-English question (a blocked non-Latin script) → the app is English-only; show a notice, call no model.
    func completeEnglishOnly() {
        guard let host = pendingAnswerHost else { state = .ready; return }
        host.arrangedSubviews.forEach { $0.removeFromSuperview() }
        addText(to: host, attributed: styled("This app supports English only. Please ask in English.",
                                             color: .secondaryLabelColor))
        pendingAnswerHost = nil
        state = .ready
        scrollToBottom()
    }

    // MARK: – Chat persistence (the document saves these to a sidecar on ⌘S)

    /// Record a completed Q&A turn for persistence. Skips empty answers and clears the pending question (so an
    /// error/notice doesn't also get recorded for the same turn). Marks the document dirty via `onChatChanged`
    /// so the Save / Don't-Save prompt decides whether the chat is kept.
    private func recordTurn(answer: String) {
        guard let q = pendingQuestion else { return }
        pendingQuestion = nil
        let a = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return }
        savedChat.append(ChatTurn(question: q, answer: a))
        onChatChanged?()
    }

    /// The chat to persist (queried by the document on save).
    func currentChat() -> [ChatTurn] { savedChat }

    /// Re-render previously saved turns when the document opens — no engine, no dirty mark (this IS the saved
    /// state). Each turn renders exactly like a live one: a right-side question bubble + the markdown answer.
    func restoreChat(_ turns: [ChatTurn]) {
        guard !turns.isEmpty else { return }
        loadViewIfNeeded()                  // ensure loadView ran (bottomAnchorSpacer is the first arranged view)
        savedChat = turns
        for t in turns {
            self.turns.append([])
            let (container, answerHost) = makeTurnView(question: t.question)
            threadStack.addArrangedSubview(container)
            container.widthAnchor.constraint(equalTo: threadStack.widthAnchor).isActive = true
            let body = t.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            addText(to: answerHost, attributed: body.isEmpty
                ? styled("(empty response)", color: .labelColor, size: 13)
                : Markdown.attributed(body, size: 13, color: .labelColor))
        }
        scrollToBottom(force: true)
    }

    // MARK: – State

    private func applyState() {
        switch state {
        case .analyzing:
            setInputEnabled(true)                        // pre-write allowed…
            sendButton.isEnabled = false                 // …but send is gated until embedding finishes
            setInputPlaceholder("Analyzing document…")
            statusBanner.stringValue = "Analyzing document…  (parsing + embedding)"
            statusBanner.textColor = .secondaryLabelColor
            statusBanner.isHidden = false
        case .ready:
            setInputEnabled(true)
            sendButton.isEnabled = !inputIsEmpty
            setInputPlaceholder("Ask about this document")
            statusBanner.isHidden = true
        case .thinking:
            setInputEnabled(false)                       // lock input while a question is in flight
            sendButton.isEnabled = false
            statusBanner.isHidden = true
        }
    }

    private var inputIsEmpty: Bool {
        currentInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func handleSend() {
        guard state == .ready, !inputIsEmpty else { return }
        let question = currentInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        setInputText("")                                 // clear → re-disables Send (updateSendEnabled inside)
        // English-only: a question with ANY blocked non-Latin script (Hangul/CJK/Kana/Cyrillic/Arabic/…) is
        // NOT sent to a model — show the English-only notice instead (zero LLM calls, like the off-topic block).
        if Self.hasNonLatinScript(question) {
            beginQuestion(question)
            completeEnglishOnly()
            return
        }
        beginQuestion(question)
        onAsk?(question)
    }

    /// True when `text` contains any character from a non-Latin script the (English-only) app blocks. Latin
    /// (incl. accented Latin), digits, punctuation, and emoji pass; Hangul, CJK, Kana, Cyrillic, Arabic,
    /// Hebrew, Thai, Devanagari do not.
    private static func hasNonLatinScript(_ text: String) -> Bool {
        for s in text.unicodeScalars {
            switch s.value {
            case 0xAC00...0xD7A3,      // Hangul syllables
                 0x1100...0x11FF,      // Hangul Jamo
                 0x3130...0x318F,      // Hangul compatibility Jamo
                 0x3040...0x30FF,      // Hiragana + Katakana
                 0x3400...0x4DBF,      // CJK extension A
                 0x4E00...0x9FFF,      // CJK unified ideographs (Hanzi / Kanji)
                 0x0400...0x04FF,      // Cyrillic
                 0x0600...0x06FF,      // Arabic
                 0x0590...0x05FF,      // Hebrew
                 0x0E00...0x0E7F,      // Thai
                 0x0900...0x097F:      // Devanagari
                return true
            default: continue
            }
        }
        return false
    }

    // User typing in the composer: refresh Send + grow the box. (Programmatic edits call these directly.)
    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === inputTextView else { return }
        updateSendEnabled()
        updateInputHeight()
        updatePlaceholderVisibility()
    }

    // Messages-style send: Return sends, Shift+Return inserts a newline. Routing through the SAME handleSend
    // keeps the existing send path (beginQuestion / onAsk) unchanged.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === inputTextView, commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }   // Shift+Return → newline
        handleSend()
        return true
    }

    // MARK: – Composer input helpers (single source of truth for text / enabled / placeholder / Send / height)

    private var currentInputText: String { inputTextView.string }

    /// (A) The one Send-enable rule: any non-whitespace character → enabled, but only while truly sendable
    /// (document ready). Called on every edit (user OR programmatic) and on clear.
    private func updateSendEnabled() {
        if state == .ready { sendButton.isEnabled = !inputIsEmpty }
    }

    private func setInputText(_ s: String) {
        inputTextView.string = s
        inputTextView.didChangeText()
        updatePlaceholderVisibility()
        updateInputHeight()
        updateSendEnabled()
    }

    private func setInputEnabled(_ enabled: Bool) {
        inputTextView.isEditable = enabled
        inputContainer.alphaValue = enabled ? 1.0 : 0.55      // dim when locked (thinking / summarizing)
    }

    private func setInputPlaceholder(_ s: String) {
        placeholderLabel.stringValue = s
        updatePlaceholderVisibility()
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !inputTextView.string.isEmpty
    }

    /// (B) Grow the container to fit the laid-out text between min and max; past max the inner scroll takes over.
    private func updateInputHeight() {
        guard let lm = inputTextView.layoutManager, let tc = inputTextView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height + inputTextView.textContainerInset.height * 2
        let newH = min(max(used + 4, inputMinHeight), inputMaxHeight)         // +4 = container's 2pt top/bottom inset
        if abs(inputHeightConstraint.constant - newH) > 0.5 { inputHeightConstraint.constant = newH }
    }

    // MARK: – Rendering

    private func makeTurnView(question: String) -> (container: NSStackView, answerHost: NSStackView) {
        // Question → RIGHT-aligned bubble (iMessage-style). A leading spacer pushes it right; a ≤78% width cap
        // wraps long questions while short ones stay compact.
        let bubble = BubbleView(text: question)
        bubble.setContentHuggingPriority(.defaultHigh, for: .horizontal)            // hug content
        let qSpacer = NSView()
        qSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)            // expands → pushes bubble right
        let questionRow = NSStackView(views: [qSpacer, bubble])
        questionRow.orientation = .horizontal
        questionRow.distribution = .fill
        questionRow.alignment = .top

        // Answer → LEFT-aligned, no bubble (unfurled — answers can be long).
        let answerHost = NSStackView()
        answerHost.orientation = .vertical
        answerHost.alignment = .leading
        answerHost.spacing = 4

        let container = NSStackView(views: [questionRow, answerHost])
        container.orientation = .vertical
        container.alignment = .leading
        container.distribution = .fill
        container.spacing = 8
        questionRow.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        answerHost.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        bubble.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, multiplier: 0.78).isActive = true
        return (container, answerHost)
    }

    private func addText(to host: NSStackView, attributed: NSAttributedString) {
        let tv = makeTextView(attributed)
        host.addArrangedSubview(tv)
        tv.widthAnchor.constraint(equalTo: host.widthAnchor).isActive = true
    }

    private func makeTextView(_ attributed: NSAttributedString) -> SelfSizingTextView {
        let tv = SelfSizingTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isHorizontallyResizable = false
        tv.delegate = self
        tv.linkTextAttributes = [.foregroundColor: NSColor.systemBlue, .cursor: NSCursor.pointingHand]
        tv.textStorage?.setAttributedString(attributed)
        return tv
    }

    /// Answer text with inline citation chips at sentence ends (`[p.N]`, or `[p.N +k]` when a sentence
    /// has citations on several pages). The chip is a link encoding turnIndex:sentenceIndex.
    private func answerAttributedString(_ sentences: [GroundedSentence], turnIndex: Int) -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ]
        let out = NSMutableAttributedString()
        for (si, s) in sentences.enumerated() {
            if out.length > 0 { out.append(NSAttributedString(string: " ", attributes: body)) }
            out.append(NSAttributedString(string: s.sentence, attributes: body))
            // D3 / Principle 3: a citation without valid coordinates is NEVER shown as a chip — only
            // coordinate-bearing citations get a clickable chip, so every chip is guaranteed jumpable.
            let coordinated = s.citations.filter { $0.bbox.count == 4 }
            if let first = coordinated.first {
                let extra = coordinated.count - 1
                let label = extra > 0 ? " [p.\(first.page) +\(extra)]" : " [p.\(first.page)]"
                out.append(NSAttributedString(string: label, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.systemBlue,
                    .link: URL(string: "openview-cite:\(turnIndex):\(si)") as Any,
                ]))
            }
        }
        return out
    }

    private func styled(_ text: String, color: NSColor, size: CGFloat = 13,
                        weight: NSFont.Weight = .regular) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ])
    }

    private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font; l.textColor = color
        l.lineBreakMode = .byWordWrapping; l.maximumNumberOfLines = 0
        return l
    }

    /// Keep the newest message in view. By DEFAULT this respects a user who has scrolled up to read history —
    /// it only follows when the view is already near the bottom. Pass `force: true` when the user just acted
    /// (sent a question) and should be snapped down to the newest message regardless.
    private func scrollToBottom(force: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let doc = self.scrollView.documentView else { return }
            let clip = self.scrollView.contentView
            let distanceFromBottom = doc.bounds.height - (clip.bounds.origin.y + clip.bounds.height)
            guard force || distanceFromBottom <= 48 else { return }   // scrolled up to read → don't yank down
            doc.scrollToVisible(NSRect(x: 0, y: max(0, doc.bounds.maxY - 1), width: 1, height: 1))
        }
    }

    // MARK: – Citation chip clicks (F4)

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let raw = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        guard raw.hasPrefix("openview-cite:") else { return false }
        let parts = raw.dropFirst("openview-cite:".count).split(separator: ":")
        guard parts.count == 2, let ti = Int(parts[0]), let si = Int(parts[1]),
              turns.indices.contains(ti), turns[ti].indices.contains(si) else { return false }
        // Same D3 filter as the chip: only coordinate-bearing citations are selectable.
        let coordinated = turns[ti][si].citations.filter { $0.bbox.count == 4 }
        guard !coordinated.isEmpty else { return false }

        if coordinated.count == 1 {
            onCitationClick?(coordinated[0])     // single source — immediate jump (unchanged, verified path)
        } else {
            // Multi-source [p.N +k] — don't jump blindly; let the user pick which source to verify.
            showCitationPopover(coordinated, anchorCharIndex: charIndex, in: textView)
        }
        return true
    }

    private func showCitationPopover(_ citations: [Citation], anchorCharIndex charIndex: Int, in textView: NSTextView) {
        citationPopover?.close()
        let controller = CitationPopoverController(citations: citations) { [weak self] citation in
            self?.onCitationClick?(citation)     // → PDFViewController.jumpHighlight
        }
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient            // dismiss on outside click (HIG)
        popover.delegate = self                  // → popoverDidClose nils the strong ref (no leak, L1)
        citationPopover = popover
        popover.show(relativeTo: chipRect(in: textView, charIndex: charIndex), of: textView, preferredEdge: .maxY)
    }

    // L1 fix: a `.transient` popover only HIDES on dismiss; AppKit keeps its contentViewController (→ the
    // citations array + onJump closure) alive while our strong `citationPopover` ref persists. Nil it once
    // the popover actually closes so the controller deallocates instead of lingering until the next chip.
    func popoverDidClose(_ notification: Notification) {
        citationPopover = nil
    }

    /// The on-screen rect of the chip's link run, so the popover's arrow points at the chip.
    private func chipRect(in textView: NSTextView, charIndex: Int) -> NSRect {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              let storage = textView.textStorage, charIndex < storage.length else {
            return NSRect(x: 0, y: 0, width: 1, height: 1)
        }
        var linkRange = NSRange(location: charIndex, length: 1)
        _ = storage.attribute(.link, at: charIndex, longestEffectiveRange: &linkRange,
                              in: NSRange(location: 0, length: storage.length))
        let glyphRange = lm.glyphRange(forCharacterRange: linkRange, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        let origin = textView.textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }
}
