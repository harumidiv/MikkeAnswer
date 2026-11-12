#!/bin/zsh
# 英語で撮った画面（captures/）に各言語の見出しを付けて、App Store 用のスクリーンショットを書き出す。
#   ./render.sh                 全言語・全端末
#   ./render.sh en de           指定した言語だけ
#   DEVICES_ONLY=ipad ./render.sh   指定した端末だけ（iphone63 / ipad / duo）
# 出力: ../localized/<言語>/<端末>/<画面>.jpg
set -euo pipefail

cd "${0:A:h}"
EDGE="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
OUT="../localized"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 端末: 撮影画像の接頭辞 出力フォルダ 幅 高さ 描画倍率（幅 ÷ 倍率 が 500 以上になるように）
DEVICES=(
  "iphone63 iPhone_6.3inch 1206 2622 2"
  "ipad iPad_13inch 2064 2752 2"
  "duo iPhoneDuo 2007 2853 3"
)
SCREENS=(01_result 02_overlay-diff 03_overlay 04_editor 05_detail)

if (( $# > 0 )); then
  LANGS=("$@")
else
  LANGS=(${(f)"$(grep -oE '^  "[A-Za-z-]+": \[' captions.js | sed -E 's/^  "([^"]+)".*/\1/')"})
fi

for lang in $LANGS; do
  for entry in $DEVICES; do
    read device folder width height scale <<< "$entry"
    # DEVICES_ONLY="iphone63 ipad" のように指定すると、その端末だけ書き出す
    if [[ -n "${DEVICES_ONLY:-}" && " $DEVICES_ONLY " != *" $device "* ]]; then continue; fi
    mkdir -p "$OUT/$lang/$folder"
    for i in {1..${#SCREENS}}; do
      screen=${SCREENS[$i]}
      shot="$PWD/captures/${device}_${screen}.png"
      [[ -f "$shot" ]] || { echo "撮影画像がありません: $shot" >&2; exit 1; }
      png="$TMP/out.png"
      # 普段使いの Edge と取り合わないよう専用のプロファイルで開き、たまに失敗するので 3 回まで試す
      for attempt in 1 2 3; do
        rm -f "$png"
        "$EDGE" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
          --user-data-dir="$TMP/profile" --no-first-run \
          --force-device-scale-factor=$scale --window-size=$((width / scale)),$((height / scale)) \
          --virtual-time-budget=10000 --screenshot="$png" \
          "file://$PWD/screenshot.html?device=$device&lang=$lang&screen=$((i - 1))&shot=file://$shot" \
          >/dev/null 2>&1 || true
        [[ -s "$png" ]] && break
      done
      [[ -s "$png" ]] || { echo "書き出しに失敗しました: $lang $device $screen" >&2; exit 1; }
      # 透過なしの JPEG にする（App Store Connect はアルファ付きを受け付けない）
      sips -s format jpeg -s formatOptions 92 "$png" --out "$OUT/$lang/$folder/$screen.jpg" >/dev/null
    done
  done
  echo "$lang 完了"
done
