// swift-tools-version: 6.0
import PackageDescription

// 実機 iPhone Duo のヒンジ角・向きを操作する Mac 用 CLI。
//
// CoreDevice を呼ぶ層は Packages/HingeCtlDevice(非公開フレームワークの設定は、そこにある)、
// CoreDevice に依存しない純粋なロジックは Packages/HingeCtlCore にあり、後者は arm64 で `swift test` できる。
// arm64e でのビルドは、`swift build` の `--triple` と `--build-system native` で指定する(Makefile を参照)。

let package = Package(
    name: "hingectl",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "hingectl", targets: ["hingectl"]),
    ],
    dependencies: [
        .package(path: "Packages/HingeCtlCore"),
        .package(path: "Packages/HingeCtlDevice"),
    ],
    targets: [
        .executableTarget(
            name: "hingectl",
            dependencies: [
                .product(name: "HingeCtlCore", package: "HingeCtlCore"),
                .product(name: "HingeCtlDevice", package: "HingeCtlDevice"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
