// swift-tools-version: 5.9
// 在 Mac（CI）上實際跑一次 App 的處理流程：解碼（含範圍）→ 分析 → WhisperKit 辨識 → 標記。
// App 的 MediaIO.swift／Transcriber.swift 由 CI 複製進來，確保測的是同一份程式碼
import PackageDescription

let package = Package(
    name: "E2E",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", exact: "1.1.0"),
        .package(path: "../AutoCutCore"),
    ],
    targets: [
        .executableTarget(name: "E2E", dependencies: [
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
            .product(name: "AutoCutCore", package: "AutoCutCore"),
        ]),
    ]
)
