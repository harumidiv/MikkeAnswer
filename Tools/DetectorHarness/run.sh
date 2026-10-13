#!/bin/zsh
# DifferenceDetector を macOS 上でビルドして実行する。
# 使い方: Tools/DetectorHarness/run.sh [画像ファイル ...]
#   画像を省略すると合成した間違い探し画像で正解と照合する。結果は .build/*_result.png に出力。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/Tools/DetectorHarness/.build"
SRC="$ROOT/MikkeAnswer/Detection"
mkdir -p "$OUT"

xcrun -sdk macosx metal -c "$SRC/DifferenceShaders.metal" -o "$OUT/shaders.air"
xcrun -sdk macosx metallib "$OUT/shaders.air" -o "$OUT/default.metallib"
xcrun -sdk macosx swiftc -O \
    "$SRC/DetectionTypes.swift" "$SRC/DifferenceDetector.swift" "$SRC/ResultRenderer.swift" \
    "$ROOT/Tools/DetectorHarness/main.swift" -o "$OUT/harness"

"$OUT/harness" "$OUT" "$@"
