#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT/ClaudeSessionManager"
DERIVED="$PROJECT_DIR/build"
CONFIG="${1:-Release}"

cd "$PROJECT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "需要 xcodegen：brew install xcodegen" >&2
  exit 1
fi

echo "→ 生成 Xcode 工程"
xcodegen generate

echo "→ 编译 ($CONFIG)"
xcodebuild \
  -scheme ClaudeSessionManager \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  build

APP="$DERIVED/Build/Products/$CONFIG/Claude会话管理.app"
echo "✓ 完成: $APP"
echo "  运行: open \"$APP\""
