#!/bin/bash
# 使い方: with-xcode.sh <最小バージョン> <コマンド> [引数...]
#
# ビルドに使う Xcode(最小バージョン以上)を決めて、DEVELOPER_DIR をそのコマンドにだけ渡して実行する。
# 優先順位:
#   1. DEVELOPER_DIR が指定済み: 要件を満たすか確かめて、そのまま使う(満たさなければ失敗)
#   2. xcode-select で選択中の Xcode が要件を満たす: DEVELOPER_DIR は設定しない
#   3. 満たさない: xcodes があれば、`xcodes installed` から、要件を満たす最新の正式版(ベータ・RC を除く)を探す
#   4. 見つからない: 案内を出して失敗する
# xcode-select の選択や、インストール済みの Xcode は変更しない(読み取りだけ)。
#
# テスト用: XCODE_SELECT_PATH で、`xcode-select -p` の結果を差し替えられる(DEVELOPER_DIR 未指定のときだけ使う)。

set -u

min=$1
shift

# 引数 1(…/Contents/Developer か、…/Xcode.app。xcrun はどちらの DEVELOPER_DIR も受け付ける)の Xcode のバージョン。
# 分からなければ失敗(Command Line Tools など)
xcode_version() {
    local dir=${1%/} plist
    case $dir in
        *.app) plist=$dir/Contents/version.plist ;;
        *) plist=$dir/../version.plist ;;
    esac
    [ -f "$plist" ] || return 1
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null
}

satisfies() {
    local version
    version=$(xcode_version "$1") || return 1
    [ -n "$version" ] || return 1
    [ "$(printf '%s\n%s\n' "$min" "$version" | sort -V | head -n 1)" = "$min" ]
}

fail() {
    echo "hingectl: $*" >&2
    exit 1
}

if [ -n "${DEVELOPER_DIR:-}" ]; then
    satisfies "$DEVELOPER_DIR" ||
        fail "DEVELOPER_DIR=${DEVELOPER_DIR} is not Xcode ${min} or later (version: $(xcode_version "$DEVELOPER_DIR" || echo unknown))."
    exec "$@"
fi

selected=${XCODE_SELECT_PATH:-$(xcode-select -p 2>/dev/null)}
if [ -n "$selected" ] && satisfies "$selected"; then
    exec "$@"
fi

hint="Set DEVELOPER_DIR=/Applications/Xcode-XX.app/Contents/Developer to Xcode ${min} or later, or select it with xcode-select."
selected_text="Selected Xcode: ${selected:-none} (version: $([ -n "$selected" ] && xcode_version "$selected" || echo unknown))."

command -v xcodes >/dev/null 2>&1 ||
    fail "${selected_text} xcodes was not found. ${hint}"

# `xcodes installed` の行: `<バージョン> (<ビルド>) [<アーキテクチャ>] [(Selected)]<TAB><パス>`。
# バージョンの直後が `(ビルド)` の行だけが正式版(ベータ・RC は `Beta` / `Release Candidate` が入る)。
# xcodes は /Applications だけを探す。
found=$(xcodes installed --no-color 2>/dev/null |
    awk -F'\t' '$1 ~ /^[0-9][0-9.]* \(/ { split($1, head, " "); print head[1] "\t" $2 }' |
    sort -V -k1,1 -r |
    while IFS=$'\t' read -r _ path; do
        if satisfies "$path/Contents/Developer"; then
            echo "$path/Contents/Developer"
            break
        fi
    done)

[ -n "$found" ] ||
    fail "${selected_text} xcodes found no release Xcode ${min} or later in /Applications. Install one with: xcodes install ${min}. Or: ${hint}"

echo "hingectl: using Xcode $(xcode_version "$found") (${found}, resolved by xcodes)" >&2
DEVELOPER_DIR=$found exec "$@"
