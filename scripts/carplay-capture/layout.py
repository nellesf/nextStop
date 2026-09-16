"""Coordinate a hosted CarPlay layout test with original native Simulator captures.

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
from dataclasses import dataclass

from capture import DEVICE, OUTPUT, click_visible_text, execute, recognize


def framebuffer(path, display):
    execute(["xcrun", "simctl", "io", DEVICE, "screenshot", f"--display={display}", str(path)])
    return recognize(path)


def normalized(value):
    return re.sub(r"\s+", " ", value.casefold().replace("’", "'").replace("–", "-")
                  .replace("“", '"').replace("”", '"')).strip()


def profile_frame_kind(frame, anchors):
    """Identify only observed root/home content; unknown frames are transitions."""
    rows = {normalized(row["text"]) for row in frame["text"]}
    matching = [normalized(anchor) in rows for anchor in anchors]
    if all(matching):
        return "profile"
    if any(matching):
        return "partial-profile"
    home_labels = {"messages", "calendar", "settings", "now playing"}
    if "nextstop" in rows and len(rows & home_labels) >= 2:
        return "home"
    return "transition"


@dataclass
class ProfileActivationState:
    clicks: int = 0
    last_click_at: float | None = None
    first_profile_at: float | None = None
    profile_frames: int = 0
    home_frames: int = 0
    profile_seen: bool = False

    def observe(self, kind, now):
        if kind == "profile":
            self.profile_seen = True
            self.home_frames = 0
            self.profile_frames += 1
            if self.first_profile_at is None:
                self.first_profile_at = now
            if self.profile_frames >= 2 and now - self.first_profile_at >= 2:
                return "ready"
            return "wait"
        if kind == "partial-profile":
            self.profile_seen = True
        self.profile_frames = 0
        self.first_profile_at = None
        self.home_frames = self.home_frames + 1 if kind == "home" else 0
        if self.home_frames >= 2 and not self.profile_seen and self.clicks < 2:
            if self.last_click_at is None or now - self.last_click_at >= 30:
                self.clicks += 1
                self.last_click_at = now
                self.home_frames = 0
                return "click"
        return "wait"


def activate_profile_root(state):
    anchors = state["expected"]
    assert len(anchors) == 2 and all(anchors), \
        "Profile readiness requires its section header and fixture profile name."
    assert state["label"] == "nextStop", "Only the observed nextStop icon can activate this root."
    started = time.monotonic()
    deadline = started + 120
    activation = ProfileActivationState()
    observations = []

    def profile_frame(path):
        execute([
            "xcrun", "simctl", "io", DEVICE, "screenshot", "--display=external", str(path),
        ], deadline=deadline)
        return recognize(path, deadline=deadline)

    def verify_home_before_click():
        # The helper's host capture and coordinate lookup take time. Verify
        # the external frame once more immediately before posting input.
        guard_path = OUTPUT / f"diagnostic-root-before-click-{activation.clicks}.png"
        guard_kind = profile_frame_kind(profile_frame(guard_path), anchors)
        entry["clickGuardKind"] = guard_kind
        if guard_kind != "home":
            if guard_kind in {"profile", "partial-profile"}:
                activation.profile_seen = True
            raise RuntimeError("The latest native frame is no longer the home page; icon input withheld.")

    # Every synchronous native command receives the same deadline, including
    # the fresh-frame guard and the helper's mouse dispatch and screenshots.
    try:
        while time.monotonic() < deadline:
            attempt = len(observations) + 1
            entry = {"attempt": attempt}
            observations.append(entry)
            try:
                path = OUTPUT / f"diagnostic-root-activation-{attempt:02d}.png"
                frame = profile_frame(path)
                now = time.monotonic()
                kind = profile_frame_kind(frame, anchors)
                decision = activation.observe(kind, now)
                entry.update({"kind": kind, "decision": decision, "elapsedSeconds": round(now - started, 1)})
                if decision == "ready" and now < deadline:
                    return
                if decision == "click" and deadline - now >= 15:
                    # click_visible_text rereads the native host window and
                    # refuses to click if the exact icon label disappeared.
                    click_visible_text(
                        state["label"], deadline=deadline, before_click=verify_home_before_click,
                    )
            except (RuntimeError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
                entry["error"] = str(error)
                # A failed capture interrupts consecutiveness; it cannot count
                # toward stable root readiness or a home-only retry decision.
                activation.observe("transition", time.monotonic())
            remaining = deadline - time.monotonic()
            if remaining > 0:
                time.sleep(min(2, remaining))
        raise TimeoutError("Profile root did not render two stable frames within 120 seconds after at most two native icon clicks.")
    finally:
        (OUTPUT / "root-activation.json").write_text(json.dumps({
            "anchors": anchors, "timeoutSeconds": 120, "retryDelaySeconds": 30,
            "maxClicks": 2, "state": vars(activation), "observations": observations,
        }, indent=2, ensure_ascii=False) + "\n")


def capture_phase(state):
    name = state["file"]
    assert re.fullmatch(r"carplay-[a-z-]+\.png", name), name
    display = state["display"]
    assert display == "external"
    expected = state["expected"]
    assert expected, "Every layout screenshot must validate visible native text."
    deadline = time.monotonic() + 90
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        path = OUTPUT / f"diagnostic-{state['phase']}-{attempt}.png"
        frame = framebuffer(path, display)
        visible = normalized("\n".join(row["text"] for row in frame["text"]))
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
            requested = (int(os.environ["CARPLAY_WIDTH"]), int(os.environ["CARPLAY_HEIGHT"]))
            assert (width, height) == requested, f"Requested {requested}, captured {(width, height)}"
            expected_texts = state.get("expectedTexts", expected)
            missing = [text for text in expected_texts if normalized(text) not in final_text]
            return {
                "file": name, "display": display,
                "expectedTexts": expected_texts,
                "notRecognized": missing,
                "ocrScope": "Missing text may be offscreen or clipped; matching OCR does not establish intact glyphs. Visual review required.",
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
                    execute(["xcrun", "simctl", "privacy", DEVICE, "grant", "location-always", "de.nextstop.app"], timeout=180)
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
                            activate_profile_root(state)
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
                        if not rows:
                            rows = [row for row in screen["text"]
                                    if re.fullmatch(r"\d+\s+Ladepunkte?", row["text"].strip(), re.IGNORECASE)]
                        assert rows, "The native result list must expose an observed distance or EVSE-count row."
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
            "carplay-profiles.png", "carplay-ride-summary.png", "carplay-criteria.png",
            "carplay-options-distance-range.png", "carplay-options-charging-points.png",
            "carplay-options-power.png", "carplay-options-food-chain.png",
            "carplay-results.png", "carplay-result-actions.png", "carplay-charging-places.png",
        }
        assert len(captures) == 10 and {item['file'] for item in captures} == required_files, captures
        source = json.loads((OUTPUT / "capture-source-base.json").read_text())
        fixture_path = documents / "website-capture-fixture.json"
        assert fixture_path.exists(), "The real MapKit place lookup and example data must have provenance."
        fixture = json.loads(fixture_path.read_text())
        (OUTPUT / "result-fixture.json").write_text(json.dumps(fixture, indent=2, ensure_ascii=False) + "\n")
        source.update({
            "data": "Example EVSE counts and power supplied through the unchanged app dependency interfaces; real MapKit places, route calculation, driving distances, filtering and template presentation",
            "fixture": fixture,
            "configuration": {
                "id": os.environ["CARPLAY_CONFIGURATION"],
                "width": int(os.environ["CARPLAY_WIDTH"]),
                "height": int(os.environ["CARPLAY_HEIGHT"]),
                "scale": float(os.environ["CARPLAY_SCALE"]),
            },
            "captureScope": fixture["captureScope"],
            "limitations": [
                "Reference fixture and initial scroll positions; arbitrary user/provider text is not exhaustively tested.",
                "OCR does not prove intact glyphs. Native screenshots need visual review.",
            ],
            "processing": "Original simctl internal and external display PNG files, without pixel modifications",
            "screenshots": captures,
        })
        (OUTPUT / "layout-capture-source.json").write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
        print(f"Captured {len(captures)} native CarPlay layout screens; visual review is required.", flush=True)
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
