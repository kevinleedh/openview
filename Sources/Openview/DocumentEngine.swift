import AppKit
import CryptoKit
import Foundation
import PDFKit

/// Per-document orchestration of the grounding engine (the "document owns the pipeline kickoff",
/// CLAUDE.md F1). On open it ingests the PDF (parse → window → embed → store) in the background while
/// the viewer stays readable; on ask it runs the grounded answer. All sidecar work is off the main
/// thread; UI updates hop back to main. Stage 3 uses the local MLX backend (no key); the cloud BYO-key
/// backend arrives with the Stage 4 model selector.
final class DocumentEngine {

    private weak var pdf: PDFViewController?
    private weak var ai: AIPanelViewController?
    private let work = DispatchQueue(label: "com.openview.engine", qos: .userInitiated)

    private var pdfURL: URL?
    private var dbPath = ""

    init(pdf: PDFViewController, ai: AIPanelViewController) {
        self.pdf = pdf
        self.ai = ai
        ai.onAsk = { [weak self] question in self?.ask(question) }
        ai.onCitationClick = { [weak self] citation in self?.pdf?.jumpHighlight(citation) }
    }

    /// Kick off ingestion. Reuses an existing index instantly; otherwise embeds in the background while
    /// the AI input stays writable (send gated until embedding completes) — spec S0.
    func start(pdfURL: URL) {
        self.pdfURL = pdfURL
        dbPath = Self.indexPath(for: pdfURL)

        let pdfReachable = (try? pdfURL.checkResourceIsReachable()) ?? false
        let indexExists = FileManager.default.fileExists(atPath: dbPath)

        // Fast path only when BOTH the source PDF and its index are reachable. The index lives on the
        // internal disk but the PDF may be on a removable drive — gating on the index alone would mark
        // the doc Ready and then hand back citations that can't be displayed once the drive is gone.
        if indexExists && pdfReachable {
            ai?.setReady()
            prewarm()                       // index reused → e5 isn't loaded yet; warm it (+ Apple) for a fast first Q
            return
        }
        if !pdfReachable {
            ai?.setDocumentError("Can't access the source PDF. Check the drive connection and reopen the document.")
            return
        }
        ai?.setAnalyzing()
        let url = pdfURL                 // non-optional parameter — captured for the off-main ingest
        work.async { [weak self] in
            guard let self else { return }
            do {
                // Extract text from a FRESH, data-backed PDFDocument — NOT the on-screen PDFView's document
                // (PDFKit is main-thread-affine; reusing it off-main deadlocks). Data-backed (no mmap) is also
                // safe on a removable volume. PDFKit extraction + NLEmbedding indexing all run off-main here.
                guard let data = try? Data(contentsOf: url), let doc = PDFDocument(data: data) else {
                    throw NSError(domain: "Openview.Engine", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "Couldn't read the PDF for analysis. Check the drive connection and reopen the document."])
                }
                try DocumentIndex.build(document: doc, indexPath: self.dbPath, provider: Embeddings.current)
                DispatchQueue.main.async { self.ai?.setReady(); self.prewarm() }
            } catch {
                DispatchQueue.main.async {
                    self.ai?.setDocumentError("Couldn't analyze this document: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Speed: warm the models BEFORE the first question, removing the cold start. Best-effort + off the main
    /// thread; failures are ignored (the first question just pays the cost). Light — NLEmbedding is small and
    /// the heavy generators (Apple/cloud/Ollama) load their own assets.
    private func prewarm() {
        // Apple model — only when it will actually be the generator (Apple selected, or an Anthropic model
        // selected with no key → Apple fallback). Skipped for cloud/Ollama so we don't load it needlessly.
        // Dispatched OFF-MAIN (the model load must not block the UI); OnDeviceQA.prewarm is idempotent per
        // document, so a duplicate open won't re-warm. dbPath is captured on main (avoids an off-main read).
        let provider = ModelProvider(rawValue: Settings.selectedModelProvider) ?? .apple
        if provider == .apple || (provider == .anthropic && !CloudBackend.hasKey()) {
            let key = dbPath
            work.async { if #available(macOS 26, *) { OnDeviceQA.prewarm(documentKey: key) } }
        }
        // Retrieval embedder (e5 Core ML or NLEmbedding fallback — used by EVERY path). Idempotent.
        work.async { Embeddings.prewarm() }
    }

    // MARK: – Q&A routing (AI-answer-only; pure Swift, no Python sidecar).
    //
    // Flow (RAW — no relevance rejection): Swift-native retrieval (DocumentIndex: e5/NLEmbedding cosine ⊕ BM25,
    // ranking only) → the selected MODEL ALWAYS generates from the retrieved chunks (Apple on-device / cloud
    // Claude / Ollama, all Swift-side). Every question goes to the LLM; there is no off-topic gate and no "not in
    // this document" short-circuit. The answer is shown as-is — NLI verification + element-bbox citations were
    // Python-only and have been removed with the sidecar.

    private func ask(_ question: String) {
        let db = dbPath
        // Re-check reachability right before the round-trip: a drive ejected after open would otherwise
        // either wedge the engine or return citations that point at an unreadable PDF.
        let pdfReachable = pdfURL.map { (try? $0.checkResourceIsReachable()) ?? false } ?? false
        guard pdfReachable, FileManager.default.isReadableFile(atPath: db) else {
            ai?.completeError("Can't access the source PDF or the analysis index. Check the drive connection.")
            return
        }
        // Read settings FRESH per question (the popover writes them) → a change applies on the NEXT question.
        // Resolve the provider; an Anthropic model with no key falls back to Apple. Ollama reachability is
        // checked at call time (a clear "can't reach Ollama" notice on failure — the app never crashes).
        let cloudKey = CloudBackend.key()
        var provider = ModelProvider(rawValue: Settings.selectedModelProvider) ?? .apple
        if provider == .anthropic, cloudKey == nil { provider = .apple }
        let modelId = Settings.selectedModelId
        let ollamaBase = Settings.ollamaURL

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                // 1) retrieve (pure-Swift e5/NLEmbedding cosine ⊕ BM25 hybrid). RAW direction: NO off-topic gate —
                //    retrieval always returns the top-k chunks and we ALWAYS proceed to generation. The retrieved
                //    passages are context for the LLM; if they don't cover the question, the model answers freely.
                let r = try DocumentIndex.retrieve(indexPath: db, question: question, provider: Embeddings.current)
                let chunkTexts = r.chunks.map { $0.text }

                // 2) generate FROM THE CHUNKS. Streaming providers (Apple on-device, Ollama local) stream —
                //    first words appear as the model produces them; cloud is non-streaming (falls through).
                switch provider {
                case .apple:
                    if #available(macOS 26, *), case .available = SummarizationService.availability() {
                        for try await p in OnDeviceQA.answerFromDocumentStream(question: question, chunks: chunkTexts, documentKey: db) {
                            await MainActor.run { self.ai?.streamAnswer(p) }
                        }
                        await MainActor.run { self.ai?.finishStreamedAnswer() }
                        return
                    }
                    // Apple unavailable → fall through to the non-streaming generate below (shows a notice).
                case .ollama:
                    for try await p in OllamaQA.answerFromDocumentStream(question: question, chunks: chunkTexts, model: modelId, base: ollamaBase) {
                        await MainActor.run { self.ai?.streamAnswer(p) }
                    }
                    await MainActor.run { self.ai?.finishStreamedAnswer() }
                    return
                case .anthropic:
                    break                                        // cloud doesn't stream → non-streaming below
                }

                // Non-streaming generate (cloud; or Apple when on-device is unavailable).
                let raw: String
                switch provider {
                case .apple:
                    guard #available(macOS 26, *), case .available = SummarizationService.availability() else {
                        // No Python fallback anymore — steer the user to a model that works on this Mac.
                        await MainActor.run { self.ai?.completeError(
                            "Apple Intelligence isn't available on this Mac. Pick a cloud model (add an API key) or connect Ollama in settings.") }
                        return
                    }
                    raw = try await OnDeviceQA.answerFromDocument(question: question, chunks: chunkTexts, documentKey: db)
                case .anthropic:
                    let key = cloudKey!                          // provider == .anthropic ⇒ a key exists
                    raw = try await CloudQA.answerFromDocument(question: question, chunks: chunkTexts, model: modelId, key: key)
                case .ollama:
                    raw = try await OllamaQA.answerFromDocument(question: question, chunks: chunkTexts, model: modelId, base: ollamaBase)
                }

                // The answer is shown as-is. NLI verification + element-bbox citations required the Python
                // sidecar (now removed); a future Swift-native grounding pass can repopulate the preserved
                // `completeAnswer(_:)` renderer.
                await MainActor.run { self.ai?.completeUnverifiedAnswer(raw) }
            } catch {
                await MainActor.run { self.ai?.completeError(error.localizedDescription) }
            }
        }
    }

    /// Embedder identity baked into the index filename — taken from the ACTIVE embedder (`Embeddings.current`),
    /// so switching embedders (e5 ↔ NLEmbedding fallback) automatically produces a new path and RE-INGESTS
    /// instead of silently reusing the old embedder's vectors (incompatible even at the same dimension; e5 is
    /// 384-d, NLEmbedding 512-d). Stale `.padidx` files from a prior embedder are simply orphaned (harmless).
    private static var embedderTag: String { Embeddings.current.identifier }

    /// Index lives in Application Support (not next to the PDF). Keyed by a hash of the FULL standardized
    /// path — NOT just the basename — so two different PDFs that merely share a file name (e.g. a
    /// `report.pdf` in two folders/volumes) never collide on one index and silently answer from the wrong
    /// document's embeddings. The basename is kept as a readable prefix for debuggability, and the embedder
    /// tag ensures a re-ingest when the embedder changes.
    private static func indexPath(for pdfURL: URL) -> String {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))?
            .appendingPathComponent("Openview/index", isDirectory: true)
            ?? fm.temporaryDirectory.appendingPathComponent("Openview/index", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let canonical = pdfURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()   // 16 hex chars
        let base = pdfURL.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent("\(base)-\(embedderTag)-\(key).padidx").path
    }
}
