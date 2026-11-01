// swift-tools-version: 6.0
import PackageDescription

// hingectl の、CoreDevice に依存しない純粋なロジック(swift-argument-parser による引数の解釈、向き、
// sweep の計算、devicectl の JSON の解析)。arm64 で `swift test` できるよう、非公開フレームワークとは切り離している。
// ArgumentParser は、このパッケージにだけ依存させる(コマンド定義をここに置き、`parseAsRoot` でテストするため)。
// executable 側(arm64e)は、ルートの Package.swift で、このパッケージと HingeCtlDevice にパス依存する。
let package = Package(
    name: "HingeCtlCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "HingeCtlCore", targets: ["HingeCtlCore"]),
    ],
    dependencies: [
        // 英語のエラー文言に依存するテストがあるため、版を固定する
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
    ],
    targets: [
        .target(
            name: "HingeCtlCore",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "HingeCtlCoreTests", dependencies: ["HingeCtlCore"]),
    ],
    swiftLanguageModes: [.v5]
)
