# 実行ファイルのビルド(make build)には Xcode 27.0 以降(Swift 6.4)が要る(それ以前の Xcode は、CoreDevice の interface をビルドできず失敗する)。
# 使う Xcode は、Scripts/with-xcode.sh が決める(優先順位は、そのスクリプトの冒頭を参照)。
# 別の Xcode を使うときは
#   make build DEVELOPER_DIR=/Applications/Xcode-XX.app/Contents/Developer
MIN_XCODE := 27.0
WITH_XCODE := Scripts/with-xcode.sh $(MIN_XCODE)

# CoreDevice は arm64e 専用のため、arm64e でビルドする。
# Xcode 27.1 の既定のビルドシステム(swiftbuild)は arm64e を指定できず(--triple を無視して
# x86_64 / arm64 でビルドする)、`native` だけが指定どおりに arm64e を作れる。
# `native` は deprecated のため、将来削除されたら、このビルドは動かなくなる(README を参照)。
TRIPLE := arm64e-apple-macosx26.0
BIN := .build/arm64e-apple-macosx/release/hingectl

# swift-argument-parser は `platforms` を宣言していないため、`--triple` の macOS 26.0 が伝わらず、macOS 12.0 向けに
# ビルドされる。すると arm64e のクラスのポインタ署名(class_ro)が、ほかのモジュールと食い違い、ld が警告を出して
# 署名フラグを落とす(動作はするが、保護が弱まる)。`-Xswiftc -target` で、依存を含む全モジュールを 26.0 に揃える。
# (`-Xswiftc -Xfrontend -Xswiftc -sign-class-ro` は、起動直後に SIGBUS で落ちるため使わない)
SWIFTC_TARGET := -Xswiftc -target -Xswiftc $(TRIPLE)

# GUI(HingeCtlApp)は Xcode プロジェクト。Xcode 27.0 以降が要る(CLI と同じ理由)。成果物は .build/xcode の下に作る。
# プロジェクトは HingeCtlApp/project.yml から、XcodeGen(版は Mintfile で固定)で生成する。mint が要る(`brew install mint`)。
APP_PROJECT := HingeCtlApp/HingeCtlApp.xcodeproj
APP_DERIVED := .build/xcode
APP_BUNDLE := $(APP_DERIVED)/Build/Products/Release/HingeCtl.app

.PHONY: build test clean app run-app screenshots dmg generate-xcodeproj

build:
	$(WITH_XCODE) swift build -c release --build-system native --triple $(TRIPLE) $(SWIFTC_TARGET) --product hingectl
	@echo "Build complete: $(CURDIR)/$(BIN)"

# 純粋なロジックのテスト(arm64。CoreDevice には依存しない。Xcode は選択中のものを使う)。
# HingeCtlCore(引数の解釈・計算・解析)と、HingeCtlAppKit(GUI の状態管理。偽のバックエンドで検証する)。
test:
	swift test --package-path Packages/HingeCtlCore
	swift test --package-path Packages/HingeCtlAppKit

app: generate-xcodeproj
	$(WITH_XCODE) xcodebuild -project $(APP_PROJECT) -scheme HingeCtlApp -configuration Release -derivedDataPath $(APP_DERIVED) -quiet build
	@echo "Build complete: $(CURDIR)/$(APP_BUNDLE)"

run-app: app
	open $(APP_BUNDLE)

# 配布用の DMG(アプリと、/Applications へのショートカットを並べたもの)。標準の hdiutil と sips だけを使う。
# ウィンドウの見た目(アイコンの位置・ウィンドウの大きさ・背景画像)は、Finder が読む .DS_Store に入る。
# それは、Scripts/dmg/DS_Store(作成済みのテンプレート)をコピーして使う。作り方と中身は、docs/DEVELOPMENT.md の「配布用の DMG」を参照。
# テンプレートは、ボリューム名(DMG_VOLUME)・ファイル名(HingeCtl.app / Applications)・背景の置き場所(.background/background.png)を
# キーにして、レイアウトと背景を指すため、これらを変えるときは、テンプレートも作り直す。
# 署名は ad-hoc で、公証はしない(受け取った人の Mac では、Gatekeeper の確認が要る)。
# 出力: .build/HingeCtl-<バージョン>.dmg(バージョンは、アプリの Info.plist の値)
DMG_VOLUME := HingeCtl
DMG_STAGE := $(CURDIR)/.tmp/dmg-stage
DMG_ASSETS := Scripts/dmg

dmg: app
	version=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $(APP_BUNDLE)/Contents/Info.plist) && \
	dmg=.build/$(DMG_VOLUME)-$$version.dmg && \
	rm -rf $(DMG_STAGE) && mkdir -p $(DMG_STAGE)/.background && \
	cp -R $(APP_BUNDLE) $(DMG_STAGE)/ && \
	ln -s /Applications $(DMG_STAGE)/Applications && \
	sips -s format png $(DMG_ASSETS)/background.svg --out $(DMG_STAGE)/.background/background.png >/dev/null && \
	cp $(DMG_ASSETS)/DS_Store $(DMG_STAGE)/.DS_Store && \
	rm -f $$dmg && \
	hdiutil create -volname $(DMG_VOLUME) -srcfolder $(DMG_STAGE) -format UDZO $$dmg && \
	echo "Build complete: $(CURDIR)/$$dmg"

# README 用の GUI のスクリーンショット(docs/images/gui-{light,dark}.png)を、モックのデータで自動で撮る。UI を変えたら、撮り直す。
# 実機は要らず、画面収録の許可も要らない(自分のウィンドウを自分で描く)。
# 設定(ウィンドウの位置・サイドバーの幅・ログ欄の開閉)を、普段の HingeCtl の設定に書き込まないよう、
# .app を .tmp の下へコピーし、Bundle ID を撮影用に替えて(別の設定の領域になる)、署名し直してから実行する。
# (CFFIXED_USER_HOME では、設定は分かれない: cfprefsd が、実際のホームに書く)
SCREENSHOT_DIR := docs/images
SCREENSHOT_APP := $(CURDIR)/.tmp/screenshot-app/HingeCtl.app
SCREENSHOT_ID := com.example.HingeCtl.screenshot

screenshots: app
	mkdir -p $(SCREENSHOT_DIR)
	rm -rf $(dir $(SCREENSHOT_APP)) && mkdir -p $(dir $(SCREENSHOT_APP))
	cp -R $(APP_BUNDLE) $(SCREENSHOT_APP)
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(SCREENSHOT_ID)" $(SCREENSHOT_APP)/Contents/Info.plist
	codesign --force --deep --sign - $(SCREENSHOT_APP)
	defaults delete $(SCREENSHOT_ID) 2>/dev/null || true
	$(SCREENSHOT_APP)/Contents/MacOS/HingeCtl --screenshot-mode $(SCREENSHOT_DIR) -AppleLanguages '(en)'
	defaults delete $(SCREENSHOT_ID) 2>/dev/null || true

# project.yml を変えたときと、チェックアウトの直後(生成物はコミットしていない)に要る。ソースファイルの追加・削除は不要。
# `make app` は、毎回これを実行する。
generate-xcodeproj:
	@command -v mint >/dev/null || { echo "mint is required: brew install mint" >&2; exit 1; }
	mint run xcodegen generate --spec HingeCtlApp/project.yml --quiet

clean:
	rm -rf .build .tmp Packages/HingeCtlCore/.build Packages/HingeCtlDevice/.build Packages/HingeCtlAppKit/.build
