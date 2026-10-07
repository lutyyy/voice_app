import BackgroundTasks
import UIKit
import UserNotifications

/// 處理期間切到背景時盡量繼續執行，完成後發通知。
/// - iOS 26 起：用「持續處理」背景工作（系統會顯示進度，可能因為電量或溫度提早停止）
/// - 較舊的 iOS：只有切出去後約 30 秒的寬限時間，之後暫停，回到 App 會接著做
@MainActor
final class BackgroundWork {
    static let shared = BackgroundWork()

    private var graceID: UIBackgroundTaskIdentifier = .invalid
    /// BGContinuedProcessingTask（iOS 26+）；用 AnyObject 存，舊系統才能編譯
    private var continued: AnyObject?
    private var registered: String?
    private var title = ""
    private var subtitle = ""
    private var fraction = 0.0
    private var ticker: Timer?
    /// 目前有沒有工作在跑（系統可能在工作結束後才啟動背景工作）
    private var active = false
    /// 同時在跑的工作數（例如預先下載模型時又開始處理專案）
    private var users = 0

    /// 開始一段工作（使用者按下按鈕時呼叫，App 在前景）
    func begin(title: String) {
        users += 1
        self.title = title
        active = true
        if users == 1 {
            subtitle = ""
            fraction = 0
        }
        askNotificationPermission()
        if graceID == .invalid {
            graceID = UIApplication.shared.beginBackgroundTask(withName: "VoiceCut") { [weak self] in
                MainActor.assumeIsolated { self?.endGrace() }
            }
        }
        if #available(iOS 26.0, *) { submitContinued() }
    }

    /// 回報整體進度（0～1）與目前步驟
    func update(_ fraction: Double?, step: String) {
        if let f = fraction, f.isFinite { self.fraction = max(self.fraction, min(0.99, f)) }
        if !step.isEmpty { subtitle = step }
        if #available(iOS 26.0, *) { pushProgress() }
    }

    /// 工作結束；在背景時發通知
    func end(success: Bool, message: String, title doneTitle: String? = nil) {
        if UIApplication.shared.applicationState != .active {
            let t = doneTitle ?? title
            notify(title: success ? "\(t)：完成" : t, body: message)
        }
        users = max(0, users - 1)
        guard users == 0 else { return }
        active = false
        if #available(iOS 26.0, *) { finishContinued(success) }
        endGrace()
    }

    private func endGrace() {
        if graceID != .invalid {
            UIApplication.shared.endBackgroundTask(graceID)
            graceID = .invalid
        }
    }

    // MARK: - 通知

    private func askNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: - iOS 26 持續處理

    /// Info.plist 允許的識別碼。SideStore 重新簽章時會改 bundle ID，所以兩種都試
    private var identifiers: [String] {
        var out = [String]()
        if let b = Bundle.main.bundleIdentifier { out.append(b + ".process") }
        out.append("com.lutyyy.voicecut.process")
        return Array(Set(out))
    }

    @available(iOS 26.0, *)
    private func submitContinued() {
        guard continued == nil else { return }
        for id in identifiers {
            if registered != id {
                var ok = false
                // 識別碼不在 Info.plist 或重複註冊時系統會丟例外，包起來避免閃退
                let fine = VCTry {
                    ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { @Sendable task in
                        MainActor.assumeIsolated { BackgroundWork.shared.started(task) }
                    }
                }
                guard fine, ok else { continue }
                registered = id
            }
            let req = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: "處理中…")
            req.strategy = .fail
            var submitted = false
            _ = VCTry {
                do {
                    try BGTaskScheduler.shared.submit(req)
                    submitted = true
                } catch {}
            }
            if submitted { return }
        }
    }

    @available(iOS 26.0, *)
    private func started(_ task: BGTask) {
        guard let t = task as? BGContinuedProcessingTask, active else {
            task.setTaskCompleted(success: true)
            return
        }
        continued = t
        t.progress.totalUnitCount = 1000
        t.expirationHandler = { @Sendable in
            // 系統要收回時：結束背景工作；處理本身會在 App 回到前景後繼續
            Task { @MainActor in BackgroundWork.shared.finishContinued(false) }
        }
        pushProgress()
        // 模型最佳化等步驟沒有進度可報，定時推一點點，系統才不會以為卡住
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let b = BackgroundWork.shared
                b.fraction = min(0.99, b.fraction + 0.001)
                b.pushProgress()
            }
        }
    }

    @available(iOS 26.0, *)
    private func pushProgress() {
        guard let t = continued as? BGContinuedProcessingTask else { return }
        t.progress.completedUnitCount = max(t.progress.completedUnitCount, Int64(fraction * 1000))
        t.updateTitle(title, subtitle: subtitle.isEmpty ? "處理中…" : subtitle)
    }

    @available(iOS 26.0, *)
    private func finishContinued(_ success: Bool) {
        ticker?.invalidate()
        ticker = nil
        guard let t = continued as? BGContinuedProcessingTask else { return }
        if success { t.progress.completedUnitCount = t.progress.totalUnitCount }
        t.setTaskCompleted(success: success)
        continued = nil
    }
}
