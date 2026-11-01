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

.PHONY: build test clean

build:
	$(WITH_XCODE) swift build -c release --build-system native --triple $(TRIPLE) $(SWIFTC_TARGET) --product hingectl
	@echo "Build complete: $(CURDIR)/$(BIN)"

# 純粋なロジックのテスト(arm64。CoreDevice には依存しない。Xcode は選択中のものを使う)。
# HingeCtlCore(引数の解釈・計算・解析)と、HingeCtlAppKit(GUI の状態管理。偽のバックエンドで検証する)。
test:
	swift test --package-path Packages/HingeCtlCore
	swift test --package-path Packages/HingeCtlAppKit

clean:
	rm -rf .build .tmp Packages/HingeCtlCore/.build Packages/HingeCtlDevice/.build Packages/HingeCtlAppKit/.build
