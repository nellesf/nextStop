"""Coordinate a hosted Main-app test with original native Simulator captures.

Only the disposable GitHub simulator is used. The test exercises the unchanged
application's dependency interfaces and signals when each real view is ready.
No image is drawn, cropped, retouched, or reconstructed by this harness.
"""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import time

from capture import DEVICE, OUTPUT, await_native_text, click_visible_text, execute, recognize


def framebuffer(path, display):
    execute(["xcrun", "simctl", "io", DEVICE, "screenshot", f"--display={display}", str(path)])
    return recognize(path)


def normalized(value):
    return re.sub(r"\s+", " ", value.casefold().replace("’", "'").replace("–", "-")
                  .replace("“", '"').replace("”", '"')).strip()


def dismiss_maps_widget_prompt(frame):
    visible = normalized(" ".join(row["text"] for row in frame["text"]))
    if 'allow widgets from "maps" to' in visible and "use your location?" in visible:
        click_visible_text("Don't Allow", "internal")
        return True
    return False


def complete_maps_introduction(visible):
    # These exact first-use screens were observed on the disposable runner.
    # Maps receives only its simulated Nuremberg location; notifications remain
    # disabled. Finish onboarding before checking any place name behind it.
    if 'allow "maps" to use your location?' in visible and "allow while using app" in visible:
        click_visible_text("Allow While Using App", "internal")
    elif "enable notifications" in visible and "not now" in visible:
        click_visible_text("Not Now", "internal")
    elif "maps may show local ads based" in visible and "continue" in visible:
        click_visible_text("Continue", "internal")
    elif "welcome to maps" in visible and "continue" in visible:
        click_visible_text("Continue", "internal")
    elif "willkommen bei karten" in visible and "fortfahren" in visible:
        click_visible_text("Fortfahren", "internal")
    else:
        return False
    return True


def capture_phase(state):
    name = state["file"]
    assert re.fullmatch(r"(?:iphone|carplay)-[a-z-]+\.png", name), name
    display = state["display"]
    assert display in {"internal", "external"}
    expected = state["expected"]
    assert expected, "Every website screenshot must validate visible native text."
    deadline = time.monotonic() + 90
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        path = OUTPUT / f"diagnostic-{state['phase']}-{attempt}.png"
        frame = framebuffer(path, display)
        visible = normalized("\n".join(row["text"] for row in frame["text"]))
        if display == "internal" and dismiss_maps_widget_prompt(frame):
            continue
        if display == "internal" and state.get("ownerApp") == "Apple Maps" and complete_maps_introduction(visible):
            continue
        if all(normalized(text) in visible for text in expected):
            time.sleep(2)
            final = OUTPUT / name
            final_frame = framebuffer(final, display)
            final_text = normalized("\n".join(row["text"] for row in final_frame["text"]))
            if not all(normalized(text) in final_text for text in expected):
                continue
            data = final.read_bytes()
            assert data[:8] == b"\x89PNG\r\n\x1a\n"
            width, height = struct.unpack(">II", data[16:24])
            assert (width > height) == (display == "external")
            return {
                "file": name, "display": display,
                "ownerApp": state.get("ownerApp", "nextStop"),
                "width": width, "height": height,
                "sha256": hashlib.sha256(data).hexdigest(),
                "capturedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            }
        time.sleep(2)
    raise RuntimeError(f"Native {name} did not show {expected!r}; observed {visible}")


app = Path("CarPlayDerivedData/Build/Products/Debug-iphonesimulator/NextStopApp.app")
execute(["xcrun", "simctl", "install", DEVICE, str(app)], timeout=180)
execute(["xcrun", "simctl", "privacy", DEVICE, "grant", "location-always", "de.nextstop.app"], timeout=180)
execute(["xcrun", "simctl", "location", DEVICE, "set", "49.4521,11.0767"], timeout=180)
container = Path(execute(["xcrun", "simctl", "get_app_container", DEVICE, "de.nextstop.app", "data"], timeout=180))
documents = container / "Documents"
documents.mkdir(exist_ok=True)
state_path = documents / "website-capture-state.json"
command_path = documents / "website-capture-command.json"
for path in [state_path, command_path]:
    path.unlink(missing_ok=True)

command = [
    "xcodebuild", "-xctestrun", (OUTPUT / "xctestrun-path.txt").read_text().strip(),
    "-destination", f"platform=iOS Simulator,id={DEVICE}",
    "-resultBundlePath", "CarPlaySetup.xcresult",
    "-only-testing:NextStopAppTests/ProfileRepositoryTests/testCaptureWebsiteResultScreenshots",
    "-parallel-testing-enabled", "NO", "test-without-building",
]
captures = []
seen = set()
with (OUTPUT / "profile-setup.log").open("w") as log:
    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 1_200
        next_container_check = 0
        permissions_reapplied = False
        while time.monotonic() < deadline:
            # Xcode installs the app host again before XCTest starts and can
            # replace its data-container UUID. Do not keep the pre-test URL.
            if not seen and time.monotonic() >= next_container_check:
                next_container_check = time.monotonic() + 3
                try:
                    lookup = subprocess.run(
                        ["xcrun", "simctl", "get_app_container", DEVICE, "de.nextstop.app", "data"],
                        text=True, capture_output=True, timeout=30)
                except subprocess.TimeoutExpired:
                    # CoreSimulator can be unresponsive while XCTest installs
                    # the host. Keep polling within the overall deadline.
                    lookup = None
                    print("Waiting for XCTest data container; lookup timed out.", flush=True)
                if lookup is not None and lookup.returncode == 0 and lookup.stdout.strip():
                    live_container = Path(lookup.stdout.strip())
                    if live_container != container:
                        print(f"XCTest app container changed: {container} -> {live_container}", flush=True)
                        container = live_container
                    documents = container / "Documents"
                    state_path = documents / "website-capture-state.json"
                    command_path = documents / "website-capture-command.json"
                else:
                    print("Waiting for Xcode to finish installing the hosted test app.", flush=True)
            if state_path.exists():
                if not permissions_reapplied:
                    execute(["xcrun", "simctl", "privacy", DEVICE, "grant", "location-always", "de.nextstop.app"])
                    permissions_reapplied = True
                state = json.loads(state_path.read_text())
                phase = state["phase"]
                if phase not in seen:
                    print(f"Hosted capture phase: {state}", flush=True)
                    (OUTPUT / f"phase-{phase}.json").write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n")
                    if state.get("error"):
                        for display in ["internal", "external"]:
                            framebuffer(OUTPUT / f"diagnostic-failure-{display}.png", display)
                        try:
                            process.wait(timeout=45)
                        except subprocess.TimeoutExpired:
                            print("XCTest did not finish preserving its failure report within 45 seconds.", flush=True)
                        raise RuntimeError(f"Hosted test failed: {state}")
                    action = state.get("action")
                    if action == "click":
                        if phase == "waiting-for-carplay":
                            ready = False
                            for attempt in range(15):
                                screen = framebuffer(OUTPUT / f"diagnostic-app-icon-{attempt}.png", "external")
                                words = normalized("\n".join(row["text"] for row in screen["text"]))
                                if "fahrt wählen" in words:
                                    ready = True
                                    break
                                if "nextstop" in words:
                                    click_visible_text(state["label"])
                                    ready = True
                                    break
                                time.sleep(2)
                            assert ready, "The native CarPlay home screen must expose the installed nextStop app."
                            # A connected scene/rootTemplate can exist while
                            # CarPlay is still finishing setRootTemplate. Wait
                            # for the actual profile list to be visibly stable
                            # before the test invokes its first row handler.
                            await_native_text("Fahrt wählen", "Leipzig")
                            time.sleep(2)
                            await_native_text("Fahrt wählen", "Leipzig")
                        else:
                            click_visible_text(state["label"], state.get("display", "external"))
                    elif action == "activate-app":
                        execute(["xcrun", "simctl", "launch", DEVICE, "de.nextstop.app"])
                    elif action:
                        raise RuntimeError(f"Unsupported native capture action: {action}")
                    if phase == "carplay-result-actions":
                        # selectedIndex highlights a POI row, but CarPlay opens
                        # its detail card only after a native user selection.
                        # Select the first observed driving-distance row.
                        screen = framebuffer(OUTPUT / "diagnostic-before-result-selection.png", "external")
                        rows = [row for row in screen["text"]
                                if re.fullmatch(r"\d+(?:[.,]\d+)?\s*km\s+Fahrstrecke", row["text"].strip(), re.IGNORECASE)]
                        assert rows, "The native result list must expose a driving-distance row."
                        first = min(rows, key=lambda row: row["y"])
                        click_visible_text(first["text"].strip(), first_match=True)
                    if state.get("file"):
                        captures.append(capture_phase(state))
                    if state.get("returnToAppAfterCapture"):
                        execute(["xcrun", "simctl", "launch", DEVICE, "de.nextstop.app"])
                    temporary = command_path.with_suffix(".tmp")
                    temporary.write_text(json.dumps({"phase": phase, "command": "continue"}))
                    temporary.replace(command_path)
                    seen.add(phase)
            if process.poll() is not None:
                break
            time.sleep(0.3)
        else:
            raise TimeoutError("The hosted capture exceeded its 20-minute deadline.")
        assert process.wait(timeout=30) == 0, "Hosted capture test must pass. Inspect profile-setup.log."
        required_files = {
            "carplay-results.png", "carplay-result-actions.png", "carplay-charging-places.png",
            "carplay-restaurant-place.png", "carplay-charging-place.png",
            "iphone-results.png", "iphone-restaurant-place.png", "iphone-charging-place.png",
        }
        assert len(captures) == 8 and {item['file'] for item in captures} == required_files, captures
        source = json.loads((OUTPUT / "capture-source-base.json").read_text())
        fixture_path = documents / "website-capture-fixture.json"
        assert fixture_path.exists(), "The real MapKit place lookup and example data must have provenance."
        fixture = json.loads(fixture_path.read_text())
        (OUTPUT / "result-fixture.json").write_text(json.dumps(fixture, indent=2, ensure_ascii=False) + "\n")
        source.update({
            "data": "Example EVSE counts and power supplied through the unchanged app dependency interfaces; real MapKit places, route calculation, driving distances, filtering, presentation, place resolution and Apple Maps",
            "fixture": fixture,
            "processing": "Original simctl internal and external display PNG files, without pixel modifications",
            "screenshots": captures,
        })
        (OUTPUT / "result-capture-source.json").write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
        print(f"Captured {len(captures)} verified native result and place screens.", flush=True)
    finally:
        for name in ["website-capture-state.json", "website-capture-fixture.json"]:
            path = documents / name
            if path.exists():
                (OUTPUT / name).write_bytes(path.read_bytes())
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
        for display in ["internal", "external"]:
            try:
                framebuffer(OUTPUT / f"diagnostic-final-{display}.png", display)
            except Exception as error:
                print(f"Final {display} diagnostic unavailable: {error}", flush=True)
