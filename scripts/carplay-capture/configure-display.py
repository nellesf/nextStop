"""Configure a fresh runner's native CarPlay display using observed public UI.

The controls were recorded in Actions run 34953971279. Preflight must enable
Apple's documented CarPlayExtraOptions preference before launching Simulator.
This script also supports preflight reconnects after the external window closes.
"""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import time


OUTPUT = Path("CarPlay-Captures")
DEADLINE = time.monotonic() + 90
OBSERVATION = {
    "runURL": "https://github.com/nellesf/nextStop/actions/runs/34953971279",
    "harnessCommit": "69d1f641ef7d33e1edb88b34d2ce2ab9e1ddf375",
    "artifact": "configuration-discovery/observed-carplay-configuration.json",
    "menuItem": "CarPlay…",
    "window": "TV Out Extended Setup",
}


def run(label, command, *, required=True):
    remaining = DEADLINE - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Native CarPlay configuration exceeded 90 seconds.")
    result = subprocess.run(
        command, text=True, capture_output=True, timeout=min(30, remaining)
    )
    with (OUTPUT / "display-configuration-actions.log").open("a") as log:
        log.write(f"{label}\n{result.stdout}{result.stderr}\n")
    if required and result.returncode:
        raise RuntimeError(f"{label} failed: {result.stderr}")
    return result.stdout


def javascript(label, source):
    return json.loads(run(label, ["osascript", "-l", "JavaScript", "-e", source]))


DIALOG_READER = r"""
var process = Application('System Events').processes.byName('Simulator');
var matching = process.windows.whose({name: 'TV Out Extended Setup'})();
if (matching.length !== 1) throw new Error('Expected exactly one observed setup window');
var window = matching[0];
function read(element, index) {
    var values = element.properties();
    var result = {index: index + 1};
    for (var key of ['role', 'name', 'value', 'position', 'size', 'enabled']) {
        if (values[key] !== undefined && values[key] !== null) result[key] = values[key];
    }
    return result;
}
JSON.stringify({
    window: 'TV Out Extended Setup',
    labels: window.staticTexts().map(read),
    textFields: window.textFields().map(read),
    comboBoxes: window.comboBoxes().map(read),
    runButton: read(window.buttons.byName('Run'), 0)
});
"""


def field_for(label_name, fields, labels):
    matching = [label for label in labels if label.get("name") == label_name]
    if len(matching) != 1:
        raise RuntimeError(f"Expected one observed {label_name} label.")
    label = matching[0]
    lx, ly = label["position"]
    lw, lh = label["size"]
    candidates = []
    for field in fields:
        fx, fy = field["position"]
        _, fh = field["size"]
        if fx >= lx + lw and abs((fy + fh / 2) - (ly + lh / 2)) <= max(lh, fh) / 2:
            candidates.append((fx - (lx + lw), field))
    candidates.sort(key=lambda pair: pair[0])
    if not candidates or (len(candidates) > 1 and candidates[0][0] == candidates[1][0]):
        raise RuntimeError(f"Cannot uniquely associate {label_name} with its native field.")
    return candidates[0][1]


def validate_dialog(state):
    if len(state["textFields"]) != 2 or len(state["comboBoxes"]) != 1:
        raise RuntimeError("Setup fields differ from the observed two text fields and one combo box.")
    width = field_for("Width", state["textFields"], state["labels"])
    height = field_for("Height", state["textFields"], state["labels"])
    scale = field_for("Scale", state["comboBoxes"], state["labels"])
    if width["index"] == height["index"]:
        raise RuntimeError("Width and Height must identify separate native fields.")
    if any(field.get("enabled") is not True for field in [width, height, scale, state["runButton"]]):
        raise RuntimeError("Observed configuration controls must be enabled.")
    return {"width": width, "height": height, "scale": scale}


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("RUNNER_OS") != "macOS":
        raise RuntimeError("Display configuration is restricted to a disposable GitHub macOS runner.")
    device = os.environ.get("CARPLAY_DEVICE_ID", "")
    if not re.fullmatch(r"[A-Fa-f0-9-]{36}", device):
        raise RuntimeError("Preflight must supply its fresh CARPLAY_DEVICE_ID.")
    configurations = json.loads(Path(__file__).with_name("display-configurations.json").read_text())
    matches = [item for item in configurations if item["id"] == os.environ["CARPLAY_CONFIGURATION"]]
    if len(matches) != 1:
        raise RuntimeError("Choose a known configuration from display-configurations.json.")
    requested = matches[0]
    for key in ["width", "height", "scale"]:
        if float(os.environ[f"CARPLAY_{key.upper()}"]) != requested[key]:
            raise RuntimeError(f"CARPLAY_{key.upper()} does not match {requested['id']}.")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    devices = json.loads(run("verify-fresh-device", ["xcrun", "simctl", "list", "devices", "--json"]))
    matching_devices = [
        item for group in devices["devices"].values() for item in group if item["udid"] == device
    ]
    if len(matching_devices) != 1 or matching_devices[0]["name"] != "nextStop CarPlay Capture":
        raise RuntimeError("Only the fresh named preflight device can be configured.")
    if matching_devices[0]["state"] != "Booted":
        raise RuntimeError("The preflight device must be booted.")

    # Use the exact menu and dialog observed on this runner version. A changed
    # control name fails with diagnostics instead of selecting a guessed item.
    run("open-carplay-configuration", ["osascript", "-e", '''
tell application "System Events" to tell process "Simulator"
    set frontmost to true
    if not (exists window "TV Out Extended Setup") then
        click menu bar item "I/O" of menu bar 1
        delay 0.5
        set externalItem to menu item "External Displays" of menu "I/O" of menu bar 1
        click externalItem
        delay 0.5
        if not (exists menu item "CarPlay…" of menu 1 of externalItem) then
            error "The observed CarPlay… menu item is unavailable"
        end if
        click menu item "CarPlay…" of menu 1 of externalItem
    end if
    repeat 20 times
        if exists window "TV Out Extended Setup" then return "Configuration window ready"
        delay 0.5
    end repeat
    error "The observed CarPlay configuration window did not appear"
end tell
'''])
    run("configuration-before", ["screencapture", "-x", str(OUTPUT / "display-configuration-before.png")])
    initial = javascript("read-configuration-controls", DIALOG_READER)
    (OUTPUT / "display-configuration-controls.json").write_text(json.dumps(initial, indent=2) + "\n")
    fields = validate_dialog(initial)
    run("set-observed-configuration-fields", ["osascript", "-e", '''
on enterAndCommit(theControl, requestedText)
    tell application "System Events"
        set value of attribute "AXFocused" of theControl to true
        delay 0.1
        if (value of attribute "AXFocused" of theControl) is not true then
            error "The observed configuration field did not receive keyboard focus"
        end if
        keystroke "a" using command down
        keystroke requestedText
        key code 48
        delay 0.2
        if (value of attribute "AXFocused" of theControl) is true then
            error "The configuration edit did not lose focus after Tab"
        end if
    end tell
end enterAndCommit

on run arguments
    tell application "System Events" to tell process "Simulator"
        set frontmost to true
        set setupWindow to window "TV Out Extended Setup"
        if (count text fields of setupWindow) is not 2 then error "Text field count changed"
        if (count combo boxes of setupWindow) is not 1 then error "Combo box count changed"
        my enterAndCommit(text field (item 1 of arguments as integer) of setupWindow, item 2 of arguments)
        my enterAndCommit(text field (item 3 of arguments as integer) of setupWindow, item 4 of arguments)
        my enterAndCommit(combo box (item 5 of arguments as integer) of setupWindow, item 6 of arguments)
    end tell
    return "Requested dimensions entered with keyboard input and committed by focus loss"
end run
''', str(fields["width"]["index"]), str(requested["width"]),
        str(fields["height"]["index"]), str(requested["height"]),
        str(fields["scale"]["index"]), str(requested["scale"])])
    readback_state = javascript("readback-configuration-controls", DIALOG_READER)
    readback_fields = validate_dialog(readback_state)
    readback = {key: float(readback_fields[key]["value"]) for key in ["width", "height", "scale"]}
    if any(readback[key] != requested[key] for key in readback):
        raise RuntimeError(f"Native field readback differs from the request: {readback!r}")
    run("configuration-readback", ["screencapture", "-x", str(OUTPUT / "display-configuration-readback.png")])
    record = {
        "id": requested["id"],
        "requested": {key: requested[key] for key in ["width", "height", "scale"]},
        "readback": readback, "deviceID": device,
        "observationRunURL": OBSERVATION["runURL"],
        "controlObservation": OBSERVATION,
        "fieldAssociation": "Nearest native field to the right of its observed label on the same row",
        "inputMethod": "Focus each observed field, Command+A, type its numeric value, then Tab and verify focus loss",
        "configuredAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "runURL": f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
        "harnessCommit": os.environ["GITHUB_SHA"], "runSubmitted": False,
    }
    manifest = OUTPUT / "display-configuration.json"
    manifest.write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n")
    run("run-configured-display", ["osascript", "-e", '''
tell application "System Events" to tell process "Simulator"
    set setupWindow to window "TV Out Extended Setup"
    if not (enabled of button "Run" of setupWindow) then error "Run button is disabled"
    click button "Run" of setupWindow
end tell
'''])
    record["runSubmitted"] = True
    manifest.write_text(json.dumps(record, indent=2, ensure_ascii=False) + "\n")
    with (OUTPUT / "display-configuration-attempts.jsonl").open("a") as attempts:
        attempts.write(json.dumps(record, ensure_ascii=False) + "\n")
    print(json.dumps(record, indent=2, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
