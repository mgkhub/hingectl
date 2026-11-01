// swift-tools-version: 6.0
import PackageDescription

// CoreDevice を呼ぶ層(実機・シミュレータのヒンジ角・向き・ディスプレイ・スクリーンショット)。
// 公開する API は Swift の型だけで、CoreDevice の型は外へ出さない(`@_implementationOnly import`)。
// CLI(ルートの Package.swift)と GUI(HingeCtlApp)が、同じ実装を使う。
//
// CoreDevice / CoreDeviceUtilities(/Library/Developer/PrivateFrameworks)は、非公開・arm64e 専用で、
// Swift モジュール情報を持たない。そのため、Interfaces/ の手書きの .swiftinterface を `-I` で読み込み、
// arm64e でビルドする(ルートの Makefile を参照)。
let privateFrameworks = "/Library/Developer/PrivateFrameworks"

let package = Package(
    name: "HingeCtlDevice",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "HingeCtlDevice", targets: ["HingeCtlDevice"]),
    ],
    dependencies: [
        .package(path: "../HingeCtlCore"),
    ],
    targets: [
        .target(
            name: "HingeCtlDevice",
            dependencies: [.product(name: "HingeCtlCore", package: "HingeCtlCore")],
            swiftSettings: [
                .unsafeFlags([
                    "-I", Context.packageDirectory + "/../../Interfaces", "-F", privateFrameworks,
                    "-enable-experimental-feature", "CheckImplementationOnly",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", privateFrameworks,
                    "-framework", "CoreDevice", "-framework", "CoreDeviceUtilities",
                    "-Xlinker", "-rpath", "-Xlinker", privateFrameworks,
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
