import ArgumentParser
import Foundation
import Testing
@testable import HingeCtlCore

// swift-argument-parser の `parseAsRoot` で、引数の解釈だけを検証する(実行はしない)。
// ライブラリのエラーの種類は internal で判別できないため、失敗は終了コード(64)とメッセージの文字列で検証する。
// メッセージはライブラリの英語に依存するため、ArgumentParser の版は Package.swift で固定している。

private func parse(_ args: [String], environment: [String: String] = [:]) throws -> Request {
    let command = try HingeCtl.parseAsRoot(args)
    let leaf = try #require(command as? any HingeSubcommand, "サブコマンドではない: \(args)")
    return leaf.request(environment: environment)
}

/// 解釈に失敗(またはヘルプ・バージョンの表示)したときの、終了コードとメッセージ。成功なら nil。
private func outcome(_ args: [String]) -> (code: Int32, message: String)? {
    do {
        _ = try HingeCtl.parseAsRoot(args)
        return nil
    } catch {
        return (HingeCtl.exitCode(for: error).rawValue, HingeCtl.message(for: error))
    }
}

private func isUsageError(_ args: [String], containing fragment: String, sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
    guard let result = outcome(args) else { return false }
    return result.code == 64 && result.message.contains(fragment)
}

private func request(_ command: Command, device: String? = nil, timeout: Double = 2, json: Bool = false) -> Request {
    Request(command: command, device: device, timeout: timeout, json: json)
}

@Suite("引数の解釈(swift-argument-parser)")
struct ArgumentsTests {
    // MARK: - 角度の設定

    @Test func setは角度を設定する() throws {
        #expect(try parse(["set", "90"]) == request(.setAngle(90)))
        #expect(try parse(["set", "0"]) == request(.setAngle(0)))
        #expect(try parse(["set", "180"]) == request(.setAngle(180)))
        #expect(try parse(["set", "45.5"]) == request(.setAngle(45.5)))
    }

    @Test func 範囲外の角度は検証エラー() {
        #expect(isUsageError(["set", "181"], containing: "Angle (degrees) must be a number from 0 to 180: 181"))
        #expect(isUsageError(["set", "180.1"], containing: "Angle (degrees) must be a number from 0 to 180: 180.1"))
        // 負の数は、`--` の後ろに置くと値として読まれ、範囲外として拒否される
        #expect(isUsageError(["set", "--", "-5"], containing: "Angle (degrees) must be a number from 0 to 180: -5"))
    }

    @Test func 負の数をそのまま渡すと_引数が無いというエラー() {
        // 標準では `-5` がオプションと見なされる。どちらにしても有効な角度ではないので、回避策は入れていない(終了コードは同じ 64)
        #expect(isUsageError(["set", "-5"], containing: "Missing expected argument '<degrees>'"))
    }

    @Test func 数値でない角度と足りない引数は使い方のエラー() {
        #expect(isUsageError(["set", "abc"], containing: "The value 'abc' is invalid for '<degrees>'"))
        #expect(isUsageError(["set"], containing: "Missing expected argument '<degrees>'"))
        #expect(isUsageError(["set", "1", "2"], containing: "Unexpected argument '2'"))
    }

    @Test func open_close_halfと別名() throws {
        for name in ["open", "flat", "unfolded"] { #expect(try parse([name]) == request(.setAngle(180)), "\(name)") }
        for name in ["close", "closed", "folded"] { #expect(try parse([name]) == request(.setAngle(0)), "\(name)") }
        for name in ["half", "half-open"] { #expect(try parse([name]) == request(.setAngle(90)), "\(name)") }
    }

    // MARK: - sweep

    @Test func sweepの秒数の既定は1秒() throws {
        #expect(try parse(["sweep", "0", "180"]) == request(.sweep(SweepPlan(from: 0, to: 180, seconds: 1))))
        #expect(try parse(["sweep", "180", "90", "2.5"]) == request(.sweep(SweepPlan(from: 180, to: 90, seconds: 2.5))))
        #expect(try parse(["sweep", "0", "180", "0"]) == request(.sweep(SweepPlan(from: 0, to: 180, seconds: 0))))
    }

    @Test func sweepの誤り() {
        #expect(isUsageError(["sweep", "0", "200"], containing: "End angle (to) must be a number from 0 to 180: 200"))
        #expect(isUsageError(["sweep", "200", "0"], containing: "Start angle (from) must be a number from 0 to 180: 200"))
        #expect(isUsageError(["sweep", "10"], containing: "Missing expected argument '<to>'"))
        #expect(isUsageError(["sweep", "0", "180", "--", "-1"], containing: "Duration (seconds) must be a number from 0 to 3600: -1"))
    }

    @Test func sweepの秒数には上限がある() throws {
        // 上限が無いと、極端に大きい値が SweepPlan.steps の整数変換でクラッシュした(終了コード 133)
        #expect(try parse(["sweep", "0", "180", "3600"]) == request(.sweep(SweepPlan(from: 0, to: 180, seconds: 3600))))
        for text in ["3600.1", "86400", "1e18", "1e300", "inf", "nan"] {
            #expect(isUsageError(["sweep", "0", "180", text], containing: "Duration (seconds) must be a number from 0 to 3600"), "\(text)")
        }
        // 上限の秒数でも、ステップ数が整数に収まる(クラッシュしない)
        #expect(SweepPlan(from: 0, to: 180, seconds: 3600).steps == 216_000)
    }

    // MARK: - オプション(サブコマンドの後ろ)

    @Test func オプションはサブコマンドの後ろに置く() throws {
        #expect(try parse(["get", "-d", "Duo", "--json"]) == request(.get, device: "Duo", json: true))
        #expect(try parse(["get", "--device", "Duo", "-j"]) == request(.get, device: "Duo", json: true))
        #expect(try parse(["set", "90", "-t", "0", "-d", "Duo"]) == request(.setAngle(90), device: "Duo", timeout: 0))
        #expect(try parse(["set", "90", "--timeout", "1.5"]) == request(.setAngle(90), timeout: 1.5))
    }

    @Test func サブコマンドの前のオプションは拒否される() {
        #expect(isUsageError(["-d", "Duo", "get"], containing: "Unknown option '-d'"))
        #expect(isUsageError(["--json", "get"], containing: "Unknown option '--json'"))
    }

    @Test func jsonを持たないサブコマンドでは拒否される() {
        for args in [["set", "90", "--json"], ["open", "-j"], ["close", "--json"], ["half", "--json"],
                     ["sweep", "0", "180", "--json"], ["orient", "portrait", "--json"], ["rotate", "left", "--json"]] {
            #expect(isUsageError(args, containing: "Unknown option"), "\(args)")
        }
    }

    @Test func timeoutを持たないサブコマンドでは拒否される() {
        for args in [["get", "-t", "1"], ["posture", "--timeout", "1"], ["orientation", "-t", "1"],
                     ["screenshot", "a.png", "-t", "1"], ["watch", "-t", "1"], ["list", "-t", "1"]] {
            #expect(isUsageError(args, containing: "Unknown option"), "\(args)")
        }
    }

    @Test func listはdeviceも持たない() {
        #expect(isUsageError(["list", "-d", "Duo"], containing: "Unknown option '-d'"))
    }

    @Test func timeoutの検証() {
        #expect(isUsageError(["set", "90", "-t=-1"], containing: "Timeout must be a number from 0 to 3600: -1"))
        #expect(isUsageError(["set", "90", "-t", "x"], containing: "The value 'x' is invalid"))
        #expect(isUsageError(["set", "90", "-t", "nan"], containing: "Timeout must be a number from 0 to 3600"))
    }

    @Test func timeoutの上限() throws {
        // 上限を超える値は、`Duration` の変換でクラッシュするため、検証で拒否する(1e300 は実際に trap する)
        #expect(try parse(["set", "90", "-t", "3600"]) == request(.setAngle(90), timeout: 3600))
        for value in ["3601", "1e300", "inf"] {
            #expect(isUsageError(["set", "90", "-t", value], containing: "Timeout must be a number from 0 to 3600"), "\(value)")
        }
        #expect(isUsageError(["set", "90", "-t=-inf"], containing: "Timeout must be a number from 0 to 3600"))   // 負の値は、`=` で渡す
        for command in [["open"], ["close"], ["half"], ["orient", "portrait"], ["rotate", "left"]] {
            #expect(isUsageError(command + ["-t", "1e300"], containing: "Timeout must be a number from 0 to 3600"), "\(command)")
        }
    }

    // MARK: - 環境変数 HINGECTL_DEVICE

    @Test func 環境変数は既定の対象で_空は無視され_dが優先される() throws {
        #expect(try parse(["get"], environment: ["HINGECTL_DEVICE": "Env"]) == request(.get, device: "Env"))
        #expect(try parse(["get"], environment: ["HINGECTL_DEVICE": ""]) == request(.get))
        #expect(try parse(["get", "-d", "Cli"], environment: ["HINGECTL_DEVICE": "Env"]) == request(.get, device: "Cli"))
        #expect(try parse(["set", "90"], environment: ["HINGECTL_DEVICE": "Env"]) == request(.setAngle(90), device: "Env"))
    }

    // MARK: - 読み取りと向き

    @Test func 出力のあるサブコマンド() throws {
        #expect(try parse(["get"]) == request(.get))
        #expect(try parse(["get", "--sensor"]) == request(.get(sensor: true)))
        #expect(try parse(["get", "--sensor", "--json"]) == request(.get(sensor: true), json: true))
        #expect(try parse(["posture", "--json"]) == request(.posture, json: true))
        #expect(try parse(["orientation", "-j"]) == request(.orientation, json: true))
        #expect(try parse(["list"]) == request(.list))
        #expect(try parse(["list", "--json"]) == request(.list, json: true))
        #expect(try parse(["screenshot", "a.png", "-j", "-d", "Duo"]) == request(.screenshot(path: "a.png"), device: "Duo", json: true))
    }

    @Test func screenshotは_pngのパスだけを受ける() throws {
        #expect(try parse(["screenshot", "A.PNG"]) == request(.screenshot(path: "A.PNG")))
        #expect(isUsageError(["screenshot", "a.jpg"], containing: "Output path must end with .png: a.jpg"))
        #expect(isUsageError(["screenshot"], containing: "Missing expected argument '<path>'"))
    }

    @Test func orientは列挙を受ける() throws {
        #expect(try parse(["orient", "portrait"]) == request(.orient(.portrait)))
        #expect(try parse(["orient", "landscape-left", "-t", "0"]) == request(.orient(.landscapeLeft), timeout: 0))
        #expect(try parse(["orient", "landscape-right"]) == request(.orient(.landscapeRight)))
        #expect(try parse(["orient", "portrait-upside-down"]) == request(.orient(.portraitUpsideDown)))
    }

    @Test func orientの不正な値は有効な値を示す() {
        #expect(isUsageError(["orient", "sideways"], containing: "The value 'sideways' is invalid for '<orientation>'"))
        #expect(isUsageError(["orient", "landscape-left-"], containing: "portrait-upside-down"))
        #expect(isUsageError(["orient", "landscapeLeft"], containing: "landscape-left"))      // キャメルケースは受けない
    }

    @Test func rotateは_lと_rも受ける() throws {
        #expect(try parse(["rotate", "left"]) == request(.rotate(.left)))
        #expect(try parse(["rotate", "l"]) == request(.rotate(.left)))
        #expect(try parse(["rotate", "right"]) == request(.rotate(.right)))
        #expect(try parse(["rotate", "r", "--timeout", "0"]) == request(.rotate(.right), timeout: 0))
        #expect(isUsageError(["rotate", "up"], containing: "The value 'up' is invalid for '<direction>'"))
    }

    // MARK: - watch

    @Test func watchのcount() throws {
        #expect(try parse(["watch"]) == request(.watch(count: nil)))
        #expect(try parse(["watch", "--sensor"]) == request(.watch(sensor: true, count: nil)))
        #expect(try parse(["watch", "--sensor", "--count", "2"]) == request(.watch(sensor: true, count: 2)))
        #expect(try parse(["watch", "--count", "3"]) == request(.watch(count: 3)))
        #expect(try parse(["watch", "--json", "--count", "1", "-d", "Duo"]) == request(.watch(count: 1), device: "Duo", json: true))
        #expect(isUsageError(["watch", "--count", "0"], containing: "--count must be a positive integer: 0"))
        #expect(isUsageError(["watch", "--count", "x"], containing: "The value 'x' is invalid"))
    }

    // MARK: - 不明なコマンド・ヘルプ・バージョン

    @Test func 不明なサブコマンドは使い方のエラー() {
        #expect(isUsageError(["foo"], containing: "Unexpected argument 'foo'"))
        #expect(isUsageError(["120"], containing: "Unexpected argument '120'"))     // 数値だけのコマンドは無い
    }

    @Test func 引数なしはヘルプを出して成功() throws {
        // サブコマンドではなくルート自身が返る(`run()` がヘルプを出す)
        let command = try HingeCtl.parseAsRoot([])
        #expect(command is HingeCtl)
        #expect(!(command is any HingeSubcommand))
    }

    @Test func ヘルプはthrowせず_サブコマンドではないコマンドが返る() throws {
        for args in [["--help"], ["-h"], ["help"], ["help", "set"], ["set", "--help"]] {
            let command = try? HingeCtl.parseAsRoot(args)
            if let command { #expect(!(command is any HingeSubcommand), "\(args)") }
        }
    }

    @Test func ヘルプの内容() {
        let help = HingeCtl.helpMessage(columns: 100)
        #expect(help.contains("USAGE: hingectl <subcommand>"))
        for name in ["set", "open", "close", "half", "sweep", "get", "posture", "screenshot", "rotate", "orient", "orientation", "list", "watch"] {
            #expect(help.contains("  \(name)"), "\(name)")
        }
        #expect(help.contains("open, flat, unfolded"))
        #expect(help.contains("--version"))
    }

    @Test func サブコマンドのヘルプにオプションが出る() {
        let get = GetCommand.helpMessage(columns: 100)
        #expect(get.contains("--device <device>") && get.contains("--json"))
        #expect(!get.contains("--timeout"))
        let set = SetCommand.helpMessage(columns: 100)
        #expect(set.contains("--timeout <seconds>") && set.contains("--device <device>"))
        #expect(!set.contains("--json"))
    }

    @Test func バージョンは0_0_1で_vは使えない() {
        let version = outcome(["--version"])
        #expect(version?.code == 0)
        #expect(version?.message == "0.0.1")
        #expect(isUsageError(["-v"], containing: "Unknown option '-v'"))
    }

    // MARK: - ヒンジを要するコマンド

    @Test func ヒンジを要するコマンドだけが_ヒンジ非対応のデバイスで拒否される() throws {
        // コマンドを足したとき判定の取りこぼしに気づけるよう、全部の入口を並べる
        let cases: [(args: [String], requiresHinge: Bool)] = [
            (["set", "90"], true), (["open"], true), (["close"], true), (["half"], true),
            (["sweep", "0", "180"], true), (["get"], true), (["watch"], true),
            (["posture"], false), (["screenshot", "a.png"], false), (["rotate", "left"], false),
            (["orient", "portrait"], false), (["orientation"], false), (["list"], false),
        ]
        for (args, expected) in cases {
            let leaf = try #require(try HingeCtl.parseAsRoot(args) as? any HingeSubcommand, "\(args)")
            #expect(leaf.request(environment: [:]).command.requiresHinge == expected, "\(args)")
        }
    }

    // MARK: - 終了コード

    @Test func 引数の誤りの終了コードは64() {
        for args in [["foo"], ["set"], ["set", "181"], ["set", "abc"], ["orient", "x"], ["get", "--json", "--bogus"]] {
            #expect(outcome(args)?.code == 64, "\(args)")
        }
    }

    @Test func CLIErrorは実行時エラーとして終了コード1() {
        // `run` の中で投げられる CLIError は ValidationError ではないため、ArgumentParser は 1 にする
        #expect(HingeCtl.exitCode(for: CLIError("boom")).rawValue == 1)
        #expect(HingeCtl.message(for: CLIError("boom")) == "boom")
        #expect(HingeCtl.exitCode(for: ValidationError("bad")).rawValue == 64)
    }
}
