"""Exercise Apple's actual Simulator menu and external framebuffer on the runner.

The disposable GitHub runner is the only target. No app source, user simulator,
TCC database, private simulator API, or entitlement is modified by this probe.
"""

import json
import os
import atexit
from pathlib import Path
import re
import shutil
import struct
import subprocess
import time


OUTPUT = Path("CarPlay-Captures")
OUTPUT.mkdir(exist_ok=True)
device_id = None
display_variant = os.environ.get("CARPLAY_DISPLAY_VARIANT", "default")
display_variants = json.loads(Path(__file__).with_name("display-variants.json").read_text())
if display_variant not in display_variants:
    raise ValueError(f"Unknown CarPlay display variant: {display_variant}")
requested_display = display_variants[display_variant]


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
input_permissions = json.loads(run("input-permissions", [
    "osascript", "-l", "JavaScript", "scripts/carplay-capture/mouse.jxa",
]))
assert input_permissions["postEvents"], "macOS mouse-event posting must be granted before starting the capture."
# Compile before booting iOS so the fresh SDK module cache does not compete
# with the simulator's first-boot migration and rendering work.
ocr = str(Path(os.environ["RUNNER_TEMP"]) / "nextstop-screen-text")
run("compile-screen-reader", [
    "xcrun", "swiftc", "scripts/carplay-capture/screen-text.swift", "-o", ocr,
], timeout=240)
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
os.environ["CARPLAY_DEVICE_ID"] = device_id
with open(os.environ["GITHUB_ENV"], "a") as output:
    output.write(f"CARPLAY_DEVICE_ID={device_id}\n")
run("boot-device", ["xcrun", "simctl", "boot", device_id])
run("boot-status", ["xcrun", "simctl", "bootstatus", device_id, "-b"], timeout=180)
run("status-bar", [
    "xcrun", "simctl", "status_bar", device_id, "override", "--time", "9:41",
    "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
    "--batteryState", "charged", "--batteryLevel", "100",
], timeout=180)
run("appearance", ["xcrun", "simctl", "ui", device_id, "appearance", "light"], timeout=180)
developer = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
simulator = str(Path(developer) / "Applications/Simulator.app")
# This documented option must be set before Simulator launches. Only the fresh
# disposable runner is configured; no user's local Simulator is touched.
run("set-display-options", [
    "defaults", "write", "com.apple.iphonesimulator", "CarPlayExtraOptions", "-bool",
    "YES" if display_variant == "wide" else "NO",
])
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
carplay_menu_script = '''
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
'''
def connect_carplay(label):
    if display_variant == "wide":
        run(label, ["python3", "scripts/carplay-capture/configure-display.py"], timeout=110)
    else:
        run(label, ["osascript", "-e", carplay_menu_script], timeout=50)


connect_carplay("enable-carplay")
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
# A booted fresh simulator may still be loading SpringBoard and CarPlay. Poll
# actual native frames, with one shared deadline for capture, OCR and delays.
def wait_for_readable_carplay(phase):
    started = time.monotonic()
    deadline = started + 90
    attempts = 0
    ready = False
    while time.monotonic() < deadline:
        attempts += 1
        suffix = f"{phase}-{attempts:02d}"
        frame = OUTPUT / f"diagnostic-carplay-readiness-{suffix}.png"
        try:
            run(f"external-screenshot-{suffix}", [
                "xcrun", "simctl", "io", device_id, "screenshot", "--display=external", str(frame),
            ], timeout=max(0.1, min(45, deadline - time.monotonic())))
            shutil.copy2(frame, OUTPUT / "diagnostic-carplay-home.png")
            if time.monotonic() >= deadline:
                break
            text = json.loads(run(
                f"external-screen-text-{suffix}", [ocr, str(frame)],
                timeout=max(0.1, min(20, deadline - time.monotonic())),
            ))
            if time.monotonic() < deadline and len(text.get("text", [])) >= 2:
                ready = True
                break
        except (subprocess.TimeoutExpired, RuntimeError, json.JSONDecodeError) as error:
            print(f"CarPlay readiness {suffix}: {error}", flush=True)
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(3, remaining))
    result = {
        "phase": phase, "ready": ready, "attempts": attempts,
        "waitSeconds": round(time.monotonic() - started, 1),
    }
    (OUTPUT / f"readiness-{phase}.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


readiness = [wait_for_readable_carplay("initial")]
if not readiness[-1]["ready"]:
    run("host-screen-before-reconnect", [
        "screencapture", "-x", str(OUTPUT / "diagnostic-host-before-reconnect.png"),
    ], required=False)
    # Discover the standard close button within the observed external window.
    # Never guess a menu label for disconnecting displays.
    run("close-carplay-window", ["osascript", "-e", '''
with timeout of 30 seconds
    tell application "System Events" to tell process "Simulator"
        set frontmost to true
        if not (exists (first window whose name ends with " – CarPlay")) then
            error "Expected the observed external CarPlay window before reconnecting"
        end if
        set carplayWindow to first window whose name ends with " – CarPlay"
        set closeButton to first button of carplayWindow whose subrole is "AXCloseButton"
        if not (exists closeButton) then error "CarPlay window has no standard close button"
        click closeButton
        delay 1
    end tell
end timeout
'''], timeout=40)
    connect_carplay("reconnect-carplay-menu")
    run("host-screen-after-reconnect", [
        "screencapture", "-x", str(OUTPUT / "diagnostic-host-after-reconnect.png"),
    ], required=False)
    readiness.append(wait_for_readable_carplay("reconnected"))
if not readiness[-1]["ready"]:
    run("host-screen-unreadable-carplay", [
        "screencapture", "-x", str(OUTPUT / "diagnostic-host-unreadable-carplay.png"),
    ], required=False)
    raise RuntimeError("CarPlay remained unreadable after two 90-second waits and one native display reconnect.")

native_frame = (OUTPUT / "diagnostic-carplay-home.png").read_bytes()
assert native_frame[:8] == b"\x89PNG\r\n\x1a\n", "The external framebuffer must be an original PNG."
native_size = struct.unpack(">II", native_frame[16:24])
requested_size = (requested_display["width"], requested_display["height"])
assert native_size == requested_size, f"Requested {requested_size}; native framebuffer is {native_size}"
connected = run("verified-displays", ["xcrun", "simctl", "io", device_id, "enumerate"])
# Match the active TVOut screen, not the separate creatable CarPlay default.
scale_match = re.search(
    r"Screen Type: TVOut\n(?:(?!Screen Type:).)*?Preferred UI Scale: ([0-9.]+)",
    connected.partition("Connected Screens:")[2], re.DOTALL,
)
assert scale_match, "The active TVOut screen must expose its actual UI scale."
runtime_scale = float(scale_match.group(1))
assert runtime_scale == requested_display["scale"], f"Unexpected runtime UI scale: {runtime_scale}"
configuration = None
if display_variant == "wide":
    configuration = json.loads((OUTPUT / "display-configuration.json").read_text())
    assert configuration["runSubmitted"] and configuration["readback"] == requested_display
    configuration.update({"runtimeScale": runtime_scale, "framebufferSize": list(native_size)})
    (OUTPUT / "display-configuration.json").write_text(json.dumps(configuration, indent=2) + "\n")

(OUTPUT / "preflight.json").write_text(json.dumps({
    "deviceID": device_id,
    "device": "iPhone 17 Pro",
    "runtime": runtime,
    "menu": "Simulator > I/O > External Displays > CarPlay",
    "capture": "simctl io screenshot --display=external",
    "readiness": readiness,
    "carplayDisplay": {
        "variant": display_variant, "width": native_size[0], "height": native_size[1],
        "scale": runtime_scale,
    },
    "configuration": configuration,
    "result": "Native CarPlay display connected and captured before app build",
}, indent=2) + "\n")
