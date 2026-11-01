#!/bin/bash
# アプリアイコンを、1 つの元(HingeCtlApp/Icon/AppIcon.template.svg)から作り直す。UI のアイコンの絵を変えたときだけ実行する。
# 作るもの(いずれもコミットする):
#   HingeCtlApp/Icon/AppIcon-{light,dark}.svg                README のロゴ(背景色だけが違う)
#   HingeCtlApp/Sources/AppIcon.icon/icon.json               ライト/ダークの背景色(fill)
#   HingeCtlApp/Sources/AppIcon.icon/Assets/device.png       背景なしのデバイスの絵(背景は icon.json の fill で切り替える)
# 背景色は、このスクリプトの BACKGROUND_LIGHT / BACKGROUND_DARK だけが持つ。絵を変えるときは、テンプレートだけを直す。
# 使い方: Scripts/render-icon.sh   (macOS 標準の sips だけを使う。追加のインストールは要らない)
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=.tmp/icon
mkdir -p "$WORK"

BACKGROUND_LIGHT=eef0f4 BACKGROUND_DARK=0b1226 python3 - <<'PY'
import json, os

template = open("HingeCtlApp/Icon/AppIcon.template.svg").read()
marker = '  <rect width="140" height="140" rx="32" fill="{{BACKGROUND}}"/>\n'
assert marker in template, "background rect not found in the template"
colors = {"light": os.environ["BACKGROUND_LIGHT"], "dark": os.environ["BACKGROUND_DARK"]}

# README のロゴ(背景つき)
for mode, color in colors.items():
    open(f"HingeCtlApp/Icon/AppIcon-{mode}.svg", "w").write(template.replace("{{BACKGROUND}}", f"#{color}"))

# アプリアイコンの絵(背景なし)を、1024px のキャンバスに拡大して置く(sips が PNG にする)
body = template.replace(marker, "").split("\n", 2)[2].rsplit("</svg>", 1)[0]
open(".tmp/icon/device.svg", "w").write(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024"><g transform="scale({1024/140})">{body}</g></svg>')

# ライト/ダークの背景色(Icon Composer の fill)
def srgb(hex_color):
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"

icon = {
    "fill": {"solid": srgb(colors["light"])},
    "fill-specializations": [{"appearance": "dark", "value": {"solid": srgb(colors["dark"])}}],
    "groups": [{"layers": [{"glass": False, "image-name": "device.png", "name": "device"}]}],
    "supported-platforms": {"squares": "shared"},
}
open("HingeCtlApp/Sources/AppIcon.icon/icon.json", "w").write(json.dumps(icon, indent=2, ensure_ascii=False) + "\n")
PY

# SVG の描画は macOS の CoreSVG。透過は保たれる
sips -s format png "$WORK/device.svg" --out HingeCtlApp/Sources/AppIcon.icon/Assets/device.png >/dev/null
echo "Wrote HingeCtlApp/Icon/AppIcon-{light,dark}.svg, AppIcon.icon/icon.json, AppIcon.icon/Assets/device.png"
