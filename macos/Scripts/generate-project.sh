#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if ! command -v node >/dev/null 2>&1; then
  printf '%s\n' "Node.js is required to regenerate the deterministic app icon assets." >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  printf '%s\n' "XcodeGen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi

node "$SCRIPT_DIR/generate_app_icons.js"
xcodegen generate --spec "$PROJECT_DIR/project.yml" --project "$PROJECT_DIR"
