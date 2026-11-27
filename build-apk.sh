#!/bin/bash
# 构建并签名「子川助手」原生 Flutter/Kotlin APK。
#
#   bash build-apk.sh                 # 版本名取 app/pubspec.yaml，版本号自动递增
#   VERSION_NAME=2.0.1 VERSION_CODE=12345678 bash build-apk.sh
#
# 产物：dist/zichuan-assistant-<version>.apk（保留现有 release signer）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 签名材料不进仓库：keystore 与密码都由环境变量传入（CI 用 Secrets，本地放仓库外）。
KS="${KEYSTORE:-$ROOT/keystore/zichuan-release.jks}"
KS_PASS="${KEYSTORE_PASSWORD:-}"
KS_ALIAS="${KEYSTORE_ALIAS:-zichuan}"
# 版本名只认 app/pubspec.yaml。以前这里写死 2.0.0：v2.0.2 的 release 里挂的
# 就是 zichuan-assistant-2.0.0.apk，APK 内的 versionName 也是 2.0.0，和 tag、
# 发布说明全对不上（versionCode 仍递增，能装，但设置页与更新检查都会认错版本）。
VERSION_NAME="${VERSION_NAME:-$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' "$ROOT/app/pubspec.yaml")}"
[[ -n "$VERSION_NAME" ]] || { echo "app/pubspec.yaml 里没有 version:" >&2; exit 1; }
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
