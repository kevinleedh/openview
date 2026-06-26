import CoreML
import Foundation

/// e5-small-v2 (intfloat/e5-small-v2, 384-d, English) running on-device via **Core ML** — the stronger
/// retrieval embedder that replaces NLEmbedding's weak separation. NO Python at runtime: the model is a
/// bundled `.mlpackage` (built once by `tools/convert_e5.py`), tokenization is pure-Swift
/// ``WordPieceTokenizer``, and the Core ML graph outputs `last_hidden_state` which this type mean-pools
/// (attention-mask weighted) and L2-normalizes — exactly reproducing sentence-transformers e5 (verified to
/// cosine 1.0 by the converter, and the tokenizer is verified token-for-token).
///
/// e5 is ASYMMETRIC: queries are prefixed `"query: "`, passages `"passage: "` (omitting these halves e5's
/// quality), so ``embed(_:kind:)`` honors `kind`. Init is FAILABLE — if the bundled model or tokenizer can't
/// be found/loaded, it returns nil and `Embeddings.current` falls back to NLEmbedding (graceful degrade).
final class E5CoreMLProvider: EmbeddingProvider {

    let identifier = "e5s2-v1"          // ↔ DocumentEngine.embedderTag; bump if the model/pooling changes
    var dimension: Int { 384 }
    var isAvailable: Bool { true }
    // Single cosine cutoff (low == high → the BM25-anchor branch is OFF; turning it on would re-reject legit
    // questions that share no word with the doc). The 4-doc calibration (FORMAL Q&A over papers/reports) cleanly
    // separated at 0.85, but that OVER-REJECTS casual questions on other genres: a résumé scored on-topic
    // "who is X" / "what is his current role" at 0.80–0.85 (below 0.85), so real questions about the open
    // document were wrongly turned away. Default lowered to 0.80 (ANSWER-FIRST — user choice): document
    // questions get answered even when phrased casually; an occasional off-topic question passes the gate and
    // the LLM (instructed to answer ONLY from the passages) replies "not in this document" as the second line
    // of defense. Override with OPENVIEW_GATE (raise = stricter off-topic rejection; 0.85 = the trust-first point).
    let gateLow = gateOverride("OPENVIEW_GATE", default: 0.80)
    let gateHigh = gateOverride("OPENVIEW_GATE_HIGH", default: 0.80)

    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private let seqLen: Int

    init?() {
        guard let dir = Self.artifactsDir(),
              let tok = WordPieceTokenizer(vocabURL: dir.appendingPathComponent("e5-vocab.txt"),
                                           configURL: dir.appendingPathComponent("e5-tokenizer.json")),
              let m = Self.loadModel(in: dir) else { return nil }
        tokenizer = tok
        model = m
        seqLen = tok.maxLen
    }

    func embed(_ text: String, kind: EmbedKind) -> [Float]? {
        let prefixed = (kind == .query ? "query: " : "passage: ") + text
        let (ids, mask) = tokenizer.encode(prefixed)
        guard let idArr = Self.mlInt(ids), let maskArr = Self.mlInt(mask),
              let input = try? MLDictionaryFeatureProvider(dictionary: ["input_ids": idArr, "attention_mask": maskArr]),
              let out = try? model.prediction(from: input),
              let lhs = out.featureValue(for: "last_hidden_state")?.multiArrayValue
        else { return nil }
        return Self.meanPoolNormalize(lhs, mask: mask, dim: dimension)
    }

    // MARK: – Core ML model loading (compile the .mlpackage once, cache the compiled .mlmodelc)

    /// Find the bundled artifacts (the app copies them into Contents/Resources at build). For the headless
    /// calibration harness, `OPENVIEW_E5_DIR` points straight at `tools/artifacts`.
    private static func artifactsDir() -> URL? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["OPENVIEW_E5_DIR"],
           fm.fileExists(atPath: (env as NSString).appendingPathComponent("e5-vocab.txt")) {
            return URL(fileURLWithPath: env)
        }
        if let res = Bundle.main.resourceURL,
           fm.fileExists(atPath: res.appendingPathComponent("e5-vocab.txt").path) {
            return res
        }
        return nil
    }

    private static func loadModel(in dir: URL) -> MLModel? {
        let fm = FileManager.default
        let pkg = dir.appendingPathComponent("e5-small-v2.mlpackage")
        guard fm.fileExists(atPath: pkg.path) else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all                          // ANE/GPU/CPU — fast on Apple Silicon

        // Compiling the .mlpackage is slow; cache the compiled .mlmodelc (keyed by embedder id so a model
        // change invalidates it) and reuse across launches.
        let cacheDir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("Openview/models", isDirectory: true)
        let cached = cacheDir?.appendingPathComponent("e5s2-v1.mlmodelc")
        if let cached, fm.fileExists(atPath: cached.path), let m = try? MLModel(contentsOf: cached, configuration: cfg) {
            return m
        }
        guard let compiled = try? MLModel.compileModel(at: pkg) else { return nil }
        if let cached, let dir = cacheDir {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.removeItem(at: cached)
            try? fm.copyItem(at: compiled, to: cached)
            if let m = try? MLModel(contentsOf: cached, configuration: cfg) { return m }
        }
        return try? MLModel(contentsOf: compiled, configuration: cfg)   // fall back to the temp compiled model
    }

    // MARK: – tensor helpers

    private static func mlInt(_ values: [Int32]) -> MLMultiArray? {
        guard let a = try? MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32) else { return nil }
        let p = a.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        for i in 0..<values.count { p[i] = values[i] }
        return a
    }

    /// Attention-mask weighted mean over tokens, then L2 normalize → the e5 sentence embedding. Reads
    /// last_hidden_state [1, seq, dim] (contiguous, so element [0,t,d] is at t*dim + d). Handles fp32 and the
    /// ANE's fp16 output; falls back to NSNumber access for any other dtype.
    private static func meanPoolNormalize(_ a: MLMultiArray, mask: [Int32], dim: Int) -> [Float]? {
        let seq = mask.count
        guard a.count >= seq * dim else { return nil }
        var acc = [Float](repeating: 0, count: dim)
        var n: Float = 0
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.bindMemory(to: Float32.self, capacity: a.count)
            for t in 0..<seq where mask[t] == 1 { n += 1; let b = t * dim; for d in 0..<dim { acc[d] += p[b + d] } }
        case .float16:
            let p = a.dataPointer.bindMemory(to: Float16.self, capacity: a.count)
            for t in 0..<seq where mask[t] == 1 { n += 1; let b = t * dim; for d in 0..<dim { acc[d] += Float(p[b + d]) } }
        default:
            for t in 0..<seq where mask[t] == 1 { n += 1; let b = t * dim; for d in 0..<dim { acc[d] += a[b + d].floatValue } }
        }
        guard n > 0 else { return nil }
        for d in 0..<dim { acc[d] /= n }
        return NLEmbeddingProvider.normalized(acc)
    }
}
