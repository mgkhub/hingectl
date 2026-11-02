# 開発メモ

[README](../README.md) に載せない、開発者向けの内容です。

- [Xcode の選ばれ方](#xcode-の選ばれ方)
- [ファイル構成](#ファイル構成)
- [テスト](#テスト)
- [仕組み](#仕組み)
- [JSON の扱い](#json-の扱い)
- [GUI の開発](#gui-の開発)
- [配布用の DMG](#配布用の-dmg)
- [ビルドの注意](#ビルドの注意)

実機での挙動は、[BEHAVIOR.md](BEHAVIOR.md) にあります。

## Xcode の選ばれ方

- **ビルド(`make build`)には、Xcode 27.0 以降(Swift 6.4)が必要です。** それ以前の Xcode(Swift 6.4 未満)では、「SDK が Swift 6.4 でビルドされており、コンパイラが対応していない」というエラーで、
  CoreDevice のモジュールをビルドできず失敗します。27.0 と 27.1 で、ビルドと動作(シミュレータ)が同じことを確認しています。それ以降の Xcode は未確認です(上限は不明)。
- **実行には、特定の Xcode は要りません。** `hingectl` は CoreDevice を、Xcode の中ではなく、システム共通の
  `/Library/Developer/PrivateFrameworks/CoreDevice.framework`(651.13.5。Xcode のインストール時に入ります)からリンクします。
  `list` / `screenshot` / `posture` が呼ぶ `xcrun devicectl` は、環境変数 `DEVELOPER_DIR` または `xcode-select` で選ばれた Xcode のものです
  (シミュレータと実機(iOS 27.1)のどちらでも、Xcode 27.0 / 27.1 のどちらの devicectl でも、同じ結果になることを確認しています)。
- `make test` は CoreDevice に依存しないため、Xcode 27.0 以降でなくても(選択中の Xcode で)通ります。

`make build` が使う Xcode は、`Scripts/with-xcode.sh` が次の優先順位で決めます(`xcode-select` の選択やインストール済みの Xcode は変更しません)。

1. 環境変数 `DEVELOPER_DIR`(または `make build DEVELOPER_DIR=...`)が指定されていれば、27.0 以降か確かめて、それを使います(満たさなければ失敗)。
2. `xcode-select` で選択中の Xcode が 27.0 以降なら、`DEVELOPER_DIR` を設定せずに、それを使います。
3. そうでなければ、`xcodes` コマンドがあれば `xcodes installed` から、27.0 以降で最新の正式版(ベータ・RC を除く)を探して使います。
   `xcodes` は `/Applications` の中だけを探します。
4. 見つからなければ、案内を出して失敗します(`xcodes install 27.1`、または `DEVELOPER_DIR=...` の指定)。

`Package.resolved` は、ルートと `Packages/HingeCtlCore`・`Packages/HingeCtlAppKit` にあり、いずれもコミットしています。

## ファイル構成

SwiftPM のパッケージが 4 つあります(ルートと、`Packages/` の 3 つ。理由は「[ビルドの注意](#ビルドの注意)」)。GUI は、これらのソースを Xcode プロジェクトで取り込みます。

```text
./                              # リポジトリのルート
  Package.swift                  # executable(arm64e)。HingeCtlCore と HingeCtlDevice にパス依存
  Makefile                       # build / app / run-app / screenshots / test / clean / generate-xcodeproj(Xcode が要るものは Scripts/with-xcode.sh 経由)
  LICENSE                        # MIT
  docs/                          # このファイル、BEHAVIOR.md(実機の挙動)、images/(README のスクリーンショット。make screenshots で生成)
  Scripts/with-xcode.sh          # ビルドに使う Xcode(27.0 以降)を DEVELOPER_DIR / xcode-select / xcodes から決める
  Scripts/render-icon.sh         # アプリアイコンの元(AppIcon.template.svg)から、SVG・icon.json・device.png を作り直す(macOS 標準の sips を使う)
  Scripts/dmg/                   # 配布用の DMG の素材(background.svg と、.DS_Store のテンプレート DS_Store)。make dmg が使う
  Mintfile                       # XcodeGen の版(mint で固定)
  Interfaces/                    # 手書きの .swiftinterface(CoreDevice / CoreDeviceUtilities)
  Sources/hingectl/
    main.swift                   # 解釈済みの Request を HingeCtlDevice で実行し、出力を整える(薄い)
  Packages/HingeCtlDevice/       # CoreDevice を呼ぶ層(CLI と GUI が共有。公開 API は Swift の型だけ)
    Package.swift                # 非公開フレームワークの設定(-I / -F / リンク)は、ここにある
    Sources/HingeCtlDevice/
      HingeDevice.swift          # 公開 API: HingeDevice(読み取り・設定・sweep・向き・posture・screenshot・連続送信)
      DeviceAccess.swift         # CoreDevice: デバイスの取得、ヒンジ角の読み書き、向きの制御
      Devicectl.swift            # devicectl の実行、実機の一覧、ディスプレイ情報、切断中の端末を起こす処理(wakeDevices)
      Log.swift                  # HingeLog: 状況・警告の出力先(既定は標準エラー。GUI は差し替える)
  HingeCtlApp/                   # GUI アプリ(SwiftUI)
    project.yml                  # Xcode プロジェクトの定義(XcodeGen)。Packages/ の 3 つのソースを、静的ライブラリのターゲットとして取り込む
    Icon/                        # アイコンの元(AppIcon.template.svg)と、そこから生成した SVG(ライト/ダーク。README のロゴにも使う)
    Sources/
      AppIcon.icon/              # アプリアイコン(Icon Composer 形式。ライト/ダークの背景は icon.json の fill)
      HingeCtlApp.swift          # @main。ログの出力先(HingeLog.sink)を、ログ欄につなぐ
      LiveBackend.swift          # HingeBackend の実体(HingeCtlDevice を呼ぶ)
      RootView / SidebarView / DeviceDetailView.swift   # 画面
      Localization/              # 画面の文言(String Catalog: General, Sidebar, HingeAngle など 8 つの .xcstrings)
      Mock/MockBackend.swift     # 撮影用の偽のバックエンド(--screenshot-mode のときだけ使う。固定のデータ)
      ScreenshotRunner.swift     # README 用のスクリーンショットを自動で撮る(make screenshots)
  Packages/HingeCtlAppKit/       # GUI の状態管理(DeviceStore / DeviceDetailStore / AppLog / HingeBackend)。CoreDevice に依存せず、arm64 で swift test
    Package.swift
    Sources/HingeCtlAppKit/
      Backend.swift              # HingeBackend / HingeSession / AngleSender(GUI から見たデバイスへのアクセス。実体は LiveBackend、テストでは偽物)
      DeviceStore.swift          # デバイス一覧と選択中のデバイス(一定間隔で取り直す)
      DeviceDetailStore.swift    # 選んだ 1 台の状態と操作(接続・購読・角度・sweep・向き・posture・screenshot)
      AppLog.swift               # ログ欄の内容
      ScreenshotName.swift       # スクリーンショットを保存するときの、ファイル名の既定値
    Tests/HingeCtlAppKitTests/   # 偽のバックエンドで、接続・起こす・非対応・ドラッグの間引き・失敗の扱いなどを検証
  Packages/HingeCtlCore/         # CoreDevice に依存しない純粋なロジック(arm64 で swift test)
    Package.swift
    Sources/HingeCtlCore/
      Commands.swift             # コマンド定義(ParsableCommand)、共通オプション、Request
      Runner.swift               # runHingeCtl: 解釈して、サブコマンドなら executable に Request を渡す
      Validation.swift           # CLIError(実行時エラー)、角度の表示
      Limits.swift               # 値の範囲(HingeLimits。CLI の検証と GUI で共有)
      Posture.swift              # posture の読み取り結果(PostureSnapshot)
      Orientation.swift          # 向きの名前(OrientationName)、rotate の順序、posture の向きの欄(OrientationField)
      Sweep.swift                # sweep の送信計画(ステップ数・各角度・各時刻)
      DevicectlModels.swift      # devicectl の JSON を読む Decodable の DTO(内部用。寛容なデコード)
      Devices.swift              # 実機の一覧のデコード、-d による選択、対話式の問い合わせ、起こす順序と理由の判定
      Hinge.swift                # ヒンジへの対応の判定(HingeSupport)、HingeReading、firstElement、posture の角度
      Displays.swift             # ディスプレイのデコード、posture の表示
      JSONOutput.swift           # --json の出力の Encodable(AngleOutput / PostureOutput など)
    Tests/HingeCtlCoreTests/     # Swift Testing
```

## テスト

`make test` で、`HingeCtlCore` と `HingeCtlAppKit` の単体テストを実行します(`swift test --package-path Packages/...`)。対象は、引数の解釈(`parseAsRoot` で、実行せずに解釈だけを検証)、角度の検査、
向きの回転、`sweep` の計算、`devicectl` の JSON のデコードと実機の選択、ディスプレイの判定、`--json` の出力(バイト列の完全一致)です。
`HingeCtlAppKit` は、偽のバックエンドで、GUI の状態遷移(接続・起こす・非対応の扱い・ドラッグの間引きと流し切り・範囲外の入力・失敗)を検証します。
CoreDevice を呼ぶ部分(ヒンジ角・向きの読み書き)と `devicectl` の実行、SwiftUI の見た目は、実機が要るため、単体テストの対象外です(実機で確認します)。

GitHub Actions の CI(`.github/workflows/ci.yml`)では、PR や main へのプッシュ時に、macOS 27 ランナー上で `make test`、CLI のビルド(`make build`)とスモークテスト(`--version` / `--help`)、GUI アプリのビルド(`make app`)、配布用 DMG 作成(`make dmg`)が自動実行され、ビルド成果物がアーティファクトとして保存されます。

## 仕組み

`CoreDevice.framework` と `CoreDeviceUtilities.framework`(どちらも `/Library/Developer/PrivateFrameworks`)は arm64e 専用で、
Swift モジュール情報を持ちません。そこで次の方法で直接呼び出しています。

- `Interfaces/` に、使う型だけを手書きした `.swiftinterface` を置き、`-I` で読み込ませる(`Packages/HingeCtlDevice/Package.swift` の `unsafeFlags`)。
- フレームワークは `-F` / `-framework` でリンクし、`-rpath` で実行時の探索パスを渡す(同じく `unsafeFlags`。リンク設定は、依存する実行ファイルにも伝わる)。
- ビルドは arm64e で、`swift build --build-system native --triple arm64e-apple-macosx26.0` に `-Xswiftc -target` を足して使う(`make build`)。
- プロトコルの要件の並びは、バイナリ内の記述子のアドレス順から復元した(ウィットネステーブルのレイアウトを合わせるため)。

| 機能 | 使っている API |
| --- | --- |
| 引数の解釈 | swift-argument-parser(`HingeCtlCore/Commands.swift`) |
| デバイスの一覧・UDID・名前 | `devicectl list devices`(JSON。実機と、起動中のシミュレータ) |
| シミュレータの RemoteDevice | CoreDevice: `DeviceManager(serviceConnection:allowedDeviceVisibilityClasses:)` に `.simulators` を許可して作る(既定の `DeviceManager.shared` は、シミュレータを返さない) |
| ヒンジ角の読み取り | CoreDevice: `.monitorMotion` → `DeviceMotionManager.monitorHingeAngle(config:)` |
| ヒンジ角の設定 | CoreDevice: `.hid.vendorDefined` → `HIDVendorDefined.send(usagePage:usage:version:data:)` |
| 向き | CoreDevice: `.orientationControl` → `OrientationControl` |
| ディスプレイの状態 | `devicectl device info displays`(JSON) |
| スクリーンショット | `devicectl device capture screenshot` |

## JSON の扱い

JSON は、`JSONSerialization` と `[String: Any]` ではなく、`Decodable` / `Encodable` の構造体で扱います(キー名と型をコンパイルで保証)。

- **読む側**(`devicectl list devices` / `device info displays`): `DevicectlModels.swift` の DTO で読み、ドメインの型(`DeviceEntry` / `DisplayState`)に変換します。
  読み方は寛容です。型が違う・欠けた・`null` の項目だけが既定値になり、未知のキーは無視し、配列の壊れた要素だけが除外されます(`Lossy`)。
- **出力側**(`--json`): `JSONOutput.swift` の `Encodable` で、1 行・キー辞書順に出します。値が無い項目は、省略せず `null` で出します(`encodeNil`)。
- 小数は最短の表記になります(`119.96`。以前の実装は `119.95999999999999` と出していました。値は同じ Double です)。整数の値は `180` のように出ます。
- 注意: `IOCFSerialize` に渡す HID のペイロード(`DeviceAccess.swift` の `[String: Any]`)は、JSON ではなくプロパティリストのため、辞書のままです。

## GUI の開発

- **アイコン**: `HingeCtlApp/Sources/AppIcon.icon`(Icon Composer 形式)です。ライト/ダークは、背景色だけを `icon.json` の `fill` で切り替えます(絵は共通)。
  `.appiconset` では、macOS 向けのダーク用の画像が無視されるため、この形式にしています。絵の元は `HingeCtlApp/Icon/AppIcon.template.svg` だけです。
  変えたときは `Scripts/render-icon.sh` を実行して、`AppIcon-{light,dark}.svg`(README のロゴ)・`AppIcon.icon/icon.json`・
  `AppIcon.icon/Assets/device.png` を、まとめて作り直します(生成物も、コミットします)。ライト/ダークの背景色は、このスクリプトだけが持っています。
- App Sandbox は有効にしていません(非公開 API の直接呼び出しや `xcrun devicectl` プロセス起動のため)。署名は ad-hoc で、配布は想定していません。
- Xcode プロジェクト(`HingeCtlApp/HingeCtlApp.xcodeproj`)は、`HingeCtlApp/project.yml` から、[XcodeGen](https://github.com/yonaskolb/XcodeGen) で生成します
  (生成物はコミットしていません。`make app` が、毎回生成します)。XcodeGen の版は、ルートの `Mintfile` で固定しており、[mint](https://github.com/yonaskolb/Mint)
  (`brew install mint`)が要ります。Xcode で開くには、先に `make generate-xcodeproj` を実行してください。
  ソースのフォルダを「フォルダ同期グループ」で参照するため、ソースファイルの追加・削除では、再生成は要りません。ターゲットやビルド設定を変えたときだけ、`project.yml` を直します。

### 文言管理(String Catalog)

画面の表示文言は、Xcode 16 / 27 標準の String Catalog(`HingeCtlApp/Sources/Localization/*.xcstrings`)で管理しています。

- **ファイル分割による名前空間**: 単一の `Localizable.xcstrings` ではなく、セクション・機能ごとに 8 つのカタログファイル(`General`, `Sidebar`, `HingeAngle`, `Sweep`, `Orientation`, `Posture`, `Screenshot`, `Log`)に分割しています。
- **型安全なシンボル生成**: `HingeCtlApp/project.yml` で `STRING_CATALOG_GENERATE_SYMBOLS: YES` を指定しているため、Xcode がビルド時に `.[TableName].[key]`(例: `.General.appName`、`.HingeAngle.close`)という型安全な enum シンボルを自動生成します(遅延評価の `LocalizedStringResource` / `Text` として渡せる)。
  - カタログのファイル名は、SwiftUI 標準の型(例: `Angle`)との衝突を避けるため、`HingeAngle.xcstrings` のように固有の UpperCamelCase にしています。
- **ビルド時の意図しない書き換え防止**: `SWIFT_EMIT_LOC_STRINGS: NO` を指定し、ビルド時にコンパイラが勝手にソースコードからキーを抽出して `.xcstrings` を書き換える(意図しない Git 差分が出る)のを防止しています。
- **撮影時の言語強制**: スクリーンショット撮影(`make screenshots`)では、多言語環境下でも英語での撮影を保証するため、起動引数に `-AppleLanguages '(en)'` を渡して実行しています。

### スクリーンショットの自動生成

README の GUI のスクリーンショット(`docs/images/gui-{light,dark}.png`)は、UI を直すたびに、自動で撮り直せます。

```bash
make screenshots
```

- 実機は要りません。`HingeCtl.app` を、起動引数 `--screenshot-mode <出力先>` で起動すると、`LiveBackend` の代わりに `MockBackend`(`HingeCtlApp/Sources/Mock/MockBackend.swift`)が使われます。
  デバイスの一覧・ヒンジ角(118.4°)・posture は固定の値で、何度撮っても、同じ画像になります。
- `ScreenshotRunner`(`HingeCtlApp/Sources/ScreenshotRunner.swift`)が、1 台目を選んで接続し、ウィンドウを撮影用の大きさにして、ライトとダークの順に撮ります。
- 設定(ウィンドウの位置・サイドバーの幅・ログ欄の開閉)を、普段の HingeCtl の設定に書き込まないよう、`.app` を `.tmp/screenshot-app/` へコピーし、
  Bundle ID を `com.example.HingeCtl.screenshot` に替えて(別の設定の領域になります)、ad-hoc で署名し直してから実行します。撮影の前後に、その領域は消します。
  (`CFFIXED_USER_HOME` を替える方法は、効きませんでした。cfprefsd が、実際のホームに書くためです。)
- **撮影には、1040×800 pt 以上の表示領域が要ります。** ウィンドウは 1040×800 pt に固定で、画面の表示領域(メニューバーと Dock を除く)がこれより小さいと、
  下の項目が切れた画像を書かず、エラーで止まります。
- **撮影中は、画面全体を、単色のウィンドウ(ライトは白、ダークは黒)が覆います(数秒)。** サイドバーは半透明で、背後のデスクトップや他のウィンドウを透かすため、
  背後を固定しないと、実行のたびに画像が変わり、背後の内容も映り込みます。撮影用のウィンドウは、アプリのウィンドウの真後ろに置くので、他のアプリのウィンドウは、さらにその後ろになります。
- **画像は、撮った Mac に少し依存します。** PNG の画素数は、ディスプレイの倍率(1x なら 1040×800、Retina なら 2 倍)で変わります。
  サイドバーの選択色は、その Mac のアクセントカラーです。別の環境で撮り直すと、画像の差分が出ます。
- 画面の文言(`Localization/*.xcstrings`)は、撮影用に変えません(実画面のまま。撮影時は `-AppleLanguages '(en)'` で英語表示を強制)。UI を変えたら、`make screenshots` で撮り直して、画像もコミットしてください。
- **撮り方**: ウィンドウサーバーが合成した、自分のウィンドウの画像を使います(`CGWindowListCreateImage`)。
  - `NSView.cacheDisplay` や `CALayer.render` は、SwiftUI のリストとスクロール領域が空白になるため、使えませんでした。
  - ScreenCaptureKit は、自分のウィンドウでも、画面収録の許可を求めます(許可が無いと失敗します)。
  - `CGWindowListCreateImage` は、SDK では使用不可と宣言されているため、実行時に `dlsym` で探して呼びます。システムからは、まだ消えていません。
    将来の macOS で消えたときは、ScreenCaptureKit に替えてください(その場合は、`make screenshots` を実行するアプリに、画面収録の許可が要ります)。

## 配布用の DMG

```bash
make dmg    # → .build/HingeCtl-<バージョン>.dmg(バージョンは、アプリの Info.plist の値)
```

- 標準の `hdiutil` と `sips` だけを使います。追加のツールは要りません。
- 中身は、`HingeCtl.app`、`/Applications` へのシンボリックリンク、背景画像(`.background/background.png`)、Finder が読む `.DS_Store` です。
  背景画像は、`Scripts/dmg/background.svg` から `sips` で作ります。
- 署名は ad-hoc で、公証はしません。インターネットで配ると、受け取った人の Mac では、Gatekeeper の確認(右クリックの「開く」など)が要ります。
  確認なしで開けるようにするには、Developer ID での署名と、公証(`notarytool`・`stapler`)が要ります。
- 背景は 1x の PNG(660×400)で、Retina では少しぼやけます。高解像度にするには、背景のファイル名(エイリアスの指す先)を変えずに、画像だけを大きくする方法を、別に考える必要があります。

### ウィンドウの見た目(`.DS_Store` のテンプレート)

アイコンの位置・ウィンドウの大きさ・背景画像は、Finder が `.DS_Store` から読みます。`make dmg` は、作成済みの `Scripts/dmg/DS_Store` を、毎回コピーするだけです。
ビルド時にはライブラリも書き込み用のコードも不要です。

| 項目 | 値 |
| --- | --- |
| ボリューム名 | `HingeCtl` |
| `HingeCtl.app` のアイコン | x=160, y=190 |
| `Applications` のアイコン | x=500, y=190 |
| ウィンドウ(上・左・下・右) | 120, 120, 520, 780(ウィンドウは 660×400) |
| 表示 | アイコン表示。背景は画像 `.background/background.png` |

- **背景画像の指し方**: `icvp` レコードの `backgroundImageAlias`(Carbon のエイリアス)で、`.background/background.png` を指します(Finder は、ブックマークのデータを受け付けません)。
  エイリアスは、ボリューム名・ファイルのパスなどを含みます。テンプレートは、別に作った DMG(ボリュームの作成日時が違う)でも、背景が出ることを、Finder で確かめてあります。
  これは、Finder の、文書化されていない挙動に頼っています。macOS の更新で効かなくなったら、テンプレートを作り直してください。
- **作り直すとき**(レイアウトや背景のファイル名・ボリューム名を変えたときも):
  1. 上の表の内容で、書き込み可能な DMG(`hdiutil create -format UDRW`)を作って、マウントする。背景画像は、`.background/background.png` に置いておく。
  2. マウント中のボリュームに、`.DS_Store` を書く。方法は、どちらでも構いません。
     - Finder で、ウィンドウを開き、アイコンの位置・大きさ・背景を、手で設定する(Finder が `.DS_Store` を書く)。
     - `.DS_Store` を書けるライブラリを、使い捨てのフォルダ(`.tmp` など)で使う。今回は、[sindresorhus/DSStore](https://github.com/sindresorhus/DSStore) 1.0.0 で作りました。
       `setIconPosition`・`setWindowBounds`・`setViewStyle(.iconView)`・`setBackgroundPicture(imageURL:relativeTo:)` を呼んで、`write(to:)` します。
       背景のエイリアスは、ボリュームが**マウント中**でないと、正しく作れません。このライブラリは、プロジェクトの依存ではありません。
  3. できた `.DS_Store` を、`Scripts/dmg/DS_Store` に置き換える。
  4. `make dmg` で DMG を作り、Finder で開いて、見た目を確かめる(アイコンの位置・ウィンドウの大きさ・背景)。
- **中身の確認**: `.DS_Store` は、`Bud1` のヘッダを持つ、Buddy アロケータと B 木の形式です(Apple は仕様を公開していません)。
  `Iloc`(アイコンの位置)、`fwi0`(ウィンドウの大きさ)、`icvp`(表示の設定と背景)、`vstl`(表示の種類)の 4 種類のレコードが入っています。

## ビルドの注意

- **パッケージを分けている理由**: CoreDevice は arm64e 専用のため、`hingectl` は arm64e でビルドします。一方、テストを実行する
  `xctest` / `swiftpm-testing-helper` は arm64(と x86_64)のみで、arm64e のテストバンドルは読み込めません。
  そこで、テストする純粋なロジック(コマンド定義を含む)や GUI の状態管理を、CoreDevice に依存しない別パッケージ(`Packages/HingeCtlCore`・`Packages/HingeCtlAppKit`)に分けています。
  executable をビルドするときは arm64e、テストのときは arm64 でビルドされます。
- **swift-argument-parser は `Packages/HingeCtlCore` にだけ依存させています**(`exact: "1.8.2"`)。コマンド定義を Core に置くことで、arm64 の
  `swift test` で解釈をテストでき、ルートの executable には依存を足さずに済みます。テストが、ライブラリの英語のエラーメッセージに依存するため、版を固定しています。
- **`--build-system native` を使っている理由**: Xcode 27.1 の `swift build` の既定のビルドシステム(`swiftbuild`)は、`--triple arm64e…` を
  無視して x86_64 / arm64 でビルドし、手書きインターフェースを読めずに失敗します(`-Xswiftc -target` を足すとコンパイルは通りますが、
  x86_64 側のリンクで失敗します)。`native` だけが arm64e を作れます。
- **`-Xswiftc -target -Xswiftc arm64e-apple-macosx26.0` を足している理由**: swift-argument-parser は `platforms` を宣言していないため、`--triple` の
  macOS 26.0 が伝わらず、macOS 12.0 向けにビルドされます。すると arm64e のクラスのポインタ署名(`class_ro`)が、ほかのモジュールと食い違い、
  ld が `class_ro_t pointer signing` の警告を出して、署名フラグを落とします(動作はしますが、保護が弱まります)。`-Xswiftc -target` で、依存を含む全モジュールを
  26.0 に揃えると、警告は出ず、全モジュールが署名ありになります。`-Xswiftc -Xfrontend -Xswiftc -sign-class-ro` で署名を強制する方法は、起動直後に SIGBUS で落ちるため、使えません。
- **GUI は Xcode プロジェクトで、ソースを直接取り込んでいます**: Xcode のパッケージ依存のターゲットは、プロジェクトの `ARCHS`(arm64e)を無視して arm64 でビルドされ、
  arm64e 専用の CoreDevice のインターフェースを読めずに失敗します(コマンドラインで `ARCHS=arm64e` を渡せば通りますが、IDE からは通りません)。
  そこで、`Packages/` のソースのフォルダを、静的ライブラリのターゲットとして取り込み、`ARCHS = arm64e` をプロジェクトの設定にしています。
  同じソースを、SwiftPM(CLI)と Xcode(GUI)の 2 つのビルドが作るため、`make app` と `make build` の両方が通ることを確かめてください。
  CoreDevice は、`HingeCtlDevice` の中だけで `@_implementationOnly import` し、GUI のコードには出しません。
- **`native` のビルドは、依存パッケージにソースファイルを追加しても変更を検出できないことがあります**(`cannot find ... in scope` になります)。`make clean` してから、ビルドし直してください。
- **`native` は deprecated です**(「将来のリリースで削除される」という警告が出ます)。削除されると `make build` は動かなくなります。
  以前は、`swiftc` を直接呼ぶ手順を代替として確認していましたが、swift-argument-parser を導入したため、その手順はそのままでは使えません
  (Core のソースが `import ArgumentParser` するため、ArgumentParser も同じ方法でビルドして、リンクする必要があります)。代替の手順は、まだ確認していません。
