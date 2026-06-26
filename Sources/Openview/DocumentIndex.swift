import Foundation
import NaturalLanguage
import PDFKit

/// Pure-Swift document index — the replacement for the Python sidecar's `pipeline.py` (parse → window →
/// embed → store → retrieve). No Python, no torch, no sqlite-vec: text comes from PDFKit, embeddings from
/// ``EmbeddingProvider`` (Apple NLEmbedding), and the index is a small Codable file. This is what makes the
/// app run from a plain `.dmg` with zero extra installs.
///
/// What it keeps from the proven sidecar design:
///   • RETRIEVAL UNIT = a context-rich WINDOW (a few consecutive sentences within one page), embedded for
///     ranking — not a single sentence (the recall@1 lesson).
///   • HYBRID retrieval = cosine (semantic) ⊕ BM25 (lexical), fused by reciprocal rank.
///
/// RAW direction (no relevance rejection): retrieval ALWAYS returns the top-k chunks — there is no off-topic
/// gate in the answer path. `gate(_:low:high:)` + the providers' `gateLow`/`gateHigh` are retained ONLY for the
/// offline calibration harness (`benchmark/gate_calibration.swift`); they no longer block any answer.
///
/// What changed vs the sidecar (the deferred "quality" pass owns these):
///   • Parsing is PDFKit page text, not Docling — so there is no element bbox / table structure, hence no
///     NLI-grounded element-level citation here (that path is dormant in the AI-answer-only product).
///   • The cosine cutoff is recalibrated for NLEmbedding's scale (see ``cutoff``).
enum DocumentIndex {

    // MARK: – Tunables (the deferred quality pass recalibrates these)

    /// Max characters per retrieval window. Windows never cross a page boundary (so a hit keeps its page).
    /// ~700 chars ≈ a short paragraph — enough context to rank well without diluting the embedding.
    private static let windowCharBudget = 700
    /// Below this, a trailing window is merged back into the previous one rather than embedded alone.
    private static let windowMinChars = 40
    /// Reciprocal-rank-fusion constant (matches the sidecar's RRF=60).
    private static let rrf = 60.0
    /// Candidate pool depth for each ranker before fusion.
    private static let pool = 40

    // OFF-TOPIC gate thresholds are EMBEDDER-SPECIFIC (a cosine cutoff for e5's 0.71–0.91 scale would reject
    // everything from NLEmbedding's 0.2–0.6 scale), so they live on the active `EmbeddingProvider`
    // (`gateLow`/`gateHigh`) and `gate(_:low:high:)` reads them. Calibrated against a labeled 4-doc × 10-Q
    // sweep (2 papers + a financial report + an economics report):
    //   • e5 (e5s2-v1): the FORMAL 4-doc eval separated cleanly at 0.85 (on ≥0.851 / off ≤0.850), but 0.85
    //     OVER-REJECTS casual questions on other genres — a résumé scored on-topic "who is X" / "current role"
    //     at 0.80–0.85 → wrongly turned away. Default lowered to ANSWER-FIRST single cutoff 0.80 (user choice);
    //     off-topic that slips the gate is caught by the LLM ("answer only from the passages"). 0.85 = the
    //     stricter trust-first point, available via OPENVIEW_GATE.
    //   • NLEmbedding (nle-v1, the fallback): scores overlap hard (off-topic can out-score on-topic; doc size
    //     inflates both) → two-threshold + BM25 anchor (0.35/0.42) → on 95% / off 60% (its ceiling).
    // Override at runtime with `OPENVIEW_GATE` / `OPENVIEW_GATE_HIGH` (apply to whichever embedder is active).

    // MARK: – Persisted format

    struct Stored: Codable {
        let tag: String                 // embedder identifier — must match the live provider or we re-ingest
        let dim: Int
        let windows: [Window]
    }
    struct Window: Codable {
        let page: Int                   // 1-based (for "p.N" references)
        let text: String
        let vector: [Float]?            // unit-normalized; nil when the embedder couldn't vectorize this window
    }

    /// One retrieved chunk handed to the Swift generator (Apple / cloud / Ollama). Mirrors the old sidecar
    /// `retrieve` chunk shape (text + page) so `DocumentEngine` / the QA generators are unchanged.
    struct Chunk {
        let text: String
        let page: Int
    }
    struct Result {
        let grounded: Bool              // vestigial (no off-topic gate anymore) — always true on the normal path
        let topScore: Double
        let chunks: [Chunk]             // the top-k ranked windows (never gated away)
    }

    // MARK: – Build (ingest)

    /// Parse → window → embed → store. Runs OFF the main thread (the caller passes a fresh `PDFDocument`
    /// created from file data, NOT the one the on-screen `PDFView` is rendering — that doc is main-thread-
    /// affine and would deadlock). Writes the index atomically to `indexPath`. Returns (#windows, #pages).
    @discardableResult
    static func build(document: PDFDocument, indexPath: String, provider: EmbeddingProvider) throws -> (windows: Int, pages: Int) {
        let windows = makeWindows(from: document)
        guard !windows.isEmpty else {
            throw err("No extractable text found in this document. It may be a scanned (image-only) PDF.")
        }
        let stored = Stored(
            tag: provider.identifier,
            dim: provider.dimension,
            windows: windows.map { w in
                Window(page: w.page, text: w.text, vector: provider.embed(w.text, kind: .passage))
            })
        let data = try JSONEncoder().encode(stored)
        let url = URL(fileURLWithPath: indexPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let embedded = stored.windows.reduce(0) { $0 + ($1.vector != nil ? 1 : 0) }
        if !provider.isAvailable {
            NSLog("[index] WARNING: on-device embedder (%@) is UNAVAILABLE on this OS/build — index has no "
                + "vectors; retrieval will be keyword-only (BM25) and lower quality.", provider.identifier)
        }
        NSLog("[index] built %d windows over %d pages (%d embedded, embedder=%@) → %@",
              stored.windows.count, document.pageCount, embedded, provider.identifier, url.lastPathComponent)
        return (stored.windows.count, document.pageCount)
    }

    /// Page-aware sentence windows. Each page's text is split into sentences and greedily packed into
    /// windows up to ``windowCharBudget``; windows never span pages, so a retrieved window keeps a single,
    /// correct page number. A tiny trailing remainder is merged into the prior window.
    private static func makeWindows(from document: PDFDocument) -> [(page: Int, text: String)] {
        var windows: [(page: Int, text: String)] = []
        for i in 0..<document.pageCount {
            guard let raw = document.page(at: i)?.string else { continue }
            let pageText = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pageText.isEmpty else { continue }
            let page = i + 1                                   // 1-based, matches PDFKit page labels' base
            var current = ""
            for sentence in NLEmbeddingProvider.sentences(in: pageText) {
                let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.isEmpty { continue }
                if current.isEmpty {
                    current = s
                } else if current.count + 1 + s.count <= windowCharBudget {
                    current += " " + s
                } else {
                    windows.append((page, current))
                    current = s
                }
            }
            if !current.isEmpty {
                // Merge a tiny tail into the previous SAME-PAGE window so we don't embed a stub — but only
                // when the merge still fits the budget, so a near-full window doesn't overflow it.
                if current.count < windowMinChars, let last = windows.last, last.page == page,
                   last.text.count + 1 + current.count <= windowCharBudget {
                    windows[windows.count - 1] = (page, last.text + " " + current)
                } else {
                    windows.append((page, current))
                }
            }
        }
        return windows
    }

    // MARK: – Retrieve (query)

    /// Hybrid retrieval (no off-topic gate). Loads the persisted index, embeds the question, ranks by cosine and
    /// BM25, fuses by reciprocal rank, and ALWAYS returns the top-k chunks. Throws if the index is missing/corrupt
    /// or was built by a different embedder (the caller treats that as "re-ingest needed").
    ///
    /// RAW direction: there is no relevance rejection — every question's top-k windows go to the LLM, which
    /// answers freely. `grounded` is retained on `Result` for source compatibility and is always `true` here.
    static func retrieve(indexPath: String, question: String, provider: EmbeddingProvider, k: Int = 8) throws -> Result {
        let windows = try loadWindows(indexPath: indexPath, provider: provider)
        guard !windows.isEmpty else { return Result(grounded: false, topScore: 0, chunks: []) }

        let s = signals(windows: windows, question: question, provider: provider, k: k)
        // RAW direction: NO off-topic gate. Ranking (cosine ⊕ BM25 ⊕ RRF) still picks the best windows, but we
        // never REJECT — the top-k chunks are ALWAYS handed to the LLM, which answers freely. (`gate(_:)` +
        // `gateLow`/`gateHigh` remain only for the offline calibration harness; they no longer block any answer.)
        let chunks = s.fusedTopIdx.map { Chunk(text: windows[$0].text, page: windows[$0].page) }

        // Behavior-neutral retrieval log (ranking diagnostics only — no gate decision). Verbose per-chunk dump
        // under OPENVIEW_RETRIEVE_DEBUG=1.
        let scores = s.fusedTopIdx.map { String(format: "%.3f", max(0, s.cosine[$0])) }.joined(separator: ",")
        let pages = s.fusedTopIdx.map { String(windows[$0].page) }.joined(separator: ",")
        let semState = s.semanticAvailable ? "cosine"
            : (provider.isAvailable ? "bm25-only" : "bm25-only(NLEmbedding-unavailable)")
        NSLog("[retrieve] top1=%.3f top2=%.3f kmean=%.3f bm25=%d k=%d sem=%@ scores=[%@] pages=[%@] q=%@",
              s.top1, s.top2, s.topKMean, s.bm25Hits, chunks.count, semState, scores, pages, question)
        if ProcessInfo.processInfo.environment["OPENVIEW_RETRIEVE_DEBUG"] == "1" {
            for (n, idx) in s.fusedTopIdx.enumerated() {
                NSLog("[retrieve]   #%d p%d cos=%.3f: %@", n + 1, windows[idx].page,
                      max(0, s.cosine[idx]), String(windows[idx].text.prefix(160)))
            }
        }
        return Result(grounded: true, topScore: s.top1, chunks: chunks)
    }

    /// All the raw retrieval signals for one query — kept SEPARATE from the gate DECISION (`gate(_:)`) so the
    /// off-topic gate can be calibrated/tuned without touching indexing, embedding, fusion, or generation.
    struct Signals {
        let semanticAvailable: Bool
        let top1: Double            // highest window cosine (0 if no semantic) — the primary off-topic signal
        let top2: Double            // 2nd-highest window cosine (for the top1−top2 margin)
        let topKMean: Double        // mean cosine over the fused top-k (broad-relevance signal)
        let bm25Hits: Int           // # windows matching ≥1 query CONTENT term (0 ⇒ no lexical anchor at all)
        let bm25TopCosine: Double   // cosine of the BM25 #1 window (lexical↔semantic agreement)
        let fusedTopIdx: [Int]      // RRF-fused top-k window indices
        let cosine: [Double]        // per-window cosine (NO_VEC where no vector)
    }

    /// Sentinel BELOW the valid cosine range [-1, 1] so a legitimate cosine of exactly -1.0 is never mistaken
    /// for "no vector computed".
    private static let NO_VEC = -2.0

    /// Compute every retrieval signal (cosine, BM25, RRF fusion) — UNCHANGED from the original retrieval math;
    /// just factored out so `gate(_:)` and the calibration harness can both consume it.
    static func signals(windows: [Window], question: String, provider: EmbeddingProvider, k: Int) -> Signals {
        // — semantic (cosine) —
        let qv = provider.embed(question, kind: .query)
        var cosine = [Double](repeating: NO_VEC, count: windows.count)
        if let qv {
            for (idx, w) in windows.enumerated() {
                guard let wv = w.vector, wv.count == qv.count else { continue }
                cosine[idx] = dot(qv, wv)                            // both unit-normalized → dot == cosine
            }
        }
        let valid = cosine.enumerated().filter { $0.element > NO_VEC }.sorted { $0.element > $1.element }
        let semanticAvailable = qv != nil && !valid.isEmpty
        let vecRank = semanticAvailable ? valid.prefix(pool).map { $0.offset } : []
        let top1 = semanticAvailable ? max(0, valid.first?.element ?? 0) : 0
        let top2 = (semanticAvailable && valid.count >= 2) ? max(0, valid[1].element) : 0

        // — lexical (BM25) —
        let bm = BM25(documents: windows.map { $0.text })
        let bmRank = Array(bm.rank(query: question).prefix(pool))
        let bm25Hits = bm.hitCount(query: question)
        let bm25TopCosine = bmRank.first.map { max(0, cosine[$0]) } ?? 0

        // — reciprocal-rank fusion → top-k —
        var fused: [Int: Double] = [:]
        for (rank, idx) in vecRank.enumerated() { fused[idx, default: 0] += 1.0 / (rrf + Double(rank) + 1) }
        for (rank, idx) in bmRank.enumerated() { fused[idx, default: 0] += 1.0 / (rrf + Double(rank) + 1) }
        let fusedTopIdx = fused.keys.sorted { fused[$0]! > fused[$1]! }.prefix(k).map { $0 }
        let kCos = fusedTopIdx.map { max(0, cosine[$0]) }
        let topKMean = kCos.isEmpty ? 0 : kCos.reduce(0, +) / Double(kCos.count)

        return Signals(semanticAvailable: semanticAvailable, top1: top1, top2: top2, topKMean: topKMean,
                       bm25Hits: bm25Hits, bm25TopCosine: bm25TopCosine, fusedTopIdx: fusedTopIdx, cosine: cosine)
    }

    /// THE off-topic gate decision — RETAINED ONLY for the offline calibration harness; it is NO LONGER called
    /// by `retrieve()` (the answer path never rejects). `low`/`high` are the ACTIVE embedder's
    /// `gateLow`/`gateHigh` (embedder-specific scales). Rule:
    ///   • STRONG semantic match (top1 ≥ `high`) → relevant, no lexical anchor required.
    ///   • MODERATE match (`low` ≤ top1 < `high`) → relevant ONLY with a BM25 lexical anchor (catches a
    ///     zero-word-overlap off-topic query that merely resonates with boilerplate). Inert when low == high.
    ///   • Below `low` → not relevant.
    ///   • Embedder unavailable (no vectors) → BM25-only "any lexical hit".
    /// For e5 (clean cosine separation) low == high == 0.85 ⇒ a pure single threshold; for the NLEmbedding
    /// fallback (overlapping scores) low 0.35 / high 0.42 uses the BM25 anchor. See the notes at the top.
    static func gate(_ s: Signals, low: Double, high: Double) -> Bool {
        guard s.semanticAvailable else { return s.bm25Hits > 0 }   // embedder unavailable → BM25-only any-hit
        if s.top1 >= high { return true }                          // strong semantic match → relevant
        if s.top1 >= low { return s.bm25Hits > 0 }                 // moderate → needs a lexical anchor
        return false                                               // (low == high ⇒ pure single threshold)
    }

    /// Load + validate the persisted index; self-heal a corrupt/mismatched file by deleting it so the next open
    /// re-ingests (the open fast-path trusts file existence; a broken file would otherwise strand the user).
    private static func loadWindows(indexPath: String, provider: EmbeddingProvider) throws -> [Window] {
        let stored: Stored
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: indexPath))
            stored = try JSONDecoder().decode(Stored.self, from: data)
        } catch {
            try? FileManager.default.removeItem(atPath: indexPath)
            throw err("The analysis index was unreadable and has been reset. Reopen the document to re-analyze it.")
        }
        guard stored.tag == provider.identifier else {
            try? FileManager.default.removeItem(atPath: indexPath)
            throw err("The analysis index was built by a different embedder (\(stored.tag)) and has been reset. Reopen the document to re-analyze it.")
        }
        return stored.windows
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Double {
        var s: Float = 0
        for i in 0..<min(a.count, b.count) { s += a[i] * b[i] }
        return Double(s)
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "Openview.Index", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Minimal Okapi BM25 over the window corpus (replaces the sidecar's SQLite FTS5 `bm25()`). Recall-oriented
/// OR-of-terms scoring: a window matching any distinctive query term ranks, so BM25 can pinpoint a row by its
/// label + numbers among near-identical windows — the same intent as the Python `_fts_query`. Built per query
/// (corpora are a few hundred windows; this is microseconds).
private struct BM25 {
    private let docTokens: [[String]]
    private let docLen: [Double]
    private let avgdl: Double
    private let idf: [String: Double]
    private let k1 = 1.5, b = 0.75

    // Mirrors the sidecar's FTS stoplist so lexical scoring keys on content words, not glue words.
    private static let stop: Set<String> = ["the", "a", "an", "of", "in", "on", "for", "to", "and", "or",
        "what", "were", "was", "is", "are", "how", "does", "did", "do", "at", "by", "with", "its", "their",
        "that", "this", "which", "be", "as", "from", "have", "has"]

    init(documents: [String]) {
        docTokens = documents.map { BM25.tokenize($0) }
        docLen = docTokens.map { Double($0.count) }
        let n = docTokens.count
        avgdl = n > 0 ? docLen.reduce(0, +) / Double(n) : 0
        var df: [String: Int] = [:]
        for toks in docTokens {
            for t in Set(toks) { df[t, default: 0] += 1 }
        }
        var idf: [String: Double] = [:]
        for (t, f) in df {
            idf[t] = log(1.0 + (Double(n) - Double(f) + 0.5) / (Double(f) + 0.5))
        }
        self.idf = idf
    }

    /// Return document indices ranked by descending BM25 score for the query's content terms (OR semantics).
    func rank(query: String) -> [Int] {
        let qTerms = Set(BM25.tokenize(query)).filter { idf[$0] != nil }
        guard !qTerms.isEmpty, avgdl > 0 else { return [] }
        var scores: [(Int, Double)] = []
        for (i, toks) in docTokens.enumerated() {
            guard !toks.isEmpty else { continue }
            var tf: [String: Int] = [:]
            for t in toks where qTerms.contains(t) { tf[t, default: 0] += 1 }
            if tf.isEmpty { continue }
            var s = 0.0
            let dl = docLen[i]
            for (t, f) in tf {
                let num = Double(f) * (k1 + 1)
                let den = Double(f) + k1 * (1 - b + b * dl / avgdl)
                s += (idf[t] ?? 0) * num / den
            }
            scores.append((i, s))
        }
        return scores.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// # documents (windows) containing at least one query CONTENT term — the lexical-anchor count the gate
    /// uses. 0 ⇒ the query shares no real word with the document → a strong "off-topic" signal even if some
    /// window's embedding incidentally resonates with it.
    func hitCount(query: String) -> Int {
        let qTerms = Set(BM25.tokenize(query)).filter { idf[$0] != nil }
        guard !qTerms.isEmpty else { return 0 }
        var n = 0
        for toks in docTokens where !Set(toks).isDisjoint(with: qTerms) { n += 1 }
        return n
    }

    private static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                cur.append(ch)
            } else if !cur.isEmpty {
                if cur.count >= 2 && !stop.contains(cur) { out.append(cur) }
                cur = ""
            }
        }
        if cur.count >= 2 && !stop.contains(cur) { out.append(cur) }
        return out
    }
}
