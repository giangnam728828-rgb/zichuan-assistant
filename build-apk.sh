#!/bin/bash
# 构建并签名「子川助手」APK（不依赖 Gradle，用 Android build-tools + JDK）。
#
#   bash build-apk.sh                 # 版本号取环境变量，默认 1.0.0 / 1
#   VERSION_NAME=1.0.2 VERSION_CODE=3 bash build-apk.sh
#
# 产物：dist/zichuan-assistant-<version>.apk（用固定 release keystore 签名）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK="${ANDROID_SDK:-/root/android-sdk}"
BT="${ANDROID_BUILD_TOOLS:-$SDK/android-14}"
PLATFORM="$SDK/android-34/android.jar"
KS="${KEYSTORE:-$ROOT/keystore/zichuan-release.jks}"
KS_PASS="${KEYSTORE_PASSWORD:-ZichuanRel2026!}"
KS_ALIAS="${KEYSTORE_ALIAS:-zichuan}"
VERSION_NAME="${VERSION_NAME:-1.0.0}"
VERSION_CODE="${VERSION_CODE:-1}"

APP="$ROOT/app/src/main"
WORK="$ROOT/build"
DIST="$ROOT/dist"
rm -rf "$WORK"
mkdir -p "$WORK/gen" "$WORK/classes" "$WORK/dex" "$DIST"

echo "== 1-2/6 资源 + manifest 打包 (aapt v1, arm64)"
"${AAPT:-aapt}" package -f -m \
  -M "$APP/AndroidManifest.xml" \
  -S "$APP/res" \
  -I "$PLATFORM" \
  -J "$WORK/gen" \
  -F "$WORK/base.apk" \
  --version-code "$VERSION_CODE" \
  --version-name "$VERSION_NAME"

echo "== 3/6 编译 Java (javac --release 8 -Xlint:-options)"
find "$WORK/gen" "$APP/java" -name "*.java" > "$WORK/sources.txt"
javac --release 8 -Xlint:-options -encoding UTF-8 -classpath "$PLATFORM" -d "$WORK/classes" @"$WORK/sources.txt"

echo "== 4/6 转 dex (d8)"
"${D8:-$BT/d8}" --release --lib "$PLATFORM" --min-api 26 --output "$WORK/dex" $(find "$WORK/classes" -name "*.class")

echo "== 5/6 打包 + 对齐"
python3 - "$WORK/base.apk" "$WORK/dex/classes.dex" <<'PY'
import shutil, sys, zipfile
src, dex = sys.argv[1], sys.argv[2]
shutil.copy(src, src + '.tmp')
with zipfile.ZipFile(src + '.tmp', 'a', zipfile.ZIP_DEFLATED) as z:
    z.write(dex, 'classes.dex')
shutil.move(src + '.tmp', src)
print('  classes.dex 已写入')
PY
"${ZIPALIGN:-zipalign}" -f -p 4 "$WORK/base.apk" "$WORK/aligned.apk"

echo "== 6/6 固定签名 (apksigner, v1+v2+v3)"
OUT="$DIST/zichuan-assistant-$VERSION_NAME.apk"
"${APKSIGNER:-apksigner}" sign \
  --ks "$KS" --ks-pass "pass:$KS_PASS" --ks-key-alias "$KS_ALIAS" \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --out "$OUT" "$WORK/aligned.apk"

"${APKSIGNER:-apksigner}" verify --print-certs "$OUT" | sed -n '1,8p'
echo
echo "产物: $OUT"
echo "大小: $(du -h "$OUT" | cut -f1)"