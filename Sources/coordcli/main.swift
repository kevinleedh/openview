import Foundation
import CoreGraphics
import AppKit
import PDFKit
import OpenviewKit

// coordcli — coordinate-PoC driver. Subcommands:
//   selftest                          run adapter (y-flip) assertions; exit 1 on failure
//   gen     <out.pdf> <lines.json>    generate a synthetic PDF + the known lines it contains
//   truth   <pdf> <lines.json> <truth.json>      PDFKit-native bounds per line (ground truth)
//   convert <pdf> <elements.json> <predictions.json>   parser bbox -> PDFKit rect (the adapter)

func die(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

func readJSON(_ path: String) -> Any {
    guard let d = FileManager.default.contents(atPath: path),
          let j = try? JSONSerialization.jsonObject(with: d) else { die("cannot read JSON: \(path)") }
    return j
}
func writeJSON(_ obj: Any, _ path: String) {
    let d = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try! d.write(to: URL(fileURLWithPath: path))
}
func rectArray(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.maxX, r.maxY] }

// The lines drawn into the synthetic PDF: spread across the page (top/middle/bottom) and
// across two pages, so the y-flip is exercised at varied vertical positions.
struct Line { let page: Int; let text: String; let x: Double; let baseline: Double }
let SYNTH_LINES: [Line] = [
    Line(page: 1, text: "Alpha heading near the very top", x: 72, baseline: 720),
    Line(page: 1, text: "Beta paragraph in the upper third", x: 72, baseline: 560),
    Line(page: 1, text: "Gamma centred middle line", x: 72, baseline: 400),
    Line(page: 1, text: "Delta lower third sentence", x: 72, baseline: 220),
    Line(page: 1, text: "Epsilon footer near the bottom", x: 72, baseline: 60),
    Line(page: 2, text: "Zeta second page top line", x: 72, baseline: 700),
    Line(page: 2, text: "Eta second page middle", x: 72, baseline: 396),
    Line(page: 2, text: "Theta second page bottom", x: 72, baseline: 72),
]
let PAGE_W = 612.0, PAGE_H = 792.0

func cmdGen(_ pdfPath: String, _ linesPath: String) {
    var mediaBox = CGRect(x: 0, y: 0, width: PAGE_W, height: PAGE_H)
    guard let ctx = CGContext(URL(fileURLWithPath: pdfPath) as CFURL, mediaBox: &mediaBox, nil)
    else { die("cannot create PDF context") }
    let font = NSFont(name: "Helvetica", size: 18) ?? NSFont.systemFont(ofSize: 18)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    for pageNo in 1...2 {
        ctx.beginPage(mediaBox: &mediaBox)
        // bottom-left origin context; draw selectable text via AppKit.
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        for line in SYNTH_LINES where line.page == pageNo {
            NSAttributedString(string: line.text, attributes: attrs)
                .draw(at: NSPoint(x: line.x, y: line.baseline))
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPage()
    }
    ctx.closePDF()
    let lines = SYNTH_LINES.map { ["page": $0.page, "text": $0.text] as [String: Any] }
    writeJSON(["lines": lines], linesPath)
    print("gen: wrote \(pdfPath) (2 pages) + \(linesPath) (\(SYNTH_LINES.count) lines)")
}

// Ground truth: ask PDFKit itself where each known string is, in PDFKit page space.
func cmdTruth(_ pdfPath: String, _ linesPath: String, _ truthPath: String) {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else { die("cannot open \(pdfPath)") }
    let lines = (readJSON(linesPath) as! [String: Any])["lines"] as! [[String: Any]]
    var cases: [[String: Any]] = []
    for entry in lines {
        let text = entry["text"] as! String
        let pageNo = entry["page"] as! Int
        guard let sels = doc.findString(text, withOptions: []).first else {
            die("truth: PDFKit could not locate line: \(text)")
        }
        guard let page = sels.pages.first else { die("truth: selection has no page for: \(text)") }
        let b = sels.bounds(for: page)   // CGRect in PDFKit page space (bottom-left)
        cases.append([
            "id": text, "doc": (pdfPath as NSString).lastPathComponent, "page": pageNo,
            "type": "text", "zoom": 1.0, "view_mode": "continuous",
            "target": rectArray(b), "text": text,
        ])
    }
    writeJSON([
        "gate": ["iou_min": 0.5, "coverage_min": 0.9, "pass_rate_min": 0.95],
        "coordinate_space": "pdf_page_points", "rect_format": "[x0, y0, x1, y1]",
        "cases": cases,
    ], truthPath)
    print("truth: wrote \(cases.count) PDFKit-native ground-truth cases → \(truthPath)")
}

// The adapter under test: parser bbox (top-left, from PyMuPDF/Docling) -> PDFKit rect.
func cmdConvert(_ pdfPath: String, _ elementsPath: String, _ predsPath: String) {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else { die("cannot open \(pdfPath)") }
    let elements = (readJSON(elementsPath) as! [String: Any])["elements"] as! [[String: Any]]
    var preds: [String: [Double]] = [:]
    for el in elements {
        let id = el["id"] as! String
        let pageNo = el["page"] as! Int
        let bb = el["bbox"] as! [Double]
        let origin = CoordOrigin(rawValue: el["origin"] as? String ?? "topLeft") ?? .topLeft
        guard let page = doc.page(at: pageNo - 1) else { die("convert: no page \(pageNo)") }
        let mb = page.bounds(for: .mediaBox)
        let box = ParserBBox(l: bb[0], t: bb[1], r: bb[2], b: bb[3], origin: origin)
        let rect: CGRect
        if let pp = el["parser_page"] as? [Double], pp.count == 2, pp[0] > 0, pp[1] > 0 {
            // parser reports its own page space (e.g. Docling) → scale into PDFKit points.
            rect = CoordinateAdapter.toPDFKitRect(box,
                parserPageSize: CGSize(width: pp[0], height: pp[1]),
                pdfkitPageSize: CGSize(width: mb.width, height: mb.height))
        } else {
            rect = CoordinateAdapter.toPDFKitRect(box, pageHeight: mb.height)
        }
        preds[id] = rectArray(rect)
    }
    writeJSON(["predictions": preds], predsPath)
    print("convert: wrote \(preds.count) predicted rects → \(predsPath)")
}

// Headless visual proof: render a page with the adapter's converted rect drawn as the blue
// system citation highlight, so we can SEE it land on the target text (same code path the GUI
// uses on chip-click). No display / screen-recording needed.
func cmdRender(_ pdfPath: String, _ elementsPath: String, _ id: String, _ outPath: String) {
    guard let doc = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else { die("cannot open \(pdfPath)") }
    let elements = (readJSON(elementsPath) as! [String: Any])["elements"] as! [[String: Any]]
    guard let el = elements.first(where: { ($0["id"] as! String) == id }) else { die("render: no element \(id)") }
    let pageNo = el["page"] as! Int
    let bb = el["bbox"] as! [Double]
    let origin = CoordOrigin(rawValue: el["origin"] as? String ?? "topLeft") ?? .topLeft
    guard let page = doc.page(at: pageNo - 1) else { die("render: no page \(pageNo)") }
    let mb = page.bounds(for: .mediaBox)
    let box = ParserBBox(l: bb[0], t: bb[1], r: bb[2], b: bb[3], origin: origin)
    let rect: CGRect
    if let pp = el["parser_page"] as? [Double], pp.count == 2, pp[0] > 0, pp[1] > 0 {
        rect = CoordinateAdapter.toPDFKitRect(box,
            parserPageSize: CGSize(width: pp[0], height: pp[1]),
            pdfkitPageSize: CGSize(width: mb.width, height: mb.height))
    } else {
        rect = CoordinateAdapter.toPDFKitRect(box, pageHeight: mb.height)
    }

    renderHighlight(page, rect, mb, outPath)
    print("render: '\(id)' p\(pageNo) rect=\(rectArray(rect).map { ($0 * 10).rounded() / 10 }) → \(outPath)")
}

/// Rasterize a page with the blue system citation highlight at `rect` (PDFKit page space) → PNG.
func renderHighlight(_ page: PDFPage, _ rect: CGRect, _ mb: CGRect, _ outPath: String) {
    let scale = 2.0
    let w = Int(mb.width * scale), h = Int(mb.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { die("no bitmap ctx") }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    ctx.saveGState(); page.draw(with: .mediaBox, to: ctx); ctx.restoreGState()
    ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.30).cgColor); ctx.fill(rect)
    ctx.setStrokeColor(NSColor.systemBlue.cgColor); ctx.setLineWidth(1.0); ctx.stroke(rect)
    guard let cg = ctx.makeImage() else { die("makeImage failed") }
    let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: outPath))
}

// NOTE: the former `e2e` subcommand (ask the Python sidecar → render the top citation) was removed with the
// Python sidecar. The coordinate adapter is still exercised by `selftest` / `convert` / `render` below.

func cmdSelftest() {
    var failures = 0
    func check(_ cond: Bool, _ name: String) {
        if cond { print("  ok   \(name)") } else { print("  FAIL \(name)"); failures += 1 }
    }
    func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }
    let H = 792.0

    let topFlip = CoordinateAdapter.toPDFKitRect(
        ParserBBox(l: 100, t: 50, r: 300, b: 80, origin: .topLeft), pageHeight: H)
    check(approx(topFlip.minX, 100) && approx(topFlip.width, 200), "topLeft x/width preserved")
    check(approx(topFlip.minY, 712) && approx(topFlip.maxY, 742), "topLeft near-top flips to high y")

    let botFlip = CoordinateAdapter.toPDFKitRect(
        ParserBBox(l: 72, t: 740, r: 540, b: 770, origin: .topLeft), pageHeight: H)
    check(approx(botFlip.minY, 22) && approx(botFlip.maxY, 52), "topLeft near-bottom flips to low y")

    let bl = CoordinateAdapter.toPDFKitRect(
        ParserBBox(l: 100, t: 742, r: 300, b: 712, origin: .bottomLeft), pageHeight: H)
    check(approx(bl.minY, 712) && approx(bl.height, 30), "bottomLeft passthrough")

    let tl2 = CoordinateAdapter.toPDFKitRect(
        ParserBBox(l: 72, t: 100, r: 520, b: 140, origin: .topLeft), pageHeight: H)
    let bl2 = CoordinateAdapter.toPDFKitRect(
        ParserBBox(l: 72, t: 692, r: 520, b: 652, origin: .bottomLeft), pageHeight: H)
    check(approx(tl2.minY, bl2.minY) && approx(tl2.height, bl2.height), "top/bottom-left equivalents agree")

    let rev = CoordinateAdapter.toPDFKitRect(
        ParserBBox(l: 300, t: 80, r: 100, b: 50, origin: .topLeft), pageHeight: H)
    check(approx(rev.width, 200) && rev.height > 0, "reversed corners normalized")

    // Scaling: a half-size (306x396) parser space at 2x must reproduce the no-scale top flip.
    let scaled = CoordinateAdapter.toPDFKitRect(
        ParserBBox(l: 50, t: 25, r: 150, b: 40, origin: .topLeft),
        parserPageSize: CGSize(width: 306, height: 396),
        pdfkitPageSize: CGSize(width: 612, height: 792))
    check(approx(scaled.minX, 100) && approx(scaled.width, 200)
          && approx(scaled.minY, 712) && approx(scaled.maxY, 742), "scaled 2x top-left flips correctly")

    print(failures == 0 ? "selftest: PASS ✅" : "selftest: \(failures) FAILED ❌")
    exit(failures == 0 ? 0 : 1)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "selftest": cmdSelftest()
case "gen"     where args.count == 3: cmdGen(args[1], args[2])
case "truth"   where args.count == 4: cmdTruth(args[1], args[2], args[3])
case "convert" where args.count == 4: cmdConvert(args[1], args[2], args[3])
case "render"  where args.count == 5: cmdRender(args[1], args[2], args[3], args[4])
default:
    die("usage: coordcli selftest | gen <pdf> <lines.json> | truth <pdf> <lines.json> <truth.json> | convert <pdf> <elements.json> <predictions.json>")
}
