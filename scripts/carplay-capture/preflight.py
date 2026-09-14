"""Exercise Apple's actual Simulator menu and external framebuffer on the runner.

The disposable GitHub runner is the only target. No app source, user simulator,
TCC database, private simulator API, or entitlement is modified by this probe.
"""

import json
import os
import atexit
from pathlib import Path
import shutil
import subprocess
import time


OUTPUT = Path("CarPlay-Captures")
OUTPUT.mkdir(exist_ok=True)
device_id = None


def run(label, command, *, required=True, timeout=60):
    print(f"{label}: {command!r}", flush=True)
    try:
        result = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
        content = result.stdout + result.stderr
        (OUTPUT / f"{label}.log").write_text(content)
        print(content, flush=True)
        if required and result.returncode:
            raise RuntimeError(f"{label} exited with {result.returncode}")
        return result.stdout
    except subprocess.TimeoutExpired as error:
        (OUTPUT / f"{label}.log").write_text(f"Timed out after {timeout} seconds: {error}")
        if required:
            raise
        return ""


def diagnostics():
    run("host-simulator-process", ["pgrep", "-fl", "Simulator"], required=False)
    run("host-screen-final", ["screencapture", "-x", str(OUTPUT / "diagnostic-host-final.png")], required=False)
    run("host-windows-final", ["osascript", "-e", '''
tell application "System Events"
    if exists process "Simulator" then
        tell process "Simulator" to return properties of every window
    end if
end tell
'''], required=False)
    run("host-simulator-log", [
        "log", "show", "--last", "3m", "--style", "compact",
        "--predicate", 'process == "Simulator"',
    ], required=False, timeout=30)
    if device_id:
        run("simulator-carplay-log", [
            "xcrun", "simctl", "spawn", device_id, "log", "show", "--last", "3m",
            "--style", "compact", "--predicate",
            'process == "CarPlay" OR process == "CarPlayApp" OR (process == "SpringBoard" AND eventMessage CONTAINS[c] "CarPlay")',
        ], required=False, timeout=30)
    recent = time.time() - 15 * 60
    crash_output = OUTPUT / "Host-Crash-Reports"
    for folder in [Path.home() / "Library/Logs/DiagnosticReports", Path("/Library/Logs/DiagnosticReports")]:
        if folder.exists():
            for report in folder.glob("*Simulator*"):
                if report.is_file() and report.stat().st_mtime >= recent:
                    crash_output.mkdir(exist_ok=True)
                    shutil.copy2(report, crash_output / report.name)


atexit.register(diagnostics)
run("xcode-version", ["xcodebuild", "-version"])
run("simctl-io-help", ["xcrun", "simctl", "io", "help"], required=False)
run("automation-mode", ["automationmodetool"], required=False)
runtimes = json.loads(run("runtimes", ["xcrun", "simctl", "list", "runtimes", "--json"]))
available = [
    runtime for runtime in runtimes["runtimes"]
    if runtime.get("isAvailable") and runtime["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
]
runtime = max(available, key=lambda item: tuple(int(p) for p in item["version"].split(".")))
# A later diagnostic retry may select an observed installed version explicitly;
# never silently move to a different runtime when the selected one fails.
if requested_runtime := os.environ.get("CARPLAY_RUNTIME_VERSION"):
    runtime = next(item for item in available if item["version"] == requested_runtime)
device_id = run("create-device", [
    "xcrun", "simctl", "create", "nextStop CarPlay Capture", "iPhone 17 Pro", runtime["identifier"]
]).strip()
with open(os.environ["GITHUB_ENV"], "a") as output:
    output.write(f"CARPLAY_DEVICE_ID={device_id}\n")
run("boot-device", ["xcrun", "simctl", "boot", device_id])
run("boot-status", ["xcrun", "simctl", "bootstatus", device_id, "-b"], timeout=180)
run("status-bar", [
    "xcrun", "simctl", "status_bar", device_id, "override", "--time", "9:41",
    "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
    "--batteryState", "charged", "--batteryLevel", "100",
])
run("appearance", ["xcrun", "simctl", "ui", device_id, "appearance", "light"])
developer = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
simulator = str(Path(developer) / "Applications/Simulator.app")
run("open-simulator", ["open", "-a", simulator, "--args", "-CurrentDeviceUDID", device_id])
run("wait-for-simulator-window", ["osascript", "-e", '''
tell application "System Events"
    repeat 40 times
        if exists process "Simulator" then
            tell process "Simulator"
                if exists window 1 then
                    set frontmost to true
                    perform action "AXRaise" of window 1
                    return name of every window
                end if
            end tell
        end if
        delay 1
    end repeat
    error "Simulator did not expose a window after launch"
end tell
'''], timeout=50)
run("host-screen-before", ["screencapture", "-x", str(OUTPUT / "diagnostic-host-before.png")], required=False)
run("displays-before", ["xcrun", "simctl", "io", device_id, "enumerate"], required=False)
run("simulator-windows-before", ["osascript", "-e", '''
tell application "System Events"
    tell process "Simulator"
        set frontmost to true
        return {name of every window, name of every menu bar item of menu bar 1}
    end tell
end tell
'''], required=False)

# Apple's documented path: I/O > External Displays > CarPlay. The host language
# stays English; app localization is configured independently during capture.
run("enable-carplay", ["osascript", "-e", '''
with timeout of 40 seconds
    tell application "System Events"
        tell process "Simulator"
            set frontmost to true
            click menu bar item "I/O" of menu bar 1
            delay 1
            set ioMenu to menu "I/O" of menu bar 1
            set externalItem to menu item "External Displays" of ioMenu
            click externalItem
            delay 1
            click menu item "CarPlay" of menu 1 of externalItem
        end tell
    end tell
end timeout
'''], timeout=50)
time.sleep(8)
run("displays-after", ["xcrun", "simctl", "io", device_id, "enumerate"])
run("simulator-windows-after", ["osascript", "-e", '''
tell application "System Events"
    tell process "Simulator"
        return properties of every window
    end tell
end tell
'''], required=False)
run("simulator-accessibility", ["osascript", "-e", '''
tell application "System Events"
    tell process "Simulator"
        return entire contents of every window
    end tell
end tell
'''], required=False)
run("external-screenshot", [
    "xcrun", "simctl", "io", device_id, "screenshot", "--display=external",
    str(OUTPUT / "diagnostic-carplay-home.png"),
])
ocr = str(Path(os.environ["RUNNER_TEMP"]) / "nextstop-screen-text")
run("compile-screen-reader", [
    "xcrun", "swiftc", "scripts/carplay-capture/screen-text.swift", "-o", ocr,
], timeout=90)
text = json.loads(run("external-screen-text", [ocr, str(OUTPUT / "diagnostic-carplay-home.png")]))
assert len(text["text"]) >= 2, "External framebuffer is blank or has no readable CarPlay UI."
(OUTPUT / "preflight.json").write_text(json.dumps({
    "deviceID": device_id,
    "device": "iPhone 17 Pro",
    "runtime": runtime,
    "menu": "Simulator > I/O > External Displays > CarPlay",
    "capture": "simctl io screenshot --display=external",
    "result": "Native CarPlay display connected and captured before app build",
}, indent=2) + "\n")
