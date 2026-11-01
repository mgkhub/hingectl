# HingeTestApp (調査・解析用 iOS アプリ)

iPhone Duo シミュレータおよび実機上で、以下の値をリアルタイムに並列取得・比較表示・ログ記録する解析用 iOS アプリです。

1. **`CoreMotion` (`CMAngleManager` / `CMAngle`)**:
   - `angleDegrees`: 画面パネル表面角 (Raw)
   - `mechanicalAngleDegrees`: 物理ヒンジ角 (Hinge)
   - `Disparity (Δ)`: テンションによるズレ (`Screen - Hinge`)
2. **`UIKit` (`UIHinge` / `UIHingeInteraction`)**:
   - `status`: `.closed (1)` / `.partiallyOpen (2)` / `.fullyOpen (3)` / `.unknown (0)`
   - `angle`: ラジアン (`CGFloat`) および度数法換算値
3. **`Orientation & Environment`**:
   - `Device Orientation`: `UIDevice.current.orientation` (Portrait, LandscapeLeft, etc.)
   - `Interface Orientation`: `UIWindowScene.effectiveGeometry.interfaceOrientation`
   - `Active Screen`: 解像度 (pt / px) とスケール、接続ディスプレイ数
4. **`Event Log Stream`**:
   - 変更イベントのリアルタイム履歴表示および `NSLog` (`[HingeTest]`) 出力

---

## 表記と丸めルール

HingeCtl 本体の表示規約（[Validation.swift](../../Packages/HingeCtlCore/Sources/HingeCtlCore/Validation.swift) および GUI）と合わせ、主要な角度表示はすべて **小数第 1 位 (`%.1f°`)** に統一しています。
精密解析のため、詳細グリッドやログには高精度な生データ（小数第 4 位 (`%.4f°`) / ラジアン (`%.4f rad`)）も併記されます。

---

## ビルドと起動

```bash
# ビルドのみ
Tools/HingeTestApp/build.sh

# ビルドしてシミュレータにインストール・起動
Tools/HingeTestApp/build.sh <SIMULATOR_UDID>
```

## ログの監視

```bash
xcrun simctl spawn <SIMULATOR_UDID> log stream --predicate 'eventMessage CONTAINS "[HingeTest]"'
```

---

## 調査から判明した事実

1. **シミュレータの物理吸着（スナップ機構）**:
   - `0° 〜 5°`: 物理角 `mechanicalAngle` は指定通り動くが、画面パネル角 `angleDegrees` (Raw) は `0.0°` に固定スナップされる。
   - `171° 〜 180°`: 画面パネル角 `angleDegrees` (Raw) は `180.0°` に固定スナップされる。
   - `85° 〜 95° (Half)`: テンションシミュレーションにより、物理角とパネル角の間に約 4° 前後の偏差が生じる。

2. **CoreDevice ストリームと setHingeAngle の解決策**:
   - CoreDevice デーモンはパネル角（Raw）の変化量をトリガーにしてストリームイベントを送信するため、スナップ領域ではイベント配信が停止する。
   - `DeviceAccess.setHingeAngle` では、タイムアウト時に `readHingeAngle` による静定角フォールバック確認を行うことで、全境界値で 100% 安定して目標角到達を判定できる。
