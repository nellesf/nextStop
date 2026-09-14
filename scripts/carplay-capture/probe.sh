#!/bin/bash
set -euo pipefail

mkdir -p CarPlay-Captures
xcodebuild -version > CarPlay-Captures/xcode-version.txt
xcrun simctl list devices available --json > CarPlay-Captures/devices.json
device_id="$(python3 -c 'import json; data=json.load(open("CarPlay-Captures/devices.json")); print(next(d["udid"] for devices in data["devices"].values() for d in devices if d["name"] == "iPhone 17 Pro"))')"
echo "CARPLAY_DEVICE_ID=$device_id" >> "$GITHUB_ENV"
xcrun simctl boot "$device_id"
xcrun simctl bootstatus "$device_id" -b
xcrun simctl status_bar "$device_id" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl io "$device_id" screenshot --help > CarPlay-Captures/screenshot-help.txt 2>&1 || true
open -a Simulator --args -CurrentDeviceUDID "$device_id"

osascript > CarPlay-Captures/simulator-menu.txt 2>&1 <<'APPLESCRIPT'
tell application "System Events"
  repeat 30 times
    if exists process "Simulator" then exit repeat
    delay 1
  end repeat
  tell process "Simulator"
    set frontmost to true
    repeat 30 times
      if exists window 1 then exit repeat
      delay 1
    end repeat
    get name of every window
    get name of every menu bar item of menu bar 1
    click menu bar item "I/O" of menu bar 1
    delay 1
    get name of every menu item of menu 1 of menu bar item "I/O" of menu bar 1
    click menu item "External Displays" of menu 1 of menu bar item "I/O" of menu bar 1
    delay 1
    click menu item "CarPlay" of menu 1 of menu item "External Displays" of menu 1 of menu bar item "I/O" of menu bar 1
    delay 8
    return name of every window
  end tell
end tell
APPLESCRIPT

xcrun simctl io "$device_id" enumerate > CarPlay-Captures/displays.txt 2>&1
xcrun simctl io "$device_id" screenshot --display=external CarPlay-Captures/carplay-preflight.png
osascript > CarPlay-Captures/simulator-ui.txt 2>&1 <<'APPLESCRIPT'
tell application "System Events" to tell process "Simulator"
  return entire contents of every window
end tell
APPLESCRIPT
