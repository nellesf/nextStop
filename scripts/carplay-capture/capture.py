"""Capture the genuine external CarPlay framebuffer after real UI interactions.

Apple's Simulator menu creates the CarPlay display. Apple Vision reads visible
text to locate controls; CoreGraphics mouse events click them. Final files come
directly from simctl, without cropping, overlays, resizing, or synthetic pixels.
"""

import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import time
from datetime import datetime, timezone


OUTPUT = Path("CarPlay-Captures")
DEVICE = os.environ["CARPLAY_DEVICE_ID"]
OCR = os.environ["CARPLAY_SCREEN_TEXT"]
captures = []


def execute(command, *, timeout=45):
    print(repr(command), flush=True)
    result = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
    with (OUTPUT / "capture-actions.log").open("a") as log:
        log.write(repr(command) + "\n" + result.stdout + result.stderr + "\n")
    if result.returncode:
        raise RuntimeError(f"Command failed: {command!r}\n{result.stdout}{result.stderr}")
    return result.stdout.strip()


def recognize(path):
    value = json.loads(execute([OCR, str(path)]))
    path.with_suffix(".ocr.json").write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    return value


def external(path):
    execute(["xcrun", "simctl", "io", DEVICE, "screenshot", "--display=external", str(path)])
    return recognize(path)


def await_native_text(*expected):
    for attempt in range(12):
        path = OUTPUT / f"diagnostic-external-{len(captures)}-{attempt}.png"
        result = external(path)
        text = "\n".join(row["text"] for row in result["text"])
        if all(value.casefold() in text.casefold() for value in expected):
            return result
        time.sleep(2)
    raise RuntimeError(f"CarPlay did not display {expected!r}; actual OCR: {text}")


def click_visible_text(label):
    # Raise the observed CarPlay window; do not click coordinates inferred from
    # the iPhone window, where a matching profile name can also appear.
    window = execute(["osascript", "-e", '''
tell application "System Events" to tell process "Simulator"
    set frontmost to true
    set captureWindow to first window whose name ends with " – CarPlay"
    perform action "AXRaise" of captureWindow
    set windowPosition to position of captureWindow
    set windowSize to size of captureWindow
    return (item 1 of windowPosition as text) & "|" & (item 2 of windowPosition as text) & "|" & (item 1 of windowSize as text) & "|" & (item 2 of windowSize as text)
end tell
'''])
    left, top, width, height = map(float, window.split("|"))
    time.sleep(1)
    path = OUTPUT / f"diagnostic-host-{len(captures)}.png"
    execute(["screencapture", "-x", str(path)])
    words = recognize(path)
    display = json.loads(execute([OCR, "display"]))
    scale_x, scale_y = display["width"] / words["width"], display["height"] / words["height"]
    candidates = []
    for word in words["text"]:
        x = display["x"] + (word["x"] + word["width"] / 2) * scale_x
        y = display["y"] + (word["y"] + word["height"] / 2) * scale_y
        if word["text"].strip().casefold() == label.casefold() and left < x < left + width and top < y < top + height:
            candidates.append((x, y))
    # Profile name and destination are both Leipzig in the same native row.
    # Accept those vertically adjacent labels, but reject unrelated matches.
    if label == "Leipzig" and len(candidates) == 2:
        first, second = sorted(candidates, key=lambda point: point[1])
        if abs(first[0] - second[0]) < 40 and 0 < second[1] - first[1] < 65:
            candidates = [first]
    if len(candidates) != 1:
        raise RuntimeError(f"Expected one visible {label!r} inside the CarPlay window; found {candidates}")
    x, y = candidates[0]
    # Simulator's rendered controls do not implement AX coordinate hit testing.
    # Send a normal mouse press through osascript, using the observed location.
    script = '''
ObjC.import("CoreGraphics");
ObjC.import("Foundation");
var point = $.CGPointMake(%d, %d);
var down = $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, point, $.kCGMouseButtonLeft);
var up = $.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, point, $.kCGMouseButtonLeft);
$.CGEventPost($.kCGHIDEventTap, down);
$.NSThread.sleepForTimeInterval(0.08);
$.CGEventPost($.kCGHIDEventTap, up);
''' % (round(x), round(y))
    execute(["osascript", "-l", "JavaScript", "-e", script])
    time.sleep(2)


def capture(name, expected):
    await_native_text(*expected)
    path = OUTPUT / name
    external(path)
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    width, height = struct.unpack(">II", data[16:24])
    assert width > height, "The website CarPlay capture must be the landscape external display."
    captures.append({
        "file": name,
        "width": width,
        "height": height,
        "sha256": hashlib.sha256(data).hexdigest(),
        "capturedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    })


execute(["xcrun", "simctl", "launch", DEVICE, "de.nextstop.app", "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"])
time.sleep(3)
execute(["xcrun", "simctl", "io", DEVICE, "enumerate"])
home = external(OUTPUT / "diagnostic-before-app.png")
if not any("Fahrt wählen" in row["text"] for row in home["text"]):
    click_visible_text("nextStop")
capture("carplay-profiles.png", ["Fahrt wählen", "Leipzig"])
click_visible_text("Leipzig")
capture("carplay-ride-summary.png", ["Leipzig", "Suche starten", "Filter ändern"])
source = json.loads((OUTPUT / "capture-source-base.json").read_text())
source.update({
    "processing": "Original simctl external-display PNG files, without pixel modifications",
    "screenshots": captures,
})
(OUTPUT / "capture-source.json").write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
print(f"Captured {len(captures)} native CarPlay screens.")
