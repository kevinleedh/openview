import Foundation

// Citation / grounded-answer value types. These were defined in the now-deleted `SidecarBridge.swift`
// (they matched the Python sidecar's `answer` JSON). The Python sidecar — and with it the NLI-grounded,
// element-bbox citation PATH — has been removed (it required Python/torch/Docling, the deployment blocker).
//
// The types are KEPT because the UI still references them: `PDFViewController.jumpHighlight(_:)`,
// `CitationPopoverController`, and `AIPanelViewController.completeAnswer(_:)` / `answerAttributedString`.
// In the current AI-answer-only product they are compile-only / dormant (no live path populates an
// `AnswerResponse`), preserved so the verified-citation feature can be reintroduced later without
// re-deriving the model. Generation (Apple / cloud / Ollama) and the new Swift-native retrieval are
// unaffected.

/// One element-level citation carrying everything `CoordinateAdapter` needs to draw the highlight.
struct Citation: Codable, Hashable {
    let page: Int
    let type: String
    let bbox: [Double]
    let origin: String          // "topLeft" | "bottomLeft" (Docling CoordOrigin)
    let parser_page: [Double]   // [width, height] in the parser's page space (for scaling), or []
}

/// One sentence that survived the per-sentence grounding check, with its supporting citations.
struct GroundedSentence: Codable {
    let sentence: String
    let citations: [Citation]
}

/// A grounded-answer response. `status` ∈ grounded | partial | not-found | error.
struct AnswerResponse: Codable {
    let status: String?
    let answer: [GroundedSentence]?
    let gate: String?
    let top_score: Double?
    let error: String?
}
