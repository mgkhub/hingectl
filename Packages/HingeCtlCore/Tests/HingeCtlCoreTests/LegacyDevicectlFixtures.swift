import Foundation
@testable import HingeCtlCore

// 旧 devicectl 出力形式（テストフィクスチャ）を処理するための互換レイヤー。
// プロダクションコードはプロセス内 CoreDevice に完全移行したため、テスト専用としてここに保持する。

struct DevicectlEnvelope<Result: Decodable>: Decodable {
    let outcome: String?
    let result: Result?

    private enum CodingKeys: String, CodingKey { case info, result }

    private struct Info: Decodable {
        let outcome: String?
        private enum CodingKeys: String, CodingKey { case outcome }
        init(from decoder: Decoder) throws {
            outcome = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .outcome)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outcome = (try? container.decodeIfPresent(Info.self, forKey: .info))?.outcome
        result = try? container.decodeIfPresent(Result.self, forKey: .result)
    }
}

func decodeDevicectl<Result: Decodable>(_ type: Result.Type, stdout: Data, stderr: String, label: String) throws -> Result {
    guard let envelope = try? JSONDecoder().decode(DevicectlEnvelope<Result>.self, from: stdout),
          envelope.outcome == "success", let result = envelope.result else {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw CLIError("devicectl \(label) failed\(detail.isEmpty ? "" : ": \(detail)")")
    }
    return result
}

struct DeviceRecord: Decodable {
    let identifier: String?
    let name: String?
    let udid: String?
    let reality: String?
    let tunnelState: String?
    let transportType: String?
    let capabilities: Set<String>
    let osVersion: String?
    let osBuild: String?
    let platform: String?
    let deviceType: String?

    private enum CodingKeys: String, CodingKey { case identifier, deviceProperties, hardwareProperties, connectionProperties, capabilities }

    private struct Capability: Decodable {
        let featureIdentifier: String?
        private enum CodingKeys: String, CodingKey { case featureIdentifier }
        init(from decoder: Decoder) throws {
            featureIdentifier = try? decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .featureIdentifier)
        }
    }

    private struct Properties: Decodable {
        let name: String?
        let osVersionNumber: String?
        let osBuildUpdate: String?
        private enum CodingKeys: String, CodingKey { case name, osVersionNumber, osBuildUpdate }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            osVersionNumber = try? container.decodeIfPresent(String.self, forKey: .osVersionNumber)
            osBuildUpdate = try? container.decodeIfPresent(String.self, forKey: .osBuildUpdate)
        }
    }

    private struct Hardware: Decodable {
        let reality: String?
        let udid: String?
        let platform: String?
        let deviceType: String?
        private enum CodingKeys: String, CodingKey { case reality, udid, platform, deviceType }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            reality = try? container.decodeIfPresent(String.self, forKey: .reality)
            udid = try? container.decodeIfPresent(String.self, forKey: .udid)
            platform = try? container.decodeIfPresent(String.self, forKey: .platform)
            deviceType = try? container.decodeIfPresent(String.self, forKey: .deviceType)
        }
    }

    private struct Connection: Decodable {
        let tunnelState: String?
        let transportType: String?
        private enum CodingKeys: String, CodingKey { case tunnelState, transportType }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tunnelState = try? container.decodeIfPresent(String.self, forKey: .tunnelState)
            transportType = try? container.decodeIfPresent(String.self, forKey: .transportType)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try? container.decodeIfPresent(String.self, forKey: .identifier)
        let properties = try? container.decodeIfPresent(Properties.self, forKey: .deviceProperties)
        name = properties?.name
        osVersion = properties?.osVersionNumber
        osBuild = properties?.osBuildUpdate
        let hardware = try? container.decodeIfPresent(Hardware.self, forKey: .hardwareProperties)
        reality = hardware?.reality
        udid = hardware?.udid
        platform = hardware?.platform
        deviceType = hardware?.deviceType
        let connection = try? container.decodeIfPresent(Connection.self, forKey: .connectionProperties)
        tunnelState = connection?.tunnelState
        transportType = connection?.transportType
        capabilities = Set(((try? container.decodeIfPresent([Capability].self, forKey: .capabilities)) ?? []).compactMap(\.featureIdentifier))
    }

    var entry: DeviceEntry? {
        guard let identifier, let reality = reality.flatMap(DeviceReality.init(rawValue:)) else { return nil }
        let state = ConnectionState(tunnelState ?? "unknown")
        if reality == .simulated && state != .connected { return nil }
        return DeviceEntry(id: identifier, name: name ?? "(unnamed)", udid: udid ?? identifier,
                           connectionState: state, reality: reality, transport: transportType,
                           capabilities: capabilities, osName: osDisplayName(platform: platform, deviceType: deviceType),
                           osVersion: osVersion, osBuild: osBuild)
    }
}

struct DeviceList: Decodable {
    let devices: [DeviceRecord]

    private enum CodingKeys: String, CodingKey { case devices }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devices = ((try? container.decodeIfPresent([Lossy<DeviceRecord>].self, forKey: .devices)) ?? []).compactMap(\.value)
    }
}

/// テスト用: `devicectl list devices -q -j -` の出力から実機と起動中シミュレータを取り出す。
func decodeDevices(stdout: Data, stderr: String, label: String) throws -> [DeviceEntry] {
    let entries = try decodeDevicectl(DeviceList.self, stdout: stdout, stderr: stderr, label: label).devices.compactMap(\.entry)
    return entries.filter { !$0.isSimulator } + entries.filter(\.isSimulator)
}

/// テスト用: `devicectl device info displays -q -j -` の出力(封筒形式)から内蔵ディスプレイを読む。
func decodeDisplays(stdout: Data, stderr: String, label: String) throws -> (displays: [DisplayState], active: Int?) {
    var displays = try decodeDevicectl(DisplayList.self, stdout: stdout, stderr: stderr, label: label).displays.compactMap(\.state)
    guard !displays.isEmpty else { throw CLIError("The device reports no integrated display") }
    var activeIndex = displays.firstIndex { $0.active }
    if activeIndex == nil && displays.count == 1 {
        displays[0].active = true
        activeIndex = 0
    }
    return (displays, activeIndex)
}

/// テスト用: `devicectl device info details` で切断中のデバイスを起こしたあと、つながらなかった理由を取り出す。
func wakeFailureReason(stdout: String, stderr: String, status: Int32) -> String? {
    for line in (stdout + "\n" + stderr).split(separator: "\n") {
        if let range = line.range(of: "Error: ") { return String(line[range.upperBound...]) }
    }
    return status == 0 ? nil : "exit status \(status)"
}
