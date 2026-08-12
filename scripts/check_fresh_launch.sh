#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$ROOT_DIR/build/mimi.app}"
EXECUTABLE="$APP_DIR/Contents/MacOS/mimi"

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "error: missing $EXECUTABLE; run scripts/build_app.sh first" >&2
  exit 1
fi

TEST_HOME="$(mktemp -d /tmp/mimi-fresh-launch.XXXXXX)"
LOG_PATH="$TEST_HOME/mimi.log"
PID=""
cleanup() {
  if [[ -n "$PID" ]]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_HOME"
}
trap cleanup EXIT

HOME="$TEST_HOME" CFFIXED_USER_HOME="$TEST_HOME" "$EXECUTABLE" >"$LOG_PATH" 2>&1 &
PID=$!

MIMI_PID="$PID" /usr/bin/swift - <<'SWIFT'
import ApplicationServices
import Foundation

let pid = pid_t(ProcessInfo.processInfo.environment["MIMI_PID"]!)!
let app = AXUIElementCreateApplication(pid)

func windowTitles() -> [String] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return [] }
    return windows.compactMap { window in
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }
}

for _ in 0 ..< 40 {
    let titles = windowTitles()
    if titles.contains(where: { $0.localizedCaseInsensitiveContains("Settings") }) {
        print("PASS: fresh launch showed Settings window: \(titles)")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.25)
}

fputs("FAIL: fresh launch showed no Settings window; windows=\(windowTitles())\n", stderr)
exit(1)
SWIFT
