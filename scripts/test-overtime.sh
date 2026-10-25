#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -target "$(uname -m)-apple-macos13.0" \
  Breaks/SharedStorage.swift \
  Breaks/Models/FocusSessionTiming.swift \
  Breaks/Models/BreakTimer.swift \
  Breaks/Models/TimerSettings.swift \
  Breaks/Models/FocusJournal.swift \
  Breaks/Models/FocusProjectLibrary.swift \
  Breaks/Models/SessionHistory.swift \
  Breaks/Models/BreakSuggestionLibrary.swift \
  Breaks/Style/ColorExtensions.swift \
  Breaks/System/CalendarExporter.swift \
  Breaks/System/LoginItemController.swift \
  Breaks/System/Hotkeys.swift \
  Tests/OvertimeTests.swift \
  -o build/tests/OvertimeTests
build/tests/OvertimeTests
