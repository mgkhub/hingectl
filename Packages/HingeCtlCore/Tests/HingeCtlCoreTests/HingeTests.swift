import Foundation
import Testing
@testable import HingeCtlCore

private struct Boom: Error, Equatable {}

private func elapsed(_ body: () async throws -> Void) async rethrows -> Duration {
    let clock = ContinuousClock()
    let start = clock.now
    try await body()
    return clock.now - start
}

@Suite("firstElement(条件を満たす最初の要素を、締切つきで待つ)")
struct FirstElementTests {
    private func values(_ items: [Int], finishing error: Error? = nil) -> AsyncThrowingStream<Int, Error> {
        AsyncThrowingStream { continuation in
            items.forEach { continuation.yield($0) }
            continuation.finish(throwing: error)
        }
    }

    private func expectFound(_ result: FirstElement<Int>, _ value: Int, _ comment: Comment? = nil) {
        guard case .found(let found) = result else { Issue.record("found になるはず: \(result)", sourceLocation: #_sourceLocation); return }
        #expect(found == value, comment)
    }

    @Test func 条件を満たす最初の要素を返す() async throws {
        let result = try await firstElement(of: values([1, 2, 3, 4]), timeout: .seconds(2)) { $0 >= 2 }
        expectFound(result, 2)
    }

    @Test func 非該当が続いても_後から来る該当を返す() async throws {
        let stream = AsyncThrowingStream<Int, Error> { continuation in
            Task {
                for value in [0, 0, 0, 7] { continuation.yield(value); try? await Task.sleep(for: .milliseconds(20)) }
                continuation.finish()
            }
        }
        expectFound(try await firstElement(of: stream, timeout: .seconds(5)) { $0 == 7 }, 7)
    }

    @Test func 該当が来ないまま列が終われば_締切を待たずにendedを返す() async throws {
        var result: FirstElement<Int>?
        let time = try await elapsed { result = try await firstElement(of: values([1, 2]), timeout: .seconds(30)) { $0 > 100 } }
        guard case .ended = result else { Issue.record("ended になるはず: \(String(describing: result))"); return }
        #expect(time < .seconds(5))
    }

    @Test func 何も来なければ_締切でtimedOutを返す() async throws {
        let silent = AsyncThrowingStream<Int, Error> { _ in }      // 何も流さず、終わらない
        var result: FirstElement<Int>?
        let time = try await elapsed { result = try await firstElement(of: silent, timeout: .milliseconds(100)) { _ in true } }
        guard case .timedOut = result else { Issue.record("timedOut になるはず: \(String(describing: result))"); return }
        #expect(time >= .milliseconds(90) && time < .seconds(5))
    }

    @Test func 締切より前に来た要素は_締切を待たずに返す() async throws {
        let late = AsyncThrowingStream<Int, Error> { continuation in
            Task { try? await Task.sleep(for: .milliseconds(50)); continuation.yield(5) }       // 終わらない列
        }
        var result: FirstElement<Int>?
        let time = try await elapsed { result = try await firstElement(of: late, timeout: .seconds(30)) { _ in true } }
        expectFound(try #require(result), 5)
        #expect(time < .seconds(5))
    }

    @Test func 列のエラーは握りつぶさずに投げる() async {
        do {
            _ = try await firstElement(of: values([1], finishing: Boom()), timeout: .seconds(2)) { $0 > 100 }
            Issue.record("エラーになるはず")
        } catch let error as Boom {
            #expect(error == Boom())
        } catch {
            Issue.record("予期しないエラー: \(error)")
        }
    }

    @Test func 該当より前のエラーも投げ_該当より後のエラーは見ない() async throws {
        let ok = try await firstElement(of: values([1, 2], finishing: Boom()), timeout: .seconds(2)) { $0 == 2 }
        expectFound(ok, 2)
    }

    @Test func 時間切れのとき_待っていた列の読み取りは取り消される() async throws {
        // 取り消されないと CoreDevice の購読が残る
        let terminated = TerminationFlag()
        let silent = AsyncThrowingStream<Int, Error> { continuation in
            continuation.onTermination = { _ in terminated.set() }
        }
        var result: FirstElement<Int>?
        let time = try await elapsed { result = try await firstElement(of: silent, timeout: .milliseconds(100)) { _ in true } }
        guard case .timedOut = result else { Issue.record("timedOut になるはず"); return }
        #expect(terminated.value, "締切で、待っていた列の読み取りも終わる(firstElement が戻る時点で終了している)")
        #expect(time < .seconds(5), "取り消しに応じない子 Task で、戻りが遅れない")
    }
}

private final class TerminationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

@Suite("状態の型(接続状態・バックライト)")
struct StateTypeTests {
    @Test func 接続状態は文字列と往復し_未知の値はそのまま持つ() {
        for (text, state) in [("connected", ConnectionState.connected), ("disconnected", .disconnected), ("unavailable", .unavailable),
                              ("unknown", .other("unknown")), ("connecting", .other("connecting"))] {
            #expect(ConnectionState(text) == state)
            #expect(state.text == text)
        }
        let literal: ConnectionState = "connected"
        #expect(literal == .connected)
        #expect(encodeJSON(ConnectionState.other("connecting")) == #""connecting""#)
    }

    @Test func バックライトは文字列と往復し_点灯の判定は1か所() {
        for (text, light, lit) in [("off", Backlight.off, false), ("unknown", .unknown, false),
                                   ("activeOn", .lit("activeOn"), true), ("dim", .lit("dim"), true)] {
            #expect(Backlight(text) == light)
            #expect(light.text == text)
            #expect(light.isLit == lit, "\(text)")
        }
    }

    @Test func HingeSupportの3つの状態は区別される() {
        #expect(HingeSupport.supported != .unsupported)
        #expect(HingeSupport.unknown("a") != .unsupported)
        #expect(HingeSupport.unknown("a") != .unknown("b"))
        #expect(HingeSupport.unknown("a") == .unknown("a"))
    }
}

@Suite("ヒンジへの対応の分類と、posture の角度")
struct HingeClassificationTests {
    private static let domain = "com.apple.dt.CoreDeviceError"

    @Test func ドメインとコードが両方一致したときだけ_非対応() {
        #expect(classifyHingeError(domain: Self.domain, code: 1001, reason: "not supported") == .unsupported)
    }

    @Test func コードが違えば_理由を持つ不明() {
        #expect(classifyHingeError(domain: Self.domain, code: 1002, reason: "timed out") == .unknown("timed out"))
        #expect(classifyHingeError(domain: Self.domain, code: 0, reason: "") == .unknown(""))
    }

    @Test func ドメインが違えば_コードが1001でも不明() {
        #expect(classifyHingeError(domain: "NSURLErrorDomain", code: 1001, reason: "x") == .unknown("x"))
        #expect(classifyHingeError(domain: "", code: 1001, reason: "x") == .unknown("x"))
    }

    private struct ReadFailed: Error, Equatable {}

    private final class Reader: @unchecked Sendable {
        private(set) var calls = 0
        let result: Result<Double, ReadFailed>
        init(_ result: Result<Double, ReadFailed>) { self.result = result }
        func read() async throws -> Double { calls += 1; return try result.get() }
    }

    @Test func 非対応のデバイスは_読まずにnil() async throws {
        let reader = Reader(.failure(ReadFailed()))
        #expect(try await postureAngle(support: .unsupported, read: reader.read) == nil)
        #expect(reader.calls == 0)
    }

    @Test func 対応と不明のデバイスは_読んだ値を返す() async throws {
        for support in [HingeSupport.supported, .unknown("x")] {
            let reader = Reader(.success(120))
            #expect(try await postureAngle(support: support, read: reader.read) == 120, "\(support)")
            #expect(reader.calls == 1)
        }
    }

    @Test func 対応と不明のデバイスで読めなければ_握りつぶさず投げる() async {
        for support in [HingeSupport.supported, .unknown("x")] {
            let reader = Reader(.failure(ReadFailed()))
            await #expect(throws: ReadFailed.self) { _ = try await postureAngle(support: support, read: reader.read) }
        }
    }
}
