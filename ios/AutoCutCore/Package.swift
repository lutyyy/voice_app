// swift-tools-version: 5.9
// autocut.py 的剪輯邏輯（標記、剪接點、停頓、交叉淡化）移植成純 Swift。
// 只依賴 Foundation，可在 Linux 上跑單元測試；iOS App 透過本地套件引用。
import PackageDescription

let package = Package(
    name: "AutoCutCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AutoCutCore", targets: ["AutoCutCore"]),
    ],
    targets: [
        .target(name: "AutoCutCore"),
        .testTarget(
            name: "AutoCutCoreTests",
            dependencies: ["AutoCutCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
