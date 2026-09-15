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
click_count = 0


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


def click_visible_text(label, display_kind="external", *, first_match=False):
    global click_count
    click_count += 1
    # Raise the observed CarPlay window; do not click coordinates inferred from
    # the iPhone window, where a matching profile name can also appear.
    window_selector = ('first window whose name ends with " – CarPlay"' if display_kind == "external"
                       else 'first window whose name contains "nextStop CarPlay Capture" and name does not end with " – CarPlay"')
    window = execute(["osascript", "-e", '''
tell application "System Events" to tell process "Simulator"
    set frontmost to true
    set captureWindow to WINDOW_SELECTOR
    perform action "AXRaise" of captureWindow
    set windowPosition to position of captureWindow
    set windowSize to size of captureWindow
    return (item 1 of windowPosition as text) & "|" & (item 2 of windowPosition as text) & "|" & (item 1 of windowSize as text) & "|" & (item 2 of windowSize as text)
end tell
'''.replace("WINDOW_SELECTOR", window_selector)])
    left, top, width, height = map(float, window.split("|"))
    time.sleep(1)
    path = OUTPUT / f"diagnostic-host-click-{click_count}.png"
    execute(["screencapture", "-x", str(path)])
    words = recognize(path)
    display = json.loads(execute([OCR, "display"]))
    scale_x, scale_y = display["width"] / words["width"], display["height"] / words["height"]
    candidates = []
    for word in words["text"]:
        x = display["x"] + (word["x"] + word["width"] / 2) * scale_x
        y = display["y"] + (word["y"] + word["height"] / 2) * scale_y
        if word["text"].strip().casefold() == label.casefold() and left < x < left + width and top < y < top + height:
            if label == "nextStop":
                # The observed home screen puts the icon center about 3.5 label
                # heights above its text. Tap the icon itself, not its caption.
                y -= 3.5 * word["height"] * scale_y
            candidates.append((x, y))
    # Profile name and destination are both Leipzig in the same native row.
    # Accept those vertically adjacent labels, but reject unrelated matches.
    if label == "Leipzig" and len(candidates) == 2:
        first, second = sorted(candidates, key=lambda point: point[1])
        if abs(first[0] - second[0]) < 40 and 0 < second[1] - first[1] < 65:
            candidates = [first]
    if first_match and candidates:
        # Explicitly requested for the first visible result row, whose driving
        # distance can legitimately equal another row's rounded distance.
        candidates = [min(candidates, key=lambda point: point[1])]
    if len(candidates) != 1:
        raise RuntimeError(f"Expected one visible {label!r} inside the CarPlay window; found {candidates}")
    x, y = candidates[0]
    execute(["osascript", "-l", "JavaScript", "scripts/carplay-capture/mouse.jxa", str(round(x)), str(round(y))])
    execute(["screencapture", "-x", "-C", str(OUTPUT / f"diagnostic-host-after-click-{click_count}.png")])
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


if __name__ == "__main__":
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
