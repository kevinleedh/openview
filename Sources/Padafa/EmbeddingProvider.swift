import Foundation
import NaturalLanguage

/// The embedding abstraction the retrieval pipeline ranks with. Introduced when the Python+ML sidecar
/// (sentence-transformers / multilingual-e5) was removed so the app ships pure-Swift + Apple frameworks
/// and runs from a plain `.dmg` with ZERO extra installs (no Python, no torch). Every embedding call now
/// goes through this protocol; the only concrete backend today is ``NLEmbeddingProvider`` (Apple's
/// NaturalLanguage). Keeping it behind a protocol means a future, higher-quality embedder (the deferred
/// "quality" pass) is a drop-in: implement `embed` + `dimension` + `identifier`, bump the identifier so
/// stale indexes re-build, and nothing else changes.
/// Some embedders (e5) are ASYMMETRIC: a search query and a stored passage get different instruction
/// prefixes, and omitting them measurably degrades retrieval. `kind` carries that intent end-to-end —
/// ingest embeds passages, query-time embeds a query. Symmetric embedders (NLEmbedding) ignore it.
enum EmbedKind { case query, passage }

protocol EmbeddingProvider {
    /// Embed `text` into a unit-normalized vector (so a dot product IS the cosine similarity). Returns nil
    /// when the backend is unavailable or the text yields no usable vector (empty / un-embeddable) — the
    /// caller SKIPS such items from semantic ranking and leans on BM25, per the migration plan.
    func embed(_ text: String, kind: EmbedKind) -> [Float]?
    /// Vector length (0 when the backend is unavailable). Never hard-code a dimension — read this.
    var dimension: Int { get }
    /// Stable identity of this embedder + its preprocessing. Baked into the index file name + stamped into
    /// the persisted index so vectors from a different embedder are never silently reused (incompatible even
    /// at the same dimension). BUMP whenever the model or the pooling scheme changes.
    var identifier: String { get }
    /// False when the model could not be loaded (older OS / asset missing). Retrieval then degrades to
    /// BM25-only and the UI shows a clear notice instead of failing.
    var isAvailable: Bool { get }
    /// Off-topic gate cutoffs calibrated for THIS embedder's cosine SCALE (e5 ≈0.71–0.91, NLEmbedding ≈0.2–0.6
    /// — a shared constant would be wrong for whichever embedder is active). See ``DocumentIndex/gate(_:low:high:)``.
    /// `gateLow` = below it never relevant; between low and high needs a BM25 lexical anchor; ≥ high passes on
    /// the semantic match alone. (For a clean single-threshold embedder, set low == high.)
    var gateLow: Double { get }
    var gateHigh: Double { get }
}

/// Read a Double env override (PADAFA_GATE / PADAFA_GATE_HIGH apply to whichever embedder is active).
func gateOverride(_ key: String, default def: Double) -> Double {
    if let s = ProcessInfo.processInfo.environment[key], let v = Double(s) { return v }
    return def
}

extension EmbeddingProvider {
    /// Convenience for callers that don't care about asymmetry (defaults to a passage).
    func embed(_ text: String) -> [Float]? { embed(text, kind: .passage) }
}

/// The ACTIVE embedder, resolved ONCE. Prefers e5-small-v2 via Core ML (the stronger retrieval model); falls
/// back to ``NLEmbeddingProvider`` if the Core ML model/tokenizer can't load (older OS / missing bundle
/// artifacts) — a graceful degrade, never a crash. Both the index-path tag and every embed call go through
/// this single instance, so the persisted vectors and the query embedding can never come from different
/// embedders. Loading the Core ML model is the cost, so it happens lazily on first access (warm it off-main
/// at launch — see AppDelegate — to avoid a first-open hitch).
enum Embeddings {
    static let current: EmbeddingProvider = {
        if let e5 = E5CoreMLProvider() {
            NSLog("[embed] active embedder = %@ (Core ML, dim %d)", e5.identifier, e5.dimension)
            return e5
        }
        NSLog("[embed] e5 Core ML unavailable → fallback to NLEmbedding")
        return NLEmbeddingProvider.shared
    }()

    /// Warm the active embedder (loads the Core ML model + runs one throwaway embedding). Off-main, best-effort.
    static func prewarm() { _ = current.embed("warm up the on-device embedding model", kind: .passage) }
}

/// Apple-native embeddings via `NLEmbedding.sentenceEmbedding(for: .english)` — the sidecar replacement.
/// The app is English-only (non-Latin input is blocked in the AI panel), so the English sentence model is
/// the exact match. Loaded once and held resident; `vector(for:)` is the per-call cost.
///
/// Pooling: `NLEmbedding` is a SENTENCE model, so a long retrieval window is split into sentences, each
/// embedded, and the vectors mean-pooled then normalized (the plan's "sentence average" option) — more
/// stable than feeding a multi-sentence blob in one shot. A single-sentence window is just embedded
/// directly. Empty / un-embeddable text → nil (skipped from semantic ranking).
final class NLEmbeddingProvider: EmbeddingProvider {

    /// Shared instance — loading the asset is the expensive part; reuse it everywhere (ingest + every query).
    static let shared = NLEmbeddingProvider()

    private let sentence: NLEmbedding?

    /// `nle-v1` = NLEmbedding English sentence model, per-sentence mean-pool, L2-normalized. Exposed as a
    /// STATIC constant so `DocumentEngine.embedderTag` references the SAME value at compile time (no drift,
    /// no need to instantiate the provider — which would load the asset just to read a string). Bump it when
    /// the model or pooling scheme changes so old indexes re-build.
    static let id = "nle-v1"
    var identifier: String { Self.id }

    init() {
        // `sentenceEmbedding(for:)` can return nil on an OS/build without the asset → guarded everywhere.
        sentence = NLEmbedding.sentenceEmbedding(for: .english)
    }

    var dimension: Int { sentence?.dimension ?? 0 }
    var isAvailable: Bool { sentence != nil }
    // NLEmbedding's weak, doc-size-inflated cosine can't cleanly separate on/off-topic (calibration found a
    // −0.27 overlap), so it uses a two-threshold + BM25-anchor gate (LOW 0.35 / HIGH 0.42 → on 95% / off 60%).
    let gateLow = gateOverride("PADAFA_GATE", default: 0.35)
    let gateHigh = gateOverride("PADAFA_GATE_HIGH", default: 0.42)

    /// NLEmbedding is SYMMETRIC (no query/passage prefixes), so `kind` is ignored here.
    func embed(_ text: String, kind: EmbedKind) -> [Float]? {
        guard let sentence else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Mean-pool the per-sentence vectors of a (possibly multi-sentence) window.
        let parts = Self.sentences(in: trimmed)
        var acc = [Double](repeating: 0, count: sentence.dimension)
        var n = 0
        for s in parts {
            guard let v = sentence.vector(for: s), v.count == sentence.dimension else { continue }
            for i in 0..<v.count { acc[i] += v[i] }
            n += 1
        }
        if n == 0 {
            // No sentence embedded (e.g. punctuation-only fragments) → try the whole string once.
            guard let v = sentence.vector(for: trimmed) else { return nil }
            return Self.normalized(v.map { Float($0) })
        }
        return Self.normalized(acc.map { Float($0 / Double(n)) })
    }

    /// Prewarm by loading the asset (init already did) and running one throwaway embedding so the first real
    /// query doesn't pay the cold cost. Cheap + idempotent; safe to call repeatedly off the main thread.
    static func prewarm() {
        _ = shared.embed("warm up the on-device sentence embedding model", kind: .passage)
    }

    // MARK: – helpers

    /// Split into sentences with NaturalLanguage; falls back to the whole text when no sentence is found.
    static func sentences(in text: String) -> [String] {
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        var out: [String] = []
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(String(s)) }
            return true
        }
        return out.isEmpty ? [text] : out
    }

    /// L2-normalize so a dot product equals the cosine similarity. nil if the vector is all-zero.
    static func normalized(_ v: [Float]) -> [Float]? {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 1e-12 else { return nil }
        return v.map { $0 / norm }
    }
}
