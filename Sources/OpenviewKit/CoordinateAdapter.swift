import CoreGraphics

/// Vertical origin of a parser-reported bounding box.
/// - topLeft: y grows DOWNWARD from the top edge (PyMuPDF; Docling `CoordOrigin.TOPLEFT`).
/// - bottomLeft: y grows UPWARD from the bottom edge (PDF-native; Docling `CoordOrigin.BOTTOMLEFT`).
public enum CoordOrigin: String, Sendable {
    case topLeft
    case bottomLeft
}

/// A bounding box for one element on one page, in PDF points, as reported by a parser.
/// `l/r` are horizontal; `t/b` are the two vertical edges in the parser's own origin.
public struct ParserBBox: Sendable, Equatable {
    public let l, t, r, b: Double
    public let origin: CoordOrigin
    public init(l: Double, t: Double, r: Double, b: Double, origin: CoordOrigin) {
        self.l = l; self.t = t; self.r = r; self.b = b; self.origin = origin
    }
}

/// Converts parser bboxes into PDFKit page-space rects.
///
/// PDFKit page space is the PDF-native coordinate system: **origin bottom-left, y up**,
/// units in points. `PDFPage.bounds(for: .mediaBox)` gives the page rect. A converted
/// rect can be used directly as a `PDFAnnotation` bounds or drawn as an overlay.
///
/// This is the single conversion point — THE core risk flagged in CLAUDE.md (the y-flip).
/// It is convention-aware so the same code serves PyMuPDF (top-left) today and Docling
/// (either origin) once the sidecar lands; only the element source changes.
public enum CoordinateAdapter {

    /// Convert assuming the parser's coordinate space already matches PDFKit points
    /// (no scaling) — only the origin may differ.
    /// - Parameters:
    ///   - box: the parser bbox (points, in its declared origin).
    ///   - pageHeight: PDFKit mediaBox height in points (same units as the bbox).
    public static func toPDFKitRect(_ box: ParserBBox, pageHeight: Double) -> CGRect {
        convert(box, sx: 1, sy: 1, pdfkitHeight: pageHeight)
    }

    /// Convert when the parser reports coordinates in its OWN page space (e.g. Docling at a
    /// different resolution). Scales by (pdfkit / parser) per axis, then flips the origin.
    /// Falls back to the no-scale path when the two page sizes are equal.
    public static func toPDFKitRect(_ box: ParserBBox,
                                    parserPageSize: CGSize,
                                    pdfkitPageSize: CGSize) -> CGRect {
        let sx = parserPageSize.width  > 0 ? pdfkitPageSize.width  / parserPageSize.width  : 1
        let sy = parserPageSize.height > 0 ? pdfkitPageSize.height / parserPageSize.height : 1
        return convert(box, sx: sx, sy: sy, pdfkitHeight: pdfkitPageSize.height)
    }

    /// Core: scale each axis, then map the origin to PDFKit (bottom-left, y up).
    private static func convert(_ box: ParserBBox, sx: Double, sy: Double, pdfkitHeight: Double) -> CGRect {
        let l = box.l * sx, r = box.r * sx
        let t = box.t * sy, b = box.b * sy
        let x = min(l, r)
        let width = abs(r - l)
        let height = abs(b - t)
        let yBottom: Double
        switch box.origin {
        case .bottomLeft:
            // y already measured up from the bottom; the lower edge is the smaller value.
            yBottom = min(t, b)
        case .topLeft:
            // y measured down from the top; the lower edge sits `max(t,b)` below the top,
            // so its distance from the page bottom is pdfkitHeight - max(t,b). (the y-flip)
            yBottom = pdfkitHeight - max(t, b)
        }
        return CGRect(x: x, y: yBottom, width: width, height: height)
    }
}
