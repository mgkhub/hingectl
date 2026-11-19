import Foundation
import HingeCtlCore
import HingeCtlDevice

// hingectl: iPhone Duo(実機と、Mac 上のシミュレータ)のヒンジ角・向きを、CoreDevice 経由で操作する Mac 用 CLI。
// 引数の解釈(swift-argument-parser)・向きや sweep の計算・CoreDevice モデルの解析は HingeCtlCore(Packages/HingeCtlCore)にあり、
// CoreDevice を呼ぶ部分は HingeCtlDevice(Packages/HingeCtlDevice)にあり、ここでは、解釈済みの `Request` を実行して出力を整える。

setvbuf(stdout, nil, _IOLBF, 0)

private func printJSON<Value: Encodable>(_ value: Value) {
    if let text = encodeJSON(value) { print(text) }
}

/// 標準入力と標準エラーが両方とも端末のときだけ、対話式に問い合わせる(パイプ・スクリプトでは入力待ちで止めない)。
private let canPrompt = isatty(STDIN_FILENO) != 0 && isatty(STDERR_FILENO) != 0

/// ヒンジ対応のデバイスが複数あるとき、番号で選ばせる。表示は標準エラーに出し、標準出力(データ)は汚さない。
private func chooseInteractively(_ candidates: [DeviceEntry]) throws -> DeviceEntry {
    try promptForDevice(candidates, input: { readLine() },
                        output: { FileHandle.standardError.write(Data($0.utf8)) })
}

// MARK: - 各コマンドのハンドラ

private func handleList(json: Bool) throws {
    let devices = try listDevices()
    if json {
        printJSON(devices)
    } else {
        devices.forEach { print(listLine($0)) }
    }
}

private func handleSetAngle(_ device: HingeDevice, degrees: Double, timeout: Double) async throws {
    print(angleText(try await device.setAngle(degrees, timeout: timeout)))
}

private func handleSweep(_ device: HingeDevice, plan: SweepPlan, timeout: Double) async throws {
    print(angleText(try await device.sweep(from: plan.from, to: plan.to, seconds: plan.seconds, timeout: timeout)))
}

private func handleGet(_ device: HingeDevice, sensor: Bool, json: Bool) async throws {
    let reading = try await device.readAngle()
    let value = sensor ? reading.sensorAngle : reading.mechanicalAngle
    if json {
        printJSON(AngleOutput(reading))
    } else {
        print(angleText(value))
    }
}

private func handlePosture(_ device: HingeDevice, json: Bool) async throws {
    let posture = try await device.posture()
    if json {
        printJSON(PostureOutput(device: device.entry, posture: posture))
    } else {
        postureLines(device: device.entry, posture: posture).forEach { print($0) }
    }
}

private func handleScreenshot(_ device: HingeDevice, path: String, json: Bool) async throws {
    let shot = try await device.screenshot(to: path)
    if json {
        printJSON(shot)
    } else {
        screenshotLines(shot).forEach { print($0) }
    }
}

private func handleRotate(_ device: HingeDevice, direction: RotationDirection, timeout: Double) async throws {
    print(orientationText(try await device.rotate(direction, timeout: timeout)))
}

private func handleOrient(_ device: HingeDevice, name: OrientationName, timeout: Double) async throws {
    print(orientationText(try await device.setOrientation(name, timeout: timeout)))
}

private func handleOrientation(_ device: HingeDevice, json: Bool) async throws {
    let orientation = try await device.orientation()
    if json {
        printJSON(OrientationOutput(orientation: orientation))
    } else {
        print(orientationText(orientation))
    }
}

private func handleWatch(_ device: HingeDevice, sensor: Bool, count: Int?, json: Bool) async throws {
    let readings = try await device.readings()
    var seen = 0
    for try await batch in readings {
        for reading in batch {
            let value = sensor ? reading.sensorAngle : reading.mechanicalAngle
            if json { printJSON(reading) } else { print(angleText(value)) }
            seen += 1
            if let count, seen >= count { return }
        }
    }
}

func execute(_ request: Request) async throws {
    // デバイスを選ばないコマンド
    if request.command == .list {
        try handleList(json: request.json)
        return
    }

    let device = try await HingeDevice.resolve(request.device, choose: canPrompt ? chooseInteractively : nil)
    // ヒンジを使うコマンドは、非対応のデバイスには何も送らずにエラーにする(`-t 0` でも)
    if request.command.requiresHinge { try await device.requireHinge() }
    let timeout = request.timeout

    switch request.command {
    case .list:
        break
    case .setAngle(let degrees):
        try await handleSetAngle(device, degrees: degrees, timeout: timeout)
    case .sweep(let plan):
        try await handleSweep(device, plan: plan, timeout: timeout)
    case .get(let sensor):
        try await handleGet(device, sensor: sensor, json: request.json)
    case .posture:
        try await handlePosture(device, json: request.json)
    case .screenshot(let path):
        try await handleScreenshot(device, path: path, json: request.json)
    case .rotate(let direction):
        try await handleRotate(device, direction: direction, timeout: timeout)
    case .orient(let name):
        try await handleOrient(device, name: name, timeout: timeout)
    case .orientation:
        try await handleOrientation(device, json: request.json)
    case .watch(let sensor, let count):
        try await handleWatch(device, sensor: sensor, count: count, json: request.json)
    }
}

await runHingeCtl(execute: execute)
