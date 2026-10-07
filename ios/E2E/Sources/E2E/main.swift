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

print("簡轉繁:", Transcriber.traditional("数位转型后，效率提升了很多"))
if Transcriber.traditional("数位转型") != "數位轉型" { fail("簡轉繁沒有作用") }
let peaks = try await MediaIO.peaks(url, duration: try await MediaIO.info(url).duration, bins: 320)
print("peaks:", peaks.count)
if peaks.isEmpty { fail("聲波是空的") }

let audio = try await MediaIO.decode16k(url, range: range)
print("16k samples \(audio.count) = \(Double(audio.count) / 16000) s")
if audio.isEmpty { fail("16k 解碼是空的") }
let peak = audio.map(abs).max() ?? 0
let rms = (audio.reduce(0) { $0 + $1 * $1 } / Float(audio.count)).squareRoot()
print("16k peak \(peak), rms \(rms), nan \(audio.contains { $0.isNaN })")
if peak < 0.001 || peak > 100 { fail("16k 音訊數值異常") }
if let r = range {
    // 只解碼一段：長度要對，內容要跟整檔解碼的同一段一樣（確認真的有照範圍切，不是從頭開始）
    if abs(Double(audio.count) / 16000 - r.length) > 0.1 { fail("範圍解碼長度不符") }
    let whole = try await MediaIO.decode16k(url)
    let off = Int(r.start * 16000)
    let n = min(audio.count, whole.count - off)
    var dot: Float = 0, aa: Float = 0, bb: Float = 0
    for i in 0..<n { dot += audio[i] * whole[off + i]; aa += audio[i] * audio[i]; bb += whole[off + i] * whole[off + i] }
    let corr = dot / max(1e-9, (aa * bb).squareRoot())
    print("範圍內容與整檔同段的相關係數 \(corr)")
    if corr < 0.9 { fail("範圍解碼的內容不是選取的那段") }
}

let t0 = Date()
var lastStatus = ""
try await Transcriber.shared.load(model: model) { _, s in
    if s != lastStatus { lastStatus = s; print(s) }
}
print("model loaded in \(Int(Date().timeIntervalSince(t0))) s")
let userPrompt = ProcessInfo.processInfo.environment["E2E_PROMPT"]
let words = try await Transcriber.shared.transcribe(audio, prompt: userPrompt, progress: { _ in },
                                                    onText: { print("  live:", $0) })
print("words:", words.count)
print("text:", words.map(\.text).joined())
if let f = words.first, let l = words.last { print("time \(f.start) – \(l.end)") }
if words.isEmpty || CommandLine.arguments.contains("--diag") {
    // 診斷：同樣的音訊用不同解碼選項跑，找出是哪個選項讓結果變空
    let folder = try await WhisperKit.download(variant: model)
    // 全部用 CPU：CI 的虛擬機沒有真的神經網路引擎／GPU，用來分辨是環境還是設定的問題
    let cpu = ProcessInfo.processInfo.environment["E2E_DEFAULT_COMPUTE"] != nil
        ? ModelComputeOptions()
        : ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly, textDecoderCompute: .cpuOnly)
    let pipe = try await WhisperKit(WhisperKitConfig(model: model, modelFolder: folder.path, computeOptions: cpu, verbose: false,
                                                     logLevel: .error, prewarm: false, load: true, download: false))
    print("diagnostic pipe:", cpu.melCompute.rawValue, cpu.audioEncoderCompute.rawValue, cpu.textDecoderCompute.rawValue)
    let tok = pipe.tokenizer!
    let prompt = tok.encode(text: " 嗯，這個，呃，就是說，我們今天，然後，那個，欸，對，我覺得啊，喔。").filter { $0 < tok.specialTokens.specialTokenBegin }
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
let joined = words.map(\.text).joined()
if model.contains("large"), range == nil {
    // Turbo 應該輸出繁體、抓到語助詞
    for k in ["數位轉型", "產品"] where !joined.contains(k) { fail("逐字稿缺少「\(k)」") }
    if !joined.contains("嗯") && !joined.contains("呃") { fail("沒有抓到語助詞") }
}
if let l = words.last, l.end > info.duration + 1 { fail("字的時間超出範圍長度") }

let plan = Planner.plan(words, speech: analysis.speech, options: PlanOptions())
let s = Planner.summary(plan)
print("plan: \(plan.count) rows, fillers \(s.fillers), repeats \(s.repeats), review \(s.review)")
print("✅ OK")
