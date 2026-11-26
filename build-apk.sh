#!/bin/bash
# 构建并签名「子川助手」原生 Flutter/Kotlin APK。
#
#   bash build-apk.sh                 # 版本名取 app/pubspec.yaml，版本号自动递增
#   VERSION_NAME=2.0.1 VERSION_CODE=12345678 bash build-apk.sh
#
# 产物：dist/zichuan-assistant-<version>.apk（保留现有 release signer）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KS="${KEYSTORE:-$ROOT/keystore/zichuan-release.jks}"
# 签名材料不进仓库：keystore 与密码都由环境变量传入（CI 用 Secrets，本地放仓库外）。
KS_PASS="${KEYSTORE_PASSWORD:-}"
KS_ALIAS="${KEYSTORE_ALIAS:-zichuan}"
# 版本名跟 pubspec.yaml 走（app_info.dart 的默认值与之同步），避免脚本里再写死一份。
VERSION_NAME="${VERSION_NAME:-$(sed -n 's/^version: \([0-9][^+ ]*\).*/\1/p' "$ROOT/app/pubspec.yaml" | head -1)}"
[[ -n "$VERSION_NAME" ]] || { echo "读不到 app/pubspec.yaml 的版本名" >&2; exit 1; }
VERSION_CODE="${VERSION_CODE:-}"

# Build the independent Flutter/Kotlin app. Gradle reads the existing signer only
# from the environment; the password is never written to a properties file or log.
[[ -f "$KS" ]] || { echo "找不到 release keystore" >&2; exit 1; }
[[ -n "$KS_PASS" && -n "$KS_ALIAS" ]] || { echo "缺少 release signing configuration" >&2; exit 1; }
build_args=(--no-companion --build-name "$VERSION_NAME")
if [[ -n "$VERSION_CODE" && "$VERSION_CODE" != 1 ]]; then
  build_args+=(--build-number "$VERSION_CODE")
fi
export KEYSTORE="$KS" KEYSTORE_PASSWORD="$KS_PASS" KEYSTORE_ALIAS="$KS_ALIAS"
unset KS_PASS VERSION_CODE
bash "$ROOT/tooling/build-apk.sh" "${build_args[@]}"

apk="$ROOT/app/build/app/outputs/flutter-apk/app-arm64-release.apk"
[[ -f "$apk" ]] || { echo "没找到 Flutter release APK: $apk" >&2; exit 1; }
DIST="$ROOT/dist"
mkdir -p "$DIST"
OUT="$DIST/zichuan-assistant-$VERSION_NAME.apk"
cp "$apk" "$OUT"
verify="$(${APKSIGNER:-apksigner} verify --print-certs "$OUT")"
printf '%s\n' "$verify" | sed -n '1,8p'
actual="$(printf '%s\n' "$verify" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | sed 's/://g' | tr -d '[:space:]' | tr 'A-F' 'a-f')"
expected="05d1265d870c5b72e53c8a745dbe8fe12edb791ea17f7bdaf40234904c4d5057"
[[ "$actual" == "$expected" ]] || { echo "release signer fingerprint mismatch" >&2; exit 1; }
echo "\n产物: $OUT"
echo "大小: $(du -h "$OUT" | cut -f1)"
exit 0
