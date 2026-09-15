"""Observe Apple's CarPlay display configuration on a disposable Actions runner.

Run after the existing native-display preflight. This enables Apple's documented
Simulator extra-options preference, restarts that runner's Simulator, and opens
the observed CarPlay menu item. It records the actual configuration controls and
public SDK declarations without guessing field positions or changing app code.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


OUTPUT = Path("CarPlay-Captures/configuration-discovery")
DEVICE = os.environ.get("CARPLAY_DEVICE_ID", "")
DEADLINE = time.monotonic() + 180


def run(label, command, *, required=True, timeout=30):
    remaining = DEADLINE - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Configuration discovery exceeded its three-minute deadline.")
    print(f"{label}: {command!r}", flush=True)
    try:
        result = subprocess.run(
            command, text=True, capture_output=True, timeout=min(timeout, remaining)
        )
        (OUTPUT / f"{label}.log").write_text(result.stdout + result.stderr)
        if required and result.returncode:
            raise RuntimeError(f"{label} exited with {result.returncode}: {result.stderr}")
        return result.stdout
    except subprocess.TimeoutExpired as error:
        (OUTPUT / f"{label}.log").write_text(str(error) + "\n")
        if required:
            raise
        return ""


def javascript(label, source):
    raw = run(label, ["osascript", "-l", "JavaScript", "-e", source])
    value = json.loads(raw)
    (OUTPUT / f"{label}.json").write_text(
        json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    )
    return value


# System Events supplies public accessibility properties. Missing properties are
# recorded as absent; they are never interpreted as instructions to operate UI.
TREE_READER = r"""
var system = Application('System Events');
var process = system.processes.byName('Simulator');
var visited = 0;
function property(element, name) {
    try { return element[name](); } catch (error) { return null; }
}
function read(element, depth, path) {
    var result = {path: path};
    for (var key of ['role', 'subrole', 'name', 'description', 'value',
                     'position', 'size', 'enabled', 'visible']) {
        var value = property(element, key);
        if (value !== null && value !== undefined) result[key] = value;
    }
    visited++;
    if (depth >= 9 || visited >= 1500) {
        result.childrenTruncated = true;
        return result;
    }
    var children = property(element, 'uiElements');
    if (children && children.length) {
        result.children = [];
        for (var index = 0; index < children.length && visited < 1500; index++) {
            result.children.push(read(children[index], depth + 1, path + '/' + index));
        }
        if (result.children.length !== children.length) result.childrenTruncated = true;
    }
    return result;
}
"""


def snapshot(label):
    state = javascript(
        label,
        TREE_READER
        + "\nJSON.stringify({windows: process.windows().map(function(window, index) { "
        + "return read(window, 0, 'windows/' + index); })});",
    )
    run(
        f"{label}-host-screen",
        ["screencapture", "-x", str(OUTPUT / f"{label}.png")],
        required=False,
    )
    return state


def public_sdk_headers():
    sdk = Path(run("simulator-sdk-path", ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]).strip())
    headers = sdk / "System/Library/Frameworks/CarPlay.framework/Headers"
    selected = [
        "CPPointOfInterestTemplate.h", "CPPointOfInterest.h", "CPBarButton.h",
        "CPListTemplate.h", "CPListItem.h", "CPTextButton.h",
        "CPInformationTemplate.h", "CPInformationItem.h", "CPTemplate.h",
    ]
    destination = OUTPUT / "public-carplay-headers"
    destination.mkdir(exist_ok=True)
    records = []
    for name in selected:
        source = headers / name
        record = {"name": name, "sdkPath": str(source), "available": source.is_file()}
        if source.is_file():
            shutil.copy2(source, destination / name)
            record["sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
        records.append(record)
    (OUTPUT / "public-sdk-headers.json").write_text(json.dumps(records, indent=2) + "\n")
    return records


def controls_in(tree):
    controls = []

    def visit(node):
        if node.get("role") in {
            "AXTextField", "AXComboBox", "AXPopUpButton", "AXButton", "AXStaticText",
            "AXCheckBox", "AXRadioButton", "AXSlider", "AXStepper", "AXMenuItem",
        }:
            controls.append({key: value for key, value in node.items() if key != "children"})
        for child in node.get("children", []):
            visit(child)

    for window in tree.get("windows", []):
        visit(window)
    return controls


def main():
    # This script must never operate the user's local Simulator or preferences.
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_OS") != "macOS":
        raise RuntimeError("Configuration discovery is restricted to a disposable GitHub macOS runner.")
    if not re.fullmatch(r"[A-Fa-f0-9-]{36}", DEVICE):
        raise RuntimeError("Run the existing preflight first to create CARPLAY_DEVICE_ID.")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    devices = json.loads(run("devices", ["xcrun", "simctl", "list", "devices", "--json"]))
    matches = [
        item for group in devices["devices"].values() for item in group
        if item["udid"] == DEVICE
    ]
    if len(matches) != 1 or matches[0]["name"] != "nextStop CarPlay Capture":
        raise RuntimeError("Expected the fresh device created by the screenshot preflight.")
    if matches[0]["state"] != "Booted":
        raise RuntimeError("The preflight capture device must already be booted.")

    headers = public_sdk_headers()
    before = snapshot("before-extra-options")
    run("simulator-preferences-before", ["defaults", "read", "com.apple.iphonesimulator"], required=False)
    run("enable-extra-options", [
        "defaults", "write", "com.apple.iphonesimulator", "CarPlayExtraOptions", "-bool", "YES",
    ])
    run("quit-runner-simulator", [
        "osascript", "-e", 'tell application id "com.apple.iphonesimulator" to quit',
    ])
    run("wait-for-simulator-exit", ["osascript", "-e", '''
tell application "System Events"
    repeat 20 times
        if not (exists process "Simulator") then return "Simulator exited"
        delay 0.5
    end repeat
    error "Simulator did not exit before the configuration probe"
end tell
'''])
    developer = Path(run("developer-path", ["xcode-select", "-p"]).strip())
    run("reopen-runner-simulator", [
        "open", "-a", str(developer / "Applications/Simulator.app"),
        "--args", "-CurrentDeviceUDID", DEVICE,
    ])
    run("wait-for-runner-window", ["osascript", "-e", '''
tell application "System Events"
    repeat 30 times
        if exists process "Simulator" then
            tell process "Simulator"
                if exists window 1 then
                    set frontmost to true
                    return name of every window
                end if
            end tell
        end if
        delay 0.5
    end repeat
    error "Simulator did not expose a window after restart"
end tell
'''])
    snapshot("after-extra-options")
    javascript("open-io-menu", TREE_READER + r"""
process.frontmost = true;
var io = process.menuBars[0].menuBarItems.byName('I/O');
io.click();
delay(0.5);
JSON.stringify(read(io, 0, 'menu/I-O'));
""")
    external = javascript("external-display-menu", TREE_READER + r"""
var external = process.menuBars[0].menuBarItems.byName('I/O')
    .menus[0].menuItems.byName('External Displays');
external.click();
delay(0.5);
JSON.stringify({items: external.menus[0].menuItems().map(function(item) {
    return {name: property(item, 'name'), enabled: property(item, 'enabled')};
}), tree: read(external, 0, 'menu/external-displays')});
""")
    candidates = [
        item for item in external["items"]
        if isinstance(item.get("name"), str)
        and re.fullmatch(r"CarPlay(?:\.{3}|…)?", item["name"])
        and item.get("enabled") is not False
    ]
    if len(candidates) != 1:
        snapshot("ambiguous-carplay-menu")
        raise RuntimeError(f"Expected exactly one observed CarPlay menu item: {external['items']!r}")
    observed_label = candidates[0]["name"]
    javascript("open-observed-carplay-item", TREE_READER + r"""
var external = process.menuBars[0].menuBarItems.byName('I/O')
    .menus[0].menuItems.byName('External Displays');
external.menus[0].menuItems.byName(""" + json.dumps(observed_label) + r""").click();
delay(1);
JSON.stringify({opened: """ + json.dumps(observed_label) + r"""});
""")
    configuration = snapshot("observed-carplay-configuration")
    run("simulator-preferences-after", ["defaults", "read", "com.apple.iphonesimulator"], required=False)
    run("connected-displays", ["xcrun", "simctl", "io", DEVICE, "enumerate"], required=False)
    run("external-display", [
        "xcrun", "simctl", "io", DEVICE, "screenshot", "--display=external",
        str(OUTPUT / "external-display.png"),
    ], required=False, timeout=15)
    controls = controls_in(configuration)
    result = {
        "deviceID": DEVICE,
        "deviceName": matches[0]["name"],
        "runURL": f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
        "harnessCommit": os.environ["GITHUB_SHA"],
        "documentation": "https://developer.apple.com/documentation/carplay/using-the-carplay-simulator",
        "preference": "defaults write com.apple.iphonesimulator CarPlayExtraOptions -bool YES",
        "observedCarPlayMenuItem": observed_label,
        "initialWindowCount": len(before["windows"]),
        "observedConfigurationControls": controls,
        "configurationFieldsObserved": any(
            control.get("role") in {"AXTextField", "AXComboBox", "AXPopUpButton"}
            for control in controls
        ),
        "publicSDKHeaders": headers,
        "scope": "Discovery only. No custom resolution was submitted and no app was changed.",
    }
    (OUTPUT / "discovery.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(result, indent=2, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
