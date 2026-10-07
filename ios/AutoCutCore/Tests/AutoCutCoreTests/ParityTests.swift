import Foundation
import XCTest
@testable import AutoCutCore

/// 與 autocut.py 的輸出逐項比對（Fixtures 由 Python 版本身產生）
final class ParityTests: XCTestCase {
    func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func words(_ arr: Any?) -> [Word] {
        (arr as! [[String: Any]]).map { d in
            var w = Word(seg: d["seg"] as! Int, start: (d["start"] as! NSNumber).doubleValue,
                         end: (d["end"] as! NSNumber).doubleValue, text: d["text"] as! String)
            w.prob = (d["prob"] as? NSNumber)?.doubleValue
            w.extra = d["extra"] as? Bool ?? false
            w.logprob = (d["logprob"] as? NSNumber)?.doubleValue
            w.misheard = d["misheard"] as? String
            if let a = d["action"] as? String { w.action = Action(rawValue: a)! }
            w.reason = d["reason"] as? String ?? ""
            if let r = d["rid"] as? String { w.rid = Int(r) ?? 0 }
            return w
        }
    }

    func spans(_ arr: Any?) -> [Span] {
        (arr as! [[NSNumber]]).map { Span($0[0].doubleValue, $0[1].doubleValue) }
    }

    func testPlanMatchesPython() throws {
        let f = try fixture("plan")
        let got = Planner.plan(words(f["words"]), speech: spans(f["speech"]))
        let want = words(f["plan"])
        XCTAssertEqual(got.count, want.count)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.text, w.text)
            XCTAssertEqual(g.seg, w.seg, g.text)
            XCTAssertEqual(g.start, w.start, accuracy: 1e-6, g.text)
            XCTAssertEqual(g.end, w.end, accuracy: 1e-6, g.text)
            XCTAssertEqual(g.action, w.action, g.text)
            XCTAssertEqual(g.reason, w.reason, g.text)
            XCTAssertEqual(g.rid, w.rid, g.text)
        }
    }

    func testSentencesMatchPython() throws {
        let f = try fixture("plan")
        let plan = words(f["plan"])
        XCTAssertEqual(Review.planCode(plan), f["code"] as? String)
        XCTAssertEqual(Review.sentencesText(plan), f["sentences"] as? String)
    }

    func testRenderPiecesMatchPython() throws {
        let f = try fixture("render")
        let E = (f["E"] as! [NSNumber]).map { $0.floatValue }
        let hopS = (f["hopS"] as! NSNumber).doubleValue
        let sr = 16000, hop = Int((hopS * Double(sr)).rounded())
        let a = Analysis(sampleRate: sr, hop: hop, E: E, floor: (f["floor"] as! NSNumber).floatValue,
                         speech: spans(f["speech"]))
        let duration = (f["duration"] as! NSNumber).doubleValue
        let plan = words(f["plan"])
        let o = RenderOptions()
        for c in f["cases"] as! [[String: Any]] {
            let video = c["video"] as! Bool
            let ws = Review.decide(plan, deletes: nil, cutReview: c["cutReview"] as! Bool)
            let gain = Renderer.breathGain(a, keepWords: ws.filter { $0.action == .keep },
                                           margin: o.breathMargin, maxCut: o.breathCut)
            let wantGain = (c["gain"] as! [NSNumber]).map { $0.floatValue }
            XCTAssertEqual(gain.count, wantGain.count)
            for (g, w) in zip(gain, wantGain) { XCTAssertEqual(g, w, accuracy: 1e-4) }

            let quiet = E.indices.map { E[$0] + 20 * log10(gain[$0] + 1e-9) < a.floor + o.quietDb }
            let p1 = try Renderer.planPieces(ws, o, duration: duration)
            assertPieces(p1, c["pieces"], third: .boundary)
            let p2 = Renderer.snapPieces(p1, E: E, hopS: hopS, win: o.snap)
            assertPieces(p2, c["snapped"], third: .boundary)
            let p3 = Renderer.shapeSilence(p2, quiet: quiet, hopS: hopS, o, video: video)
            assertPieces(p3, c["shaped"], third: .fill)
        }
    }

    func num(_ x: Any) -> Double {
        if let b = x as? Bool, !(x is Int), !(x is Double) { return b ? 1 : 0 }
        if let n = x as? NSNumber { return n.doubleValue }
        if let d = x as? Double { return d }
        if let i = x as? Int { return Double(i) }
        return .nan
    }

    enum Third { case boundary, fill }

    func assertPieces(_ got: [Piece], _ want: Any?, third: Third, line: UInt = #line) {
        let want = want as! [[Any]]
        XCTAssertEqual(got.count, want.count, line: line)
        for (g, w) in zip(got, want) {
            XCTAssertEqual(g.start, num(w[0]), accuracy: 1e-6, line: line)
            XCTAssertEqual(g.end, num(w[1]), accuracy: 1e-6, line: line)
            switch third {
            case .boundary: XCTAssertEqual(g.boundary, num(w[2]) != 0, line: line)
            case .fill: XCTAssertEqual(g.fill, num(w[2]), accuracy: 1e-6, line: line)
            }
        }
    }
}
