import SwiftUI

/// 深色創作者風：主要按鈕是亮色膠囊、黑字；卡片是淡淡的灰底
struct PillButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        Pill(configuration: configuration, prominent: prominent)
    }

    private struct Pill: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .foregroundStyle(prominent ? Color.black : Color.primary)
                .background(prominent ? Color.accentColor : Color.white.opacity(0.12), in: Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        }
    }
}

/// 不是按鈕的地方（例如選單的標籤）也要長得像膠囊
struct PillLabel: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .foregroundStyle(.black)
            .background(Color.accentColor, in: Capsule())
            .shadow(color: Color.accentColor.opacity(0.35), radius: 12, y: 4)
    }
}

extension View {
    /// 灰底圓角卡片
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
    }
}
