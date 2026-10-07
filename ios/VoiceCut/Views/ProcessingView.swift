import SwiftUI

/// 處理中的畫面：聲波掃描動畫、步驟清單、即時逐字稿、預估剩餘時間
struct ProcessingCard: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                AnimatedDotsTitle(text: title)
                Spacer()
                if let p = model.progress {
                    Text("\(Int(p * 100))%")
                        .font(.subheadline.monospacedDigit().bold())
                        .foregroundStyle(.tint)
                        .contentTransition(.numericText())
                        .animation(.default, value: Int(p * 100))
                }
            }

            WaveformScan(samples: model.waveform, progress: model.progress)
                .frame(height: 72)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.step).font(.subheadline)
                TimelineView(.periodic(from: model.stepStarted, by: 1)) { ctx in
                    Text(timing(ctx.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if !model.liveLines.isEmpty {
                LiveTranscript(lines: model.liveLines)
            }

            if !model.steps.isEmpty {
                StepList(steps: model.steps)
            }

            if Transcriber.isOptimizing(model.step) {
                Text(optimizeNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("iOS 26 以上可以切到背景，完成會通知；較舊的 iOS 請保持在前景。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("取消", role: .destructive) { model.cancel() }
        }
        .padding(.vertical, 6)
    }

    private var title: String {
        switch model.steps.first(where: { $0.state == .running })?.id {
        case "decode", "analyze": return "聲波分析中"
        case "model": return model.step == Transcriber.downloading ? "下載辨識模型" : "準備辨識模型"
        case "asr", "gaps": return "聆聽並辨識中"
        case "plan": return "找出要剪的地方"
        case "claude": return "Claude 思考中"
        case "cut", "audio", "video": return "剪接輸出中"
        case let id? where id.hasPrefix("refine"): return "檢查成品中"
        default: return "處理中"
        }
    }

    /// 說清楚是在下載還是在最佳化，以及大概要多久
    private var optimizeNote: String {
        var s = model.step == Transcriber.optimizing
            ? "模型已下載完成，iPhone 正在把它最佳化給神經網路引擎，第一次約需 2～10 分鐘，期間進度可能不動。"
            : "模型檔已在手機上，沒有重新下載。剛更新 App 或重新開機後，iOS 可能要重新最佳化一次（這是系統的規定，App 無法跳過）；沒有的話幾秒就好。"
        if let last = Transcriber.lastOptimizeSeconds(AppSettings.shared.resolvedModel) {
            s += "上次花了約 " + ProjectModel.clock(last) + "。"
        }
        return s
    }

    private func timing(_ now: Date) -> String {
        var s = "已經過 " + ProjectModel.clock(now.timeIntervalSince(model.stepStarted))
        if let eta = model.eta(at: now) {
            s += eta < 60 ? " · 預估還要不到 1 分鐘" : " · 預估還要約 " + ProjectModel.clock(eta)
        }
        return s
    }
}

/// 標題後面跟著跳動的「…」
private struct AnimatedDotsTitle: View {
    let text: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.45)) { ctx in
            let n = Int(ctx.date.timeIntervalSinceReferenceDate / 0.45) % 4
            Text(text + String(repeating: "．", count: n))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 聲波掃描動畫：有聲波概覽時畫真實聲波，掃描線跟著進度移動；還沒有時畫跳動的波浪
struct WaveformScan: View {
    let samples: [Float]
    let progress: Double?

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { gc, size in
                draw(gc, size: size, t: ctx.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func draw(_ gc: GraphicsContext, size: CGSize, t: Double) {
        let real = !samples.isEmpty
        let n = real ? samples.count : 56
        let bw = size.width / CGFloat(n)
        let mid = size.height / 2
        // 掃描線位置：有進度就跟著進度，沒有就來回掃
        let head: Double
        if let p = progress {
            head = p
        } else {
            let ph = (t * 0.35).truncatingRemainder(dividingBy: 1)
            head = ph < 0.5 ? ph * 2 : 2 - ph * 2
        }
        let accent = Color.accentColor
        for i in 0..<n {
            let f = (Double(i) + 0.5) / Double(n)
            let near = max(0, 1 - abs(f - head) * 10)
            var amp: Double
            if real {
                amp = 0.06 + 0.94 * Double(samples[i])
                amp *= 1 + 0.18 * near * sin(t * 14 + Double(i) * 0.9)
            } else {
                let base = 0.55 + 0.45 * sin(Double(i) * 1.7 + 0.6)
                amp = 0.12 + 0.75 * abs(sin(t * 2.6 + Double(i) * 0.42)) * base
            }
            let h = max(2, CGFloat(min(1, amp)) * size.height * 0.94)
            let rect = CGRect(x: CGFloat(i) * bw + bw * 0.18, y: mid - h / 2, width: max(1, bw * 0.64), height: h)
            let done = progress.map { f <= $0 } ?? false
            let color: Color = done ? accent : (near > 0 ? accent.opacity(0.25 + 0.6 * near) : Color.secondary.opacity(0.3))
            gc.fill(Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2), with: .color(color))
        }
        // 掃描線與光暈
        let x = size.width * CGFloat(min(1, max(0, head)))
        let glow = CGRect(x: x - 18, y: 0, width: 36, height: size.height)
        gc.fill(Path(glow), with: .linearGradient(
            Gradient(colors: [accent.opacity(0), accent.opacity(0.18), accent.opacity(0)]),
            startPoint: CGPoint(x: glow.minX, y: 0), endPoint: CGPoint(x: glow.maxX, y: 0)))
        gc.fill(Path(roundedRect: CGRect(x: x - 1, y: 0, width: 2, height: size.height), cornerRadius: 1),
                with: .color(accent))
    }
}

/// 辨識中即時出現的句子，最新一句最清楚
private struct LiveTranscript: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.suffix(3).enumerated()), id: \.element) { k, line in
                let age = min(lines.count, 3) - 1 - k
                Text(line)
                    .font(age == 0 ? .callout : .footnote)
                    .foregroundStyle(age == 0 ? Color.primary : Color.secondary.opacity(age == 1 ? 0.9 : 0.55))
                    .lineLimit(2)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .animation(.easeOut(duration: 0.35), value: lines)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("即時逐字稿：" + (lines.last ?? ""))
    }
}

/// 步驟清單：完成打勾、進行中轉圈、還沒開始是空心圓
private struct StepList: View {
    let steps: [PipelineStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(steps) { s in
                HStack(spacing: 10) {
                    icon(s)
                        .frame(width: 20)
                    Text(s.title)
                        .font(.subheadline)
                        .foregroundStyle(s.state == .pending ? .secondary : .primary)
                    Spacer()
                    duration(s)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(s.title + "，" + label(s.state))
            }
        }
        .animation(.spring(duration: 0.35), value: steps)
    }

    @ViewBuilder
    private func icon(_ s: PipelineStep) -> some View {
        switch s.state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .running:
            ProgressView().controlSize(.small)
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func duration(_ s: PipelineStep) -> some View {
        if s.state == .done, let a = s.started, let b = s.finished {
            Text(short(b.timeIntervalSince(a)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        } else if s.state == .running, let a = s.started {
            TimelineView(.periodic(from: a, by: 1)) { ctx in
                Text(short(ctx.date.timeIntervalSince(a)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tint)
            }
        }
    }

    private func short(_ t: Double) -> String {
        t < 60 ? "\(max(0, Int(t))) 秒" : ProjectModel.clock(t)
    }

    private func label(_ s: PipelineStep.State) -> String {
        switch s {
        case .done: return "完成"
        case .running: return "進行中"
        case .pending: return "等待中"
        }
    }
}
