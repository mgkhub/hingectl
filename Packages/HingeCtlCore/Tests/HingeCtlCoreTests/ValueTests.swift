import Foundation
import Testing
@testable import HingeCtlCore

@Suite("向き・sweep の計算と表示")
struct ValueTests {
    // MARK: - 表示

    @Test func 角度の表示は小数1桁() {
        #expect(angleText(180) == "180.0")
        #expect(angleText(119.96) == "120.0")
        #expect(angleText(0) == "0.0")
    }

    // MARK: - 向き

    @Test func 回転の方向の別名() {
        #expect(RotationDirection(argument: "left") == .left)
        #expect(RotationDirection(argument: "l") == .left)
        #expect(RotationDirection(argument: "right") == .right)
        #expect(RotationDirection(argument: "r") == .right)
        #expect(RotationDirection(argument: "up") == nil)
    }

    @Test func 左回転はDeviceHubの順序() {
        #expect(OrientationName.portrait.rotated(.left) == .landscapeLeft)
        #expect(OrientationName.landscapeLeft.rotated(.left) == .portraitUpsideDown)
        #expect(OrientationName.portraitUpsideDown.rotated(.left) == .landscapeRight)
        #expect(OrientationName.landscapeRight.rotated(.left) == .portrait)
    }

    @Test func 右回転は逆回り() {
        #expect(OrientationName.portrait.rotated(.right) == .landscapeRight)
        #expect(OrientationName.landscapeRight.rotated(.right) == .portraitUpsideDown)
        #expect(OrientationName.portraitUpsideDown.rotated(.right) == .landscapeLeft)
        #expect(OrientationName.landscapeLeft.rotated(.right) == .portrait)
    }

    @Test func 左右に回すと元に戻り_4回で一周する() {
        for start in OrientationName.allCases {
            #expect(start.rotated(.left).rotated(.right) == start)
            #expect(start.rotated(.right).rotated(.left) == start)
            #expect(start.rotated(.left) != start)
            var current = start
            for _ in 0..<4 { current = current.rotated(.left) }
            #expect(current == start)
        }
    }

    @Test func 向きの表示と_postureの向きの欄() {
        #expect(orientationText(.landscapeLeft) == "landscape-left")
        #expect(orientationText(nil) == "unknown")
        #expect(OrientationField.known(.portraitUpsideDown).text == "portrait-upside-down")
        #expect(OrientationField.unknown.text == "unknown")
        #expect(OrientationField.unavailable.text == "unavailable")
    }

    @Test func 向きの名前はDeviceHubのイベントと同じkebab_case() {
        #expect(OrientationName.allCases.map(\.rawValue) == ["portrait", "landscape-left", "landscape-right", "portrait-upside-down"])
        #expect(OrientationName(rawValue: "landscapeLeft") == nil)
    }

    // MARK: - sweep

    @Test func 秒数からステップ数が決まる() {
        #expect(SweepPlan(from: 0, to: 180, seconds: 0).steps == 1)     // 0 秒でも最小 1
        #expect(SweepPlan(from: 0, to: 180, seconds: 0.2).steps == 12)
        #expect(SweepPlan(from: 0, to: 180, seconds: 1).steps == 60)
        #expect(SweepPlan(from: 0, to: 180, seconds: 3).steps == 180)
    }

    @Test func 端点がfromとtoで_等間隔に変化する() {
        let down = SweepPlan(from: 180, to: 90, seconds: 2)
        #expect(down.angle(at: 0) == 180)
        #expect(down.angle(at: down.steps) == 90)
        #expect(abs(down.angle(at: 60) - 135) < 1e-9)
        #expect(abs(down.angle(at: 1) - down.angle(at: 0) + 0.75) < 1e-9) // 90° / 120 ステップ = 0.75° ずつ

        let up = SweepPlan(from: 0, to: 180, seconds: 3)
        #expect(up.angle(at: 0) == 0)
        #expect(up.angle(at: up.steps) == 180)
    }

    @Test func 送信の時刻は開始から数えた絶対時刻() {
        let plan = SweepPlan(from: 0, to: 180, seconds: 2)
        #expect(plan.time(at: 0) == 0)
        #expect(abs(plan.time(at: plan.steps) - 2) < 1e-9)
        #expect(abs(plan.time(at: 1) - 1.0 / 60) < 1e-9)
        // 累積誤差が無い: 途中の時刻も、ステップ数に比例した値になる
        #expect(abs(plan.time(at: 90) - 1.5) < 1e-9)
    }

    @Test func 秒数0は_fromを送ってすぐtoを送る() {
        let plan = SweepPlan(from: 30, to: 150, seconds: 0)
        #expect(plan.angle(at: 0) == 30)
        #expect(plan.angle(at: 1) == 150)
        #expect(plan.time(at: 1) == 0)
    }
}
