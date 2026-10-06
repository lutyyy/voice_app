import Foundation
import XCTest
@testable import AutoCutCore

final class CoreTests: XCTestCase {
    func testMD5() {
        XCTAssertEqual(MD5.hex(Array("".utf8)), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(MD5.hex(Array("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(MD5.hex(Array(String(repeating: "x", count: 200).utf8)).count, 32)
    }

    func testNorm() {
        XCTAssertEqual(TextRules.norm("好， "), "好")
        XCTAssertEqual(TextRules.norm("Um!"), "um")
        XCTAssertTrue(TextRules.endsWithPunct("產業。"))
        XCTAssertFalse(TextRules.endsWithPunct("產業"))
        XCTAssertTrue(TextRules.isHallucination("請訂閱我的頻道"))
    }

    func testStutterAndRedup() {
        var t = 0.0
        func w(_ s: String, _ gap: Double = 0.02) -> Word {
            defer { t += 0.2 + gap }
            return Word(seg: 0, start: t, end: t + 0.2, text: s)
        }
        let ws = [w("謝"), w("謝"), w("我們"), w("我們"), w("你"), w("你")]
        let p = Planner.plan(ws, speech: nil)
        XCTAssertEqual(p.map(\.action), [.keep, .keep, .cut, .keep, .cut, .keep])
    }

    func testDeletes() throws {
        var t = 0.0
        var ws: [Word] = []
        for (i, s) in ["然後", "我們", "開始。", "這個", "東西"].enumerated() {
            ws.append(Word(seg: i < 3 ? 0 : 1, start: t, end: t + 0.2, text: s))
            t += 0.3
        }
        let plan = Planner.plan(ws, speech: nil)
        XCTAssertEqual(plan.filter { $0.action == .review }.map(\.rid), [1, 2])
        let code = Review.planCode(plan)
        let d = try Review.parseDeletes("版本碼 \(code)\nS001 講錯重講\nR001～R002\n# R009 保留\n", words: plan)
        XCTAssertEqual(d.sentences, [1])
        XCTAssertEqual(d.reviews, [1, 2])
        XCTAssertFalse(d.missingCode)
        let out = Review.decide(plan, deletes: d, cutReview: false)
        XCTAssertEqual(out.map(\.action), [.cut, .keep, .keep, .cut, .cut])

        XCTAssertThrowsError(try Review.parseDeletes("版本碼 000000\nS001", words: plan))
        XCTAssertTrue(try Review.parseDeletes("S001", words: plan).missingCode)
    }

    func testFFTRoundTrip() {
        let x = (0..<64).map { sin(Double($0) * 0.3) + 0.1 * Double($0 % 5) }
        let (re, im) = FFT.rfft(x)
        let y = FFT.irfft(re, im, n: 64)
        for (a, b) in zip(x, y) { XCTAssertEqual(a, b, accuracy: 1e-9) }
        // 純弦波的能量集中在對應頻率
        let s = (0..<256).map { sin(2 * Double.pi * 8 * Double($0) / 256) }
        let (r2, i2) = FFT.rfft(s)
        let mag = zip(r2, i2).map { sqrt($0 * $0 + $1 * $1) }
        XCTAssertEqual(mag.firstIndex(of: mag.max()!), 8)
    }

    func testNoiseLevel() {
        let prof = NoiseProfile(psd: [Double](repeating: 1, count: 513), rms: 0.01)
        let y = makeNoise(5000, prof, seed: 3)
        XCTAssertEqual(y.count, 5000)
        let rms = sqrt(y.map { Double($0 * $0) }.reduce(0, +) / 5000)
        XCTAssertEqual(rms, 0.01, accuracy: 1e-4)
        XCTAssertEqual(makeNoise(100, prof, seed: 3), makeNoise(100, prof, seed: 3))
    }

    /// 合成一段「說話-停頓-說話」的音訊，確認輸出長度＝片段長度總和（交叉淡化不改變長度）、長停頓被壓縮
    func testRenderEndToEnd() throws {
        let sr = 16000
        var x = [Float](repeating: 0, count: sr * 4)
        var rng = SeededRandom(seed: 1)
        for i in x.indices { x[i] = Float(rng.normal()) * 0.0005 }
        for i in 0..<(sr) { x[i] += 0.3 * Float(sin(Double(i) * 0.2)) }                // 0～1 秒：說話
        for i in (2 * sr)..<(3 * sr) { x[i] += 0.3 * Float(sin(Double(i) * 0.25)) }    // 2～3 秒：說話
        let src = ArrayPCM(samples: x, sampleRate: sr)
        let a = Analysis(src: src)
        XCTAssertEqual(a.speech.count, 2)
        XCTAssertNotNil(a.noise)
        let words = [Word(seg: 0, start: 0, end: 1, text: "我們。"), Word(seg: 1, start: 2, end: 3, text: "開始")]
        let o = RenderOptions()
        let gain = Renderer.breathGain(a, keepWords: words, margin: o.breathMargin, maxCut: o.breathCut)
        let segs = try Renderer.segments(words, analysis: a, duration: src.duration, options: o, fps: nil, gain: gain)
        XCTAssertGreaterThanOrEqual(segs.count, 2)
        var out: [Float] = []
        let secs = try Renderer.synthesize(src, segs: segs, analysis: a, gain: gain, options: o) { out += $0 }
        XCTAssertEqual(out.count, segs.map { pyRound($0.end * 16000) - pyRound($0.start * 16000) }.reduce(0, +))
        XCTAssertEqual(secs, Double(out.count) / 16000, accuracy: 1e-9)
        // 原本 1 秒的停頓壓到 0.3 秒左右；開頭不留空白、結尾最多 0.4 秒
        XCTAssertLessThan(secs, 2.8)
        XCTAssertGreaterThan(secs, 2.1)
        XCTAssertTrue(out.allSatisfy { abs($0) <= 1 })
    }

    func testVideoSegmentsAlignToFrames() throws {
        let sr = 16000
        var x = [Float](repeating: 0.0005, count: sr * 3)
        for i in 0..<sr { x[i] = 0.3 * Float(sin(Double(i) * 0.2)) }
        for i in (2 * sr)..<(3 * sr) { x[i] = 0.3 * Float(sin(Double(i) * 0.2)) }
        let src = ArrayPCM(samples: x, sampleRate: sr)
        let a = Analysis(src: src)
        let words = [Word(seg: 0, start: 0, end: 1, text: "好"), Word(seg: 0, start: 2, end: 3, text: "的")]
        let gain = [Float](repeating: 1, count: a.E.count)
        let fps = 30000.0 / 1001
        let segs = try Renderer.segments(words, analysis: a, duration: src.duration, options: RenderOptions(), fps: fps, gain: gain)
        XCTAssertTrue(segs.allSatisfy { $0.kind == .src })
        for s in segs {
            XCTAssertEqual(s.start * fps, (s.start * fps).rounded(), accuracy: 1e-6)
            XCTAssertEqual(s.end * fps, (s.end * fps).rounded(), accuracy: 1e-6)
        }
    }

    func testToSourceAndRefineMerge() {
        let segs = [Seg(0, 1, .src), Seg(0, 0.1, .noise), Seg(2, 3, .src)]
        let ts = Renderer.toSource(segs, 0.9, 1.3)
        XCTAssertEqual(ts.count, 2)
        for (g, w) in zip(ts, [Span(0.9, 1.0), Span(2.0, 2.2)]) {
            XCTAssertEqual(g.start, w.start, accuracy: 1e-9)
            XCTAssertEqual(g.end, w.end, accuracy: 1e-9)
        }

        var raw = [Word(seg: 0, start: 0, end: 0.5, text: "我們"), Word(seg: 0, start: 2.0, end: 2.6, text: "開始")]
        // 成品 1.1～1.2 秒 → 原檔 2.0～2.1：與「開始」重疊但只佔 1/6，可修短
        let found = Refiner.findResidual([Word(seg: 0, start: 1.1, end: 1.2, text: "嗯", prob: 0.9)],
                                         speechOut: [Span(1.0, 1.5)])
        XCTAssertEqual(found.count, 1)
        let added = Refiner.merge(found, segs: segs, into: &raw, round: 1)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(raw.count, 3)
        XCTAssertEqual(raw[1].action, .cut)
        XCTAssertEqual(raw[2].start, 2.1, accuracy: 1e-9)
        // 同一處不重複新增
        XCTAssertEqual(Refiner.merge(found, segs: segs, into: &raw, round: 2), 0)
    }

    func testOverview() {
        let E: [Float] = [-60, -60, -20, -40, -60, -60, -30, -60]
        let a = Analysis(sampleRate: 200, hop: 1, E: E, floor: -60, speech: [])
        let o = a.overview(bins: 4)
        XCTAssertEqual(o.count, 4)
        XCTAssertEqual(o[0], 0, accuracy: 1e-6)
        XCTAssertEqual(o[1], 1, accuracy: 1e-6)
        XCTAssertEqual(o[3], 0.75, accuracy: 1e-6)
        XCTAssertEqual(a.overview(bins: 20).count, 20)
    }

    func testPresets() throws {
        XCTAssertEqual(CutPreset.matching(CutSettings()), .standard)
        for p in CutPreset.allCases {
            XCTAssertEqual(CutPreset.matching(p.settings), p)
            XCTAssertEqual(p.settings.sanitized, p.settings, "\(p) 的參數應該彼此一致")
        }
        var s = CutPreset.natural.settings
        s.render.keepPause += 0.01
        XCTAssertNil(CutPreset.matching(s))
        s.render.maxPause = 0.1
        XCTAssertEqual(s.sanitized.render.maxPause, s.render.keepPause)
        let data = try JSONEncoder().encode(CutPreset.compact.settings)
        XCTAssertEqual(try JSONDecoder().decode(CutSettings.self, from: data), CutPreset.compact.settings)
    }

    /// 同一份音訊：精簡 < 標準 < 自然
    func testPresetsOrderOutputLength() throws {
        let sr = 16000
        var x = [Float](repeating: 0, count: sr * 6)
        var rng = SeededRandom(seed: 3)
        for i in x.indices { x[i] = Float(rng.normal()) * 0.002 }
        let talk: [(Double, Double)] = [(0.3, 1.5), (2.5, 3.6), (4.4, 5.6)]
        for (a, b) in talk {
            for i in Int(a * Double(sr))..<Int(b * Double(sr)) { x[i] += 0.3 * sinf(Float(i) * 0.06) }
        }
        let src = ArrayPCM(samples: x, sampleRate: sr)
        let an = Analysis(src: src)
        let words = talk.enumerated().map { k, t in Word(seg: k, start: t.0, end: t.1, text: "好") }
        func length(_ p: CutPreset) throws -> Double {
            let gain = [Float](repeating: 1, count: an.E.count)
            return try Renderer.segments(words, analysis: an, duration: 6, options: p.settings.render, fps: nil, gain: gain)
                .reduce(0) { $0 + $1.length }
        }
        let n = try length(.natural), s = try length(.standard), c = try length(.compact)
        XCTAssertLessThan(c, s)
        XCTAssertLessThan(s, n)
    }

    func testToOutput() {
        let segs = [Seg(0, 1, .src), Seg(0, 0.2, .noise), Seg(2, 3, .src)]
        XCTAssertEqual(Renderer.toOutput(segs, 0.5)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(Renderer.toOutput(segs, 1.5)!, 1.2, accuracy: 1e-9)  // 被剪掉 → 接點
        XCTAssertEqual(Renderer.toOutput(segs, 2.5)!, 1.7, accuracy: 1e-9)
        XCTAssertNil(Renderer.toOutput(segs, 3.5))
        for t in [0.25, 2.25, 2.9] {
            let o = Renderer.toOutput(segs, t)!
            XCTAssertEqual(Renderer.toSource(segs, o, o + 0.01).first!.start, t, accuracy: 1e-9)
        }
    }

    func testUncoveredSpeech() {
        let ws = [Word(seg: 0, start: 1.0, end: 1.5, text: "好")]
        let gaps = Planner.uncoveredSpeech(words: ws, speech: [Span(0.5, 2.0)])
        XCTAssertEqual(gaps, [Span(0.5, 1.0), Span(1.5, 2.0)])
    }
}
