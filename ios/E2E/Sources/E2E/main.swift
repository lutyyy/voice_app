import AutoCutCore
import Foundation
import WhisperKit

// 用法：E2E <音檔> <模型> [開始秒 結束秒]
let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1])
let model = args[2]
let range = args.count >= 5 ? ClipRange(start: Double(args[3])!, end: Double(args[4])!) : nil

func fail(_ s: String) -> Never {
    print("❌ " + s)
    exit(1)
}

var info = try await MediaIO.info(url)
print("info:", info)
if let r = range { info.duration = min(info.duration, r.end) - r.start }

let raw = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pcm-\(UUID()).f32")
try await MediaIO.decodeToFile(url, to: raw, sampleRate: info.sampleRate, channels: info.channels, range: range)
let size = (try FileManager.default.attributesOfItem(atPath: raw.path)[.size] as? Int) ?? 0
let expect = Int(info.duration * Double(info.sampleRate)) * info.channels * 4
print("pcm bytes \(size), expected \(expect)")
if size == 0 || abs(size - expect) > info.sampleRate * info.channels * 4 { fail("解碼長度不符") }
let src = try MappedPCM(url: raw, sampleRate: info.sampleRate, channels: info.channels)
let analysis = Analysis(src: src)
print("speech spans:", analysis.speech.count)

let peaks = try await MediaIO.peaks(url, duration: try await MediaIO.info(url).duration, bins: 320)
print("peaks:", peaks.count)
if peaks.isEmpty { fail("聲波是空的") }

let audio = try await MediaIO.decode16k(url, range: range)
print("16k samples \(audio.count) = \(Double(audio.count) / 16000) s")
if audio.isEmpty { fail("16k 解碼是空的") }

let t0 = Date()
try await Transcriber.shared.load(model: model) { p, s in if !p.isNaN { _ = p } else { print(s) } }
print("model loaded in \(Int(Date().timeIntervalSince(t0))) s")
let words = try await Transcriber.shared.transcribe(audio, prompt: Transcriber.defaultPrompt, progress: { _ in },
                                                    onText: { print("  live:", $0) })
print("words:", words.count)
print("text:", words.map(\.text).joined())
if let f = words.first, let l = words.last { print("time \(f.start) – \(l.end)") }
if words.isEmpty || CommandLine.arguments.contains("--diag") {
    // 診斷：同樣的音訊用不同解碼選項跑，找出是哪個選項讓結果變空
    let folder = try await WhisperKit.download(variant: model)
    let pipe = try await WhisperKit(WhisperKitConfig(model: model, modelFolder: folder.path, verbose: false, logLevel: .error,
                                                     prewarm: false, load: true, download: false))
    let tok = pipe.tokenizer!
    let prompt = tok.encode(text: " " + Transcriber.defaultPrompt).filter { $0 < tok.specialTokens.specialTokenBegin }
    let variants: [(String, DecodingOptions)] = [
        ("app", DecodingOptions(task: .transcribe, language: "zh", temperature: 0, usePrefillPrompt: true, skipSpecialTokens: true,
                                wordTimestamps: true, promptTokens: prompt, chunkingStrategy: .vad)),
        ("app,no-thresholds", DecodingOptions(task: .transcribe, language: "zh", temperature: 0, usePrefillPrompt: true,
                                skipSpecialTokens: true, wordTimestamps: true, promptTokens: prompt,
                                compressionRatioThreshold: nil, logProbThreshold: nil, firstTokenLogProbThreshold: nil,
                                noSpeechThreshold: nil, chunkingStrategy: .vad)),
        ("no-prompt", DecodingOptions(task: .transcribe, language: "zh", temperature: 0, usePrefillPrompt: true,
                                skipSpecialTokens: true, wordTimestamps: true, chunkingStrategy: .vad)),
        ("no-prompt,no-words", DecodingOptions(task: .transcribe, language: "zh", temperature: 0, usePrefillPrompt: true,
                                skipSpecialTokens: true, chunkingStrategy: .vad)),
        ("plain", DecodingOptions()),
    ]
    for (name, o) in variants {
        let r = try await pipe.transcribe(audioArray: audio, decodeOptions: o)
        let segs = r.flatMap(\.segments)
        let nw = segs.reduce(0) { $0 + ($1.words?.count ?? 0) }
        print("[\(name)] segments \(segs.count), words \(nw), text: \(segs.map(\.text).joined().prefix(200))")
        for sg in segs.prefix(3) { print("   seg \(sg.start)-\(sg.end) noSpeech \(sg.noSpeechProb) avgLogprob \(sg.avgLogprob) tokens \(sg.tokens.count)") }
    }
}
if words.isEmpty { fail("辨識出 0 個字") }
if let l = words.last, l.end > info.duration + 1 { fail("字的時間超出範圍長度") }

let plan = Planner.plan(words, speech: analysis.speech, options: PlanOptions())
let s = Planner.summary(plan)
print("plan: \(plan.count) rows, fillers \(s.fillers), repeats \(s.repeats), review \(s.review)")
print("✅ OK")
