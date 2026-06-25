import Foundation

/// Pure-Swift BERT WordPiece tokenizer (uncased) — the runtime tokenizer for `E5CoreMLProvider`, so the app
/// needs NO Python tokenizer at inference. It reproduces HuggingFace's `BertTokenizer` deterministically:
/// BasicTokenizer (clean → lowercase → strip accents → split on punctuation/whitespace) then a greedy
/// longest-match WordPiece with `##` continuations, framed by [CLS]…[SEP], truncated and right-padded to a
/// fixed length with [PAD] (and a matching attention mask). Verified token-for-token against the reference
/// tokenizer via `tools/convert_e5.py`'s `e5-verify.json` (any mismatch breaks embedding equivalence, so the
/// match is a hard gate).
struct WordPieceTokenizer {

    private let vocab: [String: Int32]
    private let clsId: Int32, sepId: Int32, padId: Int32, unkId: Int32
    private let doLowerCase: Bool
    let maxLen: Int
    private let maxCharsPerWord = 100

    /// Load `vocab.txt` (one token per line; line index = id) + the tokenizer config JSON.
    init?(vocabURL: URL, configURL: URL) {
        guard let vocabText = try? String(contentsOf: vocabURL, encoding: .utf8),
              let cfgData = try? Data(contentsOf: configURL),
              let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any] else { return nil }
        var v: [String: Int32] = [:]
        var i: Int32 = 0
        vocabText.enumerateLines { line, _ in v[line] = i; i += 1 }
        guard !v.isEmpty else { return nil }
        vocab = v
        clsId = (cfg["cls_id"] as? NSNumber)?.int32Value ?? v["[CLS]"] ?? 101
        sepId = (cfg["sep_id"] as? NSNumber)?.int32Value ?? v["[SEP]"] ?? 102
        padId = (cfg["pad_id"] as? NSNumber)?.int32Value ?? v["[PAD]"] ?? 0
        unkId = (cfg["unk_id"] as? NSNumber)?.int32Value ?? v["[UNK]"] ?? 100
        doLowerCase = (cfg["do_lower_case"] as? Bool) ?? true
        maxLen = (cfg["max_len"] as? NSNumber)?.intValue ?? 256
    }

    /// Encode to fixed-length (`maxLen`) input_ids + attention_mask (1 for real tokens incl. [CLS]/[SEP], 0
    /// for [PAD]). Token ids only — no embedding here.
    func encode(_ text: String) -> (inputIds: [Int32], attentionMask: [Int32]) {
        var ids: [Int32] = [clsId]
        let budget = maxLen - 2                                 // room for [CLS] and [SEP]
        outer: for basic in basicTokenize(text) {
            for piece in wordpiece(basic) {
                if ids.count >= budget + 1 { break outer }      // +1 for the already-added [CLS]
                ids.append(piece)
            }
        }
        ids.append(sepId)
        var mask = [Int32](repeating: 1, count: ids.count)
        if ids.count < maxLen {
            ids.append(contentsOf: [Int32](repeating: padId, count: maxLen - ids.count))
            mask.append(contentsOf: [Int32](repeating: 0, count: maxLen - mask.count))
        }
        return (ids, mask)
    }

    // MARK: – BasicTokenizer (mirrors HF tokenization.py)

    private func basicTokenize(_ text: String) -> [String] {
        let cleaned = clean(text)
        var out: [String] = []
        for token in cleaned.split(whereSeparator: { Self.isWhitespace($0.unicodeScalars.first!) }) {
            var t = String(token)
            if doLowerCase { t = stripAccents(t.lowercased()) }
            out.append(contentsOf: splitOnPunctuation(t))
        }
        return out
    }

    /// Remove control / replacement chars; map any whitespace to a single space (so split() works).
    private func clean(_ text: String) -> String {
        var s = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            if c.value == 0 || c.value == 0xFFFD || Self.isControl(c) { continue }
            s.append(Self.isWhitespace(c) ? " " : c)
        }
        return String(s)
    }

    /// NFD decompose, drop nonspacing marks (é → e) — HF `_run_strip_accents`.
    private func stripAccents(_ text: String) -> String {
        var s = String.UnicodeScalarView()
        for c in text.decomposedStringWithCanonicalMapping.unicodeScalars
        where c.properties.generalCategory != .nonspacingMark { s.append(c) }
        return String(s)
    }

    /// Each punctuation char becomes its own token (HF `_run_split_on_punc`).
    private func splitOnPunctuation(_ text: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            if Self.isPunctuation(c) {
                if !cur.isEmpty { out.append(String(cur)); cur = String.UnicodeScalarView() }
                out.append(String(c))
            } else {
                cur.append(c)
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out.isEmpty ? [text] : out
    }

    // MARK: – WordPiece (greedy longest-match-first)

    private func wordpiece(_ token: String) -> [Int32] {
        let chars = Array(token)
        if chars.count > maxCharsPerWord { return [unkId] }
        var output: [Int32] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var curId: Int32? = nil
            while start < end {
                var sub = String(chars[start..<end])
                if start > 0 { sub = "##" + sub }
                if let id = vocab[sub] { curId = id; break }
                end -= 1
            }
            guard let id = curId else { return [unkId] }         // any unmatchable span → whole word is [UNK]
            output.append(id)
            start = end
        }
        return output
    }

    // MARK: – Unicode classification (mirror HF helpers)

    static func isWhitespace(_ c: Unicode.Scalar) -> Bool {
        if c == " " || c == "\t" || c == "\n" || c == "\r" { return true }
        return c.properties.generalCategory == .spaceSeparator
    }
    static func isControl(_ c: Unicode.Scalar) -> Bool {
        if c == "\t" || c == "\n" || c == "\r" { return false }
        switch c.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned: return true
        default: return false
        }
    }
    static func isPunctuation(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        if (v >= 33 && v <= 47) || (v >= 58 && v <= 64) || (v >= 91 && v <= 96) || (v >= 123 && v <= 126) {
            return true
        }
        switch c.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }
}
