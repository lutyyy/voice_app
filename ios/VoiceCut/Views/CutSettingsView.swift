import AutoCutCore
import SwiftUI

/// 剪輯風格選擇（自然／標準／精簡；改過參數時顯示「自訂」）
struct PresetPicker: View {
    @EnvironmentObject private var settings: AppSettings
    /// 有給的話一直顯示「自訂」，點了就呼叫（打開微調頁）
    var onCustom: (() -> Void)?

    var body: some View {
        Picker("剪輯風格", selection: Binding(
            get: { settings.preset?.rawValue ?? "custom" },
            set: { v in
                if let p = CutPreset(rawValue: v) { settings.apply(p) } else { onCustom?() }
            })) {
            ForEach(CutPreset.allCases) { Text($0.name).tag($0.rawValue) }
            if settings.preset == nil || onCustom != nil { Text("自訂").tag("custom") }
        }
        .pickerStyle(.segmented)
    }
}

/// 處理速度選擇；這支手機跑不動的等級會先警告
struct SpeedPicker: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var pending: SpeedTier?
    /// 有給的話一直顯示「自訂」，點了就呼叫（打開微調頁）
    var onCustom: (() -> Void)?

    var body: some View {
        Picker("處理速度", selection: Binding(
            get: { settings.speed?.rawValue ?? "custom" },
            set: { v in
                guard let t = SpeedTier(rawValue: v) else {
                    onCustom?()
                    return
                }
                if t.warning != nil { pending = t } else { settings.apply(t) }
            })) {
            ForEach(SpeedTier.allCases) { t in
                Text(t.warning == nil ? t.name : t.name + " ⚠︎").tag(t.rawValue)
            }
            if settings.speed == nil || onCustom != nil { Text("自訂").tag("custom") }
        }
        .pickerStyle(.segmented)
        .alert("這支 iPhone 可能跑不動", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { t in
            Button("仍要使用「\(t.name)」", role: .destructive) { settings.apply(t) }
            Button("改用「\(SpeedTier.recommended.name)」") { settings.apply(SpeedTier.recommended) }
            Button("取消", role: .cancel) {}
        } message: { t in
            Text(t.warning ?? "")
        }
    }
}

/// 全部剪輯參數；套用預設後可以再微調
struct CutSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                PresetPicker()
                Text(settings.preset?.note ?? "已依你的需要調整過參數。點上方的風格可以還原成該預設。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("從預設開始")
            }

            Section {
                ParamSlider(title: "超過多久的停頓要壓縮", value: bind(\.render.maxPause), range: 0.15...1.2, step: 0.05, unit: "秒")
                ParamSlider(title: "壓縮後保留", value: bind(\.render.keepPause), range: 0.05...0.6, step: 0.01, unit: "秒")
                ParamSlider(title: "句與句之間至少留", value: bind(\.render.minGapSentence), range: 0...0.4, step: 0.01, unit: "秒")
                ParamSlider(title: "句子中間剪接處至少留", value: bind(\.render.minGapPhrase), range: 0...0.15, step: 0.01, unit: "秒")
            } header: {
                Text("停頓")
            } footer: {
                Text("停頓越短，成品越緊湊；太短會像喘不過氣。剪接後停頓不夠長時，會補上環境底噪。")
            }

            Section {
                Toggle("修剪拖長的字", isOn: Binding(
                    get: { settings.cut.plan.maxChar > 0 },
                    set: { on in
                        var c = settings.cut
                        c.plan.maxChar = on ? max(0.3, CutPreset.standard.settings.plan.maxChar) : 0
                        settings.cut = c
                    }))
                if settings.cut.plan.maxChar > 0 {
                    ParamSlider(title: "一個字超過多久算拖音", value: bind(\.plan.maxChar), range: 0.3...1.5, step: 0.05, unit: "秒")
                    ParamSlider(title: "拖音字保留", value: bind(\.plan.trimTo), range: 0.2...1.0, step: 0.05, unit: "秒")
                }
                Toggle("疑似贅詞全部剪掉（沒有 Claude 判斷時）", isOn: $settings.cutReview)
            } header: {
                Text("標記")
            } footer: {
                Text("拖音例如「然後～～」拖很長，只保留開頭。疑似贅詞是「然後、就是、那個」等，可能是內容也可能是口頭禪。改了拖音設定後，下次輸出會重新標記（手動改過的字會保留）。")
            }

            Section {
                ParamSlider(title: "太短的剪接不剪（少於）", value: bind(\.render.minCut), range: 0...0.4, step: 0.01, unit: "秒")
                ParamSlider(title: "剪接點往安靜處對齊的範圍", value: bind(\.render.snap), range: 0...0.1, step: 0.005, unit: "秒")
                ParamSlider(title: "交叉淡化", value: bind(\.render.xfade), range: 0.005...0.08, step: 0.005, unit: "秒")
                ParamSlider(title: "剪在有聲音處的淡化", value: bind(\.render.xfadeLong), range: 0.01...0.15, step: 0.005, unit: "秒")
            } header: {
                Text("剪接點")
            } footer: {
                Text("淡化越長接得越順，但太長會吃掉字頭字尾。")
            }

            Section {
                ParamSlider(title: "呼吸聲最多壓低（0 = 不處理）", value: bind(\.render.breathCut), range: 0...30, step: 1, unit: "dB")
                ParamSlider(title: "停頓中高出底噪多少算呼吸聲", value: bind(\.render.breathMargin), range: 3...15, step: 1, unit: "dB")
                ParamSlider(title: "高出底噪多少以內算安靜", value: bind(\.render.quietDb), range: 6...20, step: 1, unit: "dB")
                Toggle("停頓太短時補環境底噪", isOn: bind(\.render.roomtone))
            } header: {
                Text("呼吸聲與底噪")
            } footer: {
                Text("影片不補底噪（畫面要對齊）。")
            }
        }
        .navigationTitle("剪輯參數")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bind<T>(_ kp: WritableKeyPath<CutSettings, T>) -> Binding<T> {
        Binding(get: { settings.cut[keyPath: kp] },
                set: { v in
                    var c = settings.cut
                    c[keyPath: kp] = v
                    settings.cut = c
                })
    }
}

/// 一個參數的滑桿：標題、目前值、單位
private struct ParamSlider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    let title: String
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V.Stride
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(formatted).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { value = $0 }),
                   in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(formatted)
        }
    }

    private var formatted: String {
        let v = Double(value)
        if unit == "dB" { return String(format: "%.0f dB", v) }
        return String(format: v < 0.1 && v > 0 ? "%.3f 秒" : "%.2f 秒", v)
    }
}
