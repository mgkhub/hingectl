.PHONY: test clean

# 純粋なロジックのテスト(arm64。CoreDevice には依存しない)。
# HingeCtlCore(引数の解釈・計算・解析)。
test:
	swift test --package-path Packages/HingeCtlCore

clean:
	rm -rf Packages/HingeCtlCore/.build
