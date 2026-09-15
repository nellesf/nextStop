#!/usr/bin/env python3
"""Verify and import original CarPlay matrix artifacts; never modify PNG pixels.

Usage: python3 scripts/carplay-capture/import-layout-captures.py DOWNLOADED_ARTIFACTS
Missing/failed configurations return exit code 1 after importing valid evidence.
Use --allow-partial for an explicitly partial import, or --replace to replace
different evidence for a configuration. Provenance conflicts always fail closed.
"""

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct
import sys
import tempfile


REPOSITORY = Path(__file__).resolve().parents[2]
MATRIX_PATH = Path(__file__).with_name("display-configurations.json")
MANIFEST = "layout-capture-source.json"
SCREENS = {
    "carplay-profiles.png": "Profiles",
    "carplay-ride-summary.png": "Ride summary",
    "carplay-criteria.png": "Criteria",
    "carplay-options-distance-range.png": "Distance options",
    "carplay-options-charging-points.png": "Charging-point options",
    "carplay-options-power.png": "Power options",
    "carplay-options-food-chain.png": "Restaurant options",
    "carplay-results.png": "Results",
    "carplay-result-actions.png": "Result actions",
    "carplay-charging-places.png": "Operator selection",
}
METADATA = (MANIFEST, "display-configuration.json", "preflight.json", "profile-test-summary.json")
PROVENANCE_KEYS = ("runURL", "harnessCommit", "appCommit")
REVIEW_NOTICE = (
    "Capture integrity and hosted-test success do not establish unclipped text. "
    "OCR may reconstruct clipped words or miss offscreen content. "
    "Every original PNG requires visual review; these are reference-flow captures."
)


class EvidenceError(ValueError):
    """An artifact cannot be admitted as completed evidence."""


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceError(f"Cannot read {path.name}: {error}") from error


def object_json(path):
    value = read_json(path)
    require(isinstance(value, dict), f"{path.name} must contain a JSON object")
    return value


def regular_file(directory, name):
    path = directory / name
    require(path.is_file() and not path.is_symlink(), f"Missing regular file: {name}")
    require(path.resolve().parent == directory.resolve(), f"File escapes artifact: {name}")
    return path


def positive_integer(value):
    return type(value) is int and value > 0


def matrix():
    values = read_json(MATRIX_PATH)
    require(isinstance(values, list) and values, "Display matrix must be a nonempty array")
    result = {}
    for config in values:
        require(isinstance(config, dict), "Display configuration must be an object")
        identifier = config.get("id")
        require(isinstance(identifier, str) and re.fullmatch(r"[a-z0-9-]+", identifier),
                "Invalid display configuration ID")
        require(identifier not in result, f"Duplicate display configuration: {identifier}")
        require(positive_integer(config.get("width")) and positive_integer(config.get("height")),
                f"Invalid display dimensions: {identifier}")
        require(type(config.get("scale")) in (int, float) and config["scale"] > 0,
                f"Invalid display scale: {identifier}")
        result[identifier] = {key: config[key] for key in ("id", "width", "height", "scale")}
    return result


@dataclass
class Evidence:
    directory: Path
    manifest: dict
    files: dict

    @property
    def identifier(self):
        return self.manifest["configuration"]["id"]

    @property
    def provenance(self):
        return tuple(self.manifest[key] for key in PROVENANCE_KEYS)


def verify(directory, configurations):
    require(directory.is_dir() and not directory.is_symlink(), "Artifact must be a regular directory")
    files = {name: regular_file(directory, name) for name in METADATA}
    source = object_json(files[MANIFEST])
    config = source.get("configuration")
    require(isinstance(config, dict), "Manifest is missing configuration")
    identifier = config.get("id")
    require(isinstance(identifier, str) and identifier in configurations,
            f"Unknown display configuration: {identifier!r}")
    expected = configurations[identifier]
    require(positive_integer(config.get("width")) and positive_integer(config.get("height")),
            "Configuration width/height must be positive integers")
    require(type(config.get("scale")) in (int, float), "Configuration scale must be numeric")
    require(all(config.get(key) == value for key, value in expected.items()),
            f"Configuration does not match display-configurations.json: {identifier}")
    for key in ("harnessCommit", "appCommit"):
        require(isinstance(source.get(key), str) and re.fullmatch(r"[0-9a-f]{40}", source[key]),
                f"Manifest requires a full lowercase Git SHA for {key}")
    require(isinstance(source.get("runURL"), str) and re.fullmatch(
        r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+",
        source["runURL"]), "Manifest requires a GitHub Actions run URL")

    summary = object_json(files["profile-test-summary.json"])
    for key, value in {"totalTestCount": 1, "passedTests": 1, "failedTests": 0,
                       "skippedTests": 0}.items():
        require(type(summary.get(key)) is int and summary[key] == value,
                f"Hosted test summary must have {key}={value}")
    preflight = object_json(files["preflight.json"])
    display = object_json(files["display-configuration.json"])
    require(display.get("id") == identifier and display.get("runSubmitted") is True,
            "Display configuration was not submitted for the expected ID")
    for key in ("requested", "readback"):
        values = display.get(key)
        require(isinstance(values, dict) and all(
            type(values.get(field)) in (int, float) and values[field] == expected[field]
            for field in ("width", "height", "scale")),
            f"Display configuration {key} differs from the planned matrix")
    require(display.get("runURL") == source["runURL"]
            and display.get("harnessCommit") == source["harnessCommit"],
            "Display configuration and capture manifest provenance differ")
    require(preflight.get("configuration") == display,
            "Preflight did not verify this exact display configuration")
    readiness = preflight.get("readiness")
    require(isinstance(readiness, list) and readiness and isinstance(readiness[-1], dict)
            and readiness[-1].get("ready") is True, "Preflight did not confirm a ready display")
    require(isinstance(preflight.get("deviceID"), str) and preflight["deviceID"],
            "Preflight is missing deviceID")
    require(display.get("deviceID") == preflight["deviceID"],
            "Display configuration and preflight device IDs differ")
    devices = summary.get("devicesAndConfigurations", [])
    require(isinstance(devices, list), "Invalid hosted-test device metadata")
    for entry in devices:
        require(isinstance(entry, dict) and isinstance(entry.get("device"), dict),
                "Invalid hosted-test device entry")
        device_id = entry["device"].get("deviceId")
        require(device_id == preflight["deviceID"], "Hosted test and preflight device IDs differ")

    screenshots = source.get("screenshots")
    require(isinstance(screenshots, list) and len(screenshots) == len(SCREENS),
            "Manifest must contain exactly ten screenshots")
    require(all(isinstance(item, dict) for item in screenshots), "Invalid screenshot metadata")
    names = [item.get("file") for item in screenshots]
    require(all(isinstance(name, str) for name in names) and set(names) == set(SCREENS),
            "Manifest screenshot filenames do not match the ten required phases")
    for screenshot in screenshots:
        name = screenshot["file"]
        require(screenshot.get("display") == "external", f"{name} is not an external display")
        require(screenshot.get("ownerApp") == "nextStop", f"Unexpected screenshot owner: {name}")
        require(screenshot.get("width") == expected["width"]
                and screenshot.get("height") == expected["height"], f"Wrong manifest dimensions: {name}")
        path = regular_file(directory, name)
        data = path.read_bytes()
        require(len(data) >= 33 and data[:8] == b"\x89PNG\r\n\x1a\n"
                and data[8:16] == b"\x00\x00\x00\rIHDR", f"Invalid PNG header: {name}")
        dimensions = struct.unpack(">II", data[16:24])
        require(dimensions == (expected["width"], expected["height"]),
                f"Wrong actual PNG dimensions: {name}: {dimensions}")
        require(hashlib.sha256(data).hexdigest() == screenshot.get("sha256"),
                f"PNG SHA-256 mismatch: {name}")
        ocr_name = path.with_suffix(".ocr.json").name
        ocr_path = regular_file(directory, ocr_name)
        ocr = object_json(ocr_path)
        require((ocr.get("width"), ocr.get("height")) == dimensions,
                f"OCR dimensions do not match PNG: {ocr_name}")
        require(isinstance(ocr.get("text"), list)
                and all(isinstance(row, dict) and isinstance(row.get("text"), str)
                        for row in ocr["text"]), f"Invalid OCR text rows: {ocr_name}")
        for key in ("expectedTexts", "notRecognized"):
            require(isinstance(screenshot.get(key), list)
                    and all(isinstance(text, str) for text in screenshot[key]),
                    f"Invalid {key} metadata: {name}")
        files[name] = path
        files[ocr_name] = ocr_path
    return Evidence(directory, source, files)


def artifact_hint(path, root, configurations):
    for candidate in (path, *path.parents):
        identifier = candidate.name.removeprefix("carplay-layout-")
        if identifier in configurations:
            return identifier
        if candidate == root:
            break
    return None


def same_files(first, second):
    return set(first.files) == set(second.files) and all(
        first.files[name].read_bytes() == second.files[name].read_bytes() for name in first.files)


def discover(root, configurations):
    found, problems = {}, {identifier: [] for identifier in configurations}
    unassigned = []
    manifest_paths = sorted(root.rglob(MANIFEST))
    manifest_directories = {path.parent for path in manifest_paths}
    for path in manifest_paths:
        identifier = artifact_hint(path.parent, root, configurations)
        try:
            raw = object_json(regular_file(path.parent, path.name))
            raw_config = raw.get("configuration", {})
            if (isinstance(raw_config, dict) and isinstance(raw_config.get("id"), str)
                    and raw_config["id"] in configurations):
                identifier = raw_config["id"]
            evidence = verify(path.parent, configurations)
        except (EvidenceError, OSError) as error:
            message = f"{path.parent.relative_to(root)}: {error}"
            (problems[identifier] if identifier else unassigned).append(message)
            continue
        if evidence.identifier in found:
            require(same_files(evidence, found[evidence.identifier]),
                    f"Conflicting downloaded artifacts for {evidence.identifier}")
        else:
            found[evidence.identifier] = evidence
    # Failed runs often contain preflight/logs but never reach the final manifest.
    artifact_roots = {path.parent for name in ("preflight.json", "profile-test-summary.json")
                      for path in root.rglob(name)}
    artifact_roots.add(root)
    artifact_roots.update(path for path in root.iterdir() if path.is_dir()
                          and path.name.startswith("carplay-layout-"))
    for directory in sorted(artifact_roots):
        identifier = artifact_hint(directory, root, configurations)
        if identifier and not any(path == directory or directory in path.parents
                                  for path in manifest_directories):
            message = f"{directory.relative_to(root)}: completed layout manifest is absent"
            if message not in problems[identifier]:
                problems[identifier].append(message)
    return found, problems, unassigned


def install(evidence, destination, configurations):
    target = destination / evidence.identifier
    stage = Path(tempfile.mkdtemp(prefix=f".{evidence.identifier}-", dir=destination))
    backup = None
    try:
        for name, source in evidence.files.items():
            shutil.copyfile(source, stage / name)
        staged = verify(stage, configurations)
        require(staged.manifest == evidence.manifest, "Artifact manifest changed during import")
        if target.exists():
            backup = Path(tempfile.mkdtemp(prefix=f".previous-{evidence.identifier}-", dir=destination))
            backup.rmdir()
            target.rename(backup)
        try:
            stage.rename(target)
        except OSError:
            if backup is not None:
                backup.rename(target)
                backup = None
            raise
    finally:
        if stage.exists():
            shutil.rmtree(stage)
        if backup is not None and backup.exists():
            shutil.rmtree(backup)


def write_index(destination, configurations, evidence, problems, unassigned):
    identity = next(iter(evidence.values())).provenance if evidence else None
    records = []
    lines = ["# Native CarPlay capture evidence", "", REVIEW_NOTICE, ""]
    if identity:
        provenance = dict(zip(PROVENANCE_KEYS, identity))
        lines += [f"Run: [GitHub Actions]({provenance['runURL']}).",
                  f"App: `{provenance['appCommit']}`. Harness: `{provenance['harnessCommit']}`.", ""]
    else:
        provenance = None
    complete = len(evidence) == len(configurations) and not unassigned
    lines += [f"Verified capture sets: **{len(evidence)}/{len(configurations)}**. "
              + ("The planned matrix was captured." if complete else "The planned matrix is incomplete."),
              "", "| Configuration | Pixels | Scale | Evidence |",
              "| --- | --- | --- | --- |"]
    for identifier, config in configurations.items():
        record = dict(config)
        record["status"] = "captured" if identifier in evidence else (
            "incomplete" if problems[identifier] else "absent")
        if identifier in evidence:
            item = evidence[identifier]
            record["screenshotCount"] = len(SCREENS)
            record["manifest"] = f"{identifier}/{MANIFEST}"
            record["ocrStringsNotRecognized"] = sum(
                len(screen["notRecognized"]) for screen in item.manifest["screenshots"])
            record["visualReview"] = "required"
            link = f"[Gallery](#{identifier}) · [Manifest]({identifier}/{MANIFEST})"
        else:
            record["issues"] = problems[identifier]
            link = record["status"]
        records.append(record)
        lines.append(f"| {identifier} | {config['width']} × {config['height']} "
                     f"| @{config['scale']:g}x | {link} |")
    for identifier in configurations:
        if identifier not in evidence:
            continue
        lines += ["", f"## {identifier}", "",
                  " · ".join(f"[{label}]({identifier}/{name})" for name, label in SCREENS.items()),
                  "", f"[Hosted test summary]({identifier}/profile-test-summary.json) · "
                  f"[Preflight]({identifier}/preflight.json). "
                  "OCR JSON files sit beside their original PNGs."]
    issues = [message for messages in problems.values() for message in messages] + unassigned
    if issues:
        lines += ["", "## Incomplete or rejected artifacts", ""]
        lines += ["- " + message.replace("\n", " ") for message in issues]
    index = {"schemaVersion": 1, "matrixComplete": complete,
             "verifiedConfigurationCount": len(evidence), "expectedConfigurationCount": len(configurations),
             "source": provenance, "reviewNotice": REVIEW_NOTICE,
             "configurations": records, "unassignedArtifactIssues": unassigned}
    (destination / "index.json").write_text(json.dumps(index, indent=2, ensure_ascii=False) + "\n")
    (destination / "README.md").write_text("\n".join(lines) + "\n")
    return complete


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path, help="Directory containing downloaded artifact folders")
    parser.add_argument("--destination", type=Path,
                        default=REPOSITORY / "docs/testing/carplay-layout/captures")
    parser.add_argument("--allow-partial", action="store_true",
                        help="Return success for a verified subset; still report missing configurations")
    parser.add_argument("--replace", action="store_true",
                        help="Replace different evidence in existing configuration directories")
    args = parser.parse_args()
    try:
        configurations = matrix()
        root, destination = args.source.resolve(), args.destination.resolve()
        require(root.is_dir(), f"Source directory does not exist: {root}")
        require(root != destination and root not in destination.parents
                and destination not in root.parents, "Source and destination must be separate directories")
        incoming, problems, unassigned = discover(root, configurations)
        existing = {}
        for identifier in configurations:
            path = destination / identifier
            if path.exists() or path.is_symlink():
                try:
                    existing[identifier] = verify(path, configurations)
                except EvidenceError:
                    require(args.replace and identifier in incoming and path.is_dir()
                            and not path.is_symlink() and (path / MANIFEST).is_file(),
                            f"Existing evidence is invalid for {identifier}; provide a verified "
                            "replacement with --replace")
                    continue
                require(existing[identifier].identifier == identifier,
                        f"Existing evidence directory has a different ID: {identifier}")
        for identifier, item in incoming.items():
            if identifier in existing and not same_files(item, existing[identifier]):
                require(args.replace, f"Different evidence exists for {identifier}; use --replace explicitly")
        combined = {**existing, **incoming}
        require(len({item.provenance for item in combined.values()}) <= 1,
                "Configurations do not share one runURL, harnessCommit and appCommit; "
                "use a separate destination or replace the complete previous matrix")
        destination.mkdir(parents=True, exist_ok=True)
        for identifier, item in incoming.items():
            if identifier not in existing or not same_files(item, existing[identifier]):
                install(item, destination, configurations)
        complete = write_index(destination, configurations, combined, problems, unassigned)
        print(f"Verified {len(combined)}/{len(configurations)} configuration sets; "
              f"imported {len(incoming)} completed artifact sets into {destination}.")
        for identifier in configurations:
            if identifier not in combined:
                print(f"{identifier}: " + ("incomplete" if problems[identifier] else "absent"))
        for message in [item for messages in problems.values() for item in messages] + unassigned:
            print(message, file=sys.stderr)
        print(REVIEW_NOTICE)
        return 0 if incoming and (complete or (args.allow_partial and not unassigned)) else 1
    except (EvidenceError, OSError) as error:
        print(f"Import refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
