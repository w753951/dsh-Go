#!/usr/bin/env bash
# `flutter build ios` with these arguments. Reading a job's log takes a GitHub sign-in
# and its annotations don't, so on failure the compiler's errors go up as annotations
# as well (at most ten: GitHub's limit for one step).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# The library ships with the iOS app; sensitive capabilities are disabled until
# the user enables them in the app. This does not install an XCTest runner.
if ! bash "$ROOT/tooling/ios/build-phone-self-runner.sh"; then
  printf '::error::The pinned iOS phone native library did not build.\n' >&2
  exit 1
fi

log="$(mktemp)"
# Flutter 的 --no-codesign 只是不给产物签名；工程里 CODE_SIGN_STYLE 是
# Automatic 时，xcodebuild 仍会去找 Development Team，找不到就在编译完成
# 之后报 requires a selected Development Team。CI 上没有任何证书，
# 所以把 Xcode 侧的签名一起关掉，构建完成后再由后面的步骤 ldid 重签。
# 用环境变量而不是命令行参数：这与 tooling/ios/check-archive.sh 的做法一致。
CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" EXPANDED_CODE_SIGN_IDENTITY="" \
  flutter build ios "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ]; then
  # Flutter 会把 xcodebuild 的原始输出吞掉，只吐一段通用的签名提示。
  # 失败时把日志里跟编译有关的行全部倒出来，免得下一次还要靠猜。
  echo "----- flutter build ios 失败，原始日志里的可疑行 -----"
  grep -nE 'error:|Error:|\(Xcode\)|The following build commands failed|CompileSwift|SwiftCompile|ld:|Undefined symbol|not found for architecture|Command .* failed|cannot find|no such module|has no member' "$log" \
    | cut -c1-800 | head -60 || true
  echo "----- 日志尾部 80 行 -----"
  tail -80 "$log" | cut -c1-800 || true
  echo "----- 原始日志到此为止 -----"
  # Flutter prints Xcode's message with its file on the line after.
  awk '/\(Xcode\):|error:|Error:/ {
    line = $0
    if (getline following > 0) line = line " | " following
    print line
  }' "$log" | awk '!seen[$0]++' | cut -c1-600 | head -10 | sed -e 's/%/%25/g' -e 's/^/::error::/'
fi
exit "$status"
