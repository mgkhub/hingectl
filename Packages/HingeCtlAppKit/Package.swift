// swift-tools-version: 6.0
import PackageDescription

// GUI の状態管理(デバイス一覧・選択・操作の実行・ログ)。CoreDevice には依存せず、バックエンドは
// `HingeBackend` のプロトコル越しに受け取る。そのため、偽のバックエンドで arm64 の `swift test` ができる。
// 実際のバックエンド(HingeCtlDevice を呼ぶ)と SwiftUI のビューは、HingeCtlApp にある。
let package = Package(
    name: "HingeCtlAppKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "HingeCtlAppKit", targets: ["HingeCtlAppKit"]),
    ],
    dependencies: [
        .package(path: "../HingeCtlCore"),
    ],
    targets: [
        .target(
            name: "HingeCtlAppKit",
            dependencies: [.product(name: "HingeCtlCore", package: "HingeCtlCore")]
        ),
        .testTarget(name: "HingeCtlAppKitTests", dependencies: ["HingeCtlAppKit"]),
    ],
    swiftLanguageModes: [.v5]
)
