#!/usr/bin/env python3
"""Prepare local review artifacts only. This CLI never connects to a database or cloud API."""
import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess

PROJECT = "nextstop-tech-testing"
BASE_TABLES = frozenset({
    "availability_observations", "availability_snapshots", "charging_campus_park_memberships",
    "charging_campus_power_projection", "charging_campus_projection", "charging_park_food_poi_matches",
    "charging_park_location_memberships", "charging_park_power_projection", "charging_park_projection",
    "food_poi_projection", "food_poi_projection_versions", "food_poi_quarantine",
    "normalized_charging_locations", "normalized_charging_points", "projection_conflicts",
    "projection_versions", "provider_quarantine", "provider_records", "schema_migrations",
    "static_projection_input_checks", "app_attest_keys", "app_attest_challenges", "user_error_reports",
    "live_refresh_control", "monthly_ingestion_schedule",
})


def checked_connection(value):
    if not re.fullmatch(r"nextstop-tech-testing:europe-west1:[a-z](?:[a-z0-9-]{0,96}[a-z0-9])?", value):
        raise ValueError("Expected the authorized staging Cloud SQL connection in europe-west1.")
    return value


def expected_tables(purpose, migrations):
    if purpose not in ("handoff", "backup") or migrations not in (17, 18):
        raise ValueError("Unreviewed snapshot purpose or schema version.")
    return (BASE_TABLES | ({"monthly_import_budget"} if migrations == 18 else set())) - (
        {"user_error_reports"} if purpose == "backup" else set())


def checked_directory(value):
    directory = Path(value)
    if not directory.is_absolute() or directory.is_symlink():
        raise ValueError("A private absolute local directory is required.")
    directory.mkdir(mode=0o700, exist_ok=True)
    info = directory.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("Snapshot directory must be owned by this operator and mode 0700.")
    return directory.resolve()


def write_private(path, text):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(text)


def plan(connection, directory, purpose, migrations):
    checked_connection(connection)
    expected_tables(purpose, migrations)
    archive = directory / (purpose + ".dump")
    dump = ["pg_dump", "--dbname=service=nextstop_staging_source", "--format=custom", "--schema=nextstop",
            "--no-owner", "--no-privileges", "--lock-wait-timeout=500ms", "--file=" + str(archive)]
    if purpose == "backup":
        dump.append("--exclude-table=nextstop.user_error_reports")
    return {"version": 1, "purpose": purpose, "sourceProject": PROJECT,
            "targetConnectionName": connection, "sourceMigrations": migrations,
            "durableStorageAllowed": purpose == "backup", "maximumHandoffHours": 4,
            "dumpArgv": dump,
            **({"reportSchemaExportArgv": ["psql", "--dbname=service=nextstop_staging_source", "-XqAt",
                 "-v", "ON_ERROR_STOP=1", "--file=" + str(Path(__file__).resolve().parents[2] / "backend/operations/export-report-schema.sql")],
                "reportSchemaOutput": str(directory / "report-schema.sql"),
                "reportSchemaRestoreArgv": ["psql", "--dbname=service=nextstop_staging_cloudsql", "-Xq",
                 "-v", "ON_ERROR_STOP=1", "--single-transaction", "--file=" + str(directory / "report-schema.sql")]}
               if purpose == "backup" else {}),
            "restoreArgv": ["pg_restore", "--dbname=service=nextstop_staging_cloudsql", "--schema=nextstop",
                            "--no-owner", "--no-privileges", "--exit-on-error", "--single-transaction",
                            "--use-list=" + str(directory / "restore.list"), str(archive)],
            "requirements": ["Operator verifies both service-file endpoints; credentials stay outside commands/logs.",
                             "Freeze old staging writers for the final handoff; never dump production here.",
                             "Preinstall postgis/btree_gist and nextstop schema with the reviewed bootstrap.",
                             "Run prepare after dumping; it validates the exact reviewed TABLE DATA inventory.",
                             "Restore as nextstop_app; apply report-schema.sql only when receipt says restoreSupplementRequired=true, before migrations/grants.",
                             "Backup excludes the entire report table; export its separate schema with no report SELECT grant.",
                             "Keep report-schema.sql (0600) with its archive and receipt; verify both hashes before restore.",
                             "Do not execute the destructive integration suite against the restored staging database.",
                             "Handoff may include staging reports only for immediate private transfer; never upload it as backup.",
                             "Instance-level backup/PITR must not silently retain excluded report payloads.",
                             "After verification remove exact transient files and source copies; preserve application signing keys."]}


def validate_listing(listing, purpose, migrations):
    found = []
    output = []
    for line in listing.splitlines():
        if line.startswith(";") or not line.strip():
            output.append(line)
            continue
        if " TABLE DATA " in line:
            match = re.fullmatch(r"\d+; \d+ \d+ TABLE DATA nextstop ([a-z_]+) [a-z_]+", line)
            if match is None:
                raise ValueError("Unreviewed archive data object.")
            found.append(match[1])
        # Cloud SQL owns extensions; nextstop schema is precreated explicitly.
        if " EXTENSION " in line or " SCHEMA - nextstop " in line:
            output.append("; " + line)
        else:
            output.append(line)
    if len(found) != len(set(found)) or set(found) != expected_tables(purpose, migrations):
        raise ValueError("Archive data inventory differs from its reviewed purpose and schema version.")
    return "\n".join(output) + "\n"


def prepare(archive, directory, purpose, migrations, pg_restore="pg_restore"):
    if archive.is_symlink() or not archive.is_file():
        raise ValueError("Archive must be a regular private file.")
    info = archive.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError("Archive must be operator-owned and mode 0600.")
    now = datetime.now(timezone.utc)
    if purpose == "handoff" and now.timestamp() - info.st_mtime > 4 * 60 * 60:
        raise ValueError("Private handoff archive exceeded its four-hour transfer window.")
    result = subprocess.run([pg_restore, "--list", str(archive)], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise ValueError("Archive inspection failed; private tool output suppressed.")
    listing = validate_listing(result.stdout, purpose, migrations)
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    receipt = {"version": 1, "purpose": purpose, "bytes": info.st_size, "sha256": digest.hexdigest(),
               "dataTableCount": len(expected_tables(purpose, migrations)), "sourceMigrations": migrations,
               "durableStorageAllowed": purpose == "backup", "preparedAt": now.isoformat()}
    if purpose == "backup":
        embedded_report_schema = bool(re.search(r"^\d+; \d+ \d+ TABLE nextstop user_error_reports [a-z_]+$", result.stdout, re.MULTILINE))
        receipt["restoreSupplementRequired"] = not embedded_report_schema
        receipt["excludedTables"] = ["nextstop.user_error_reports"] if not embedded_report_schema else []
        receipt["excludedTableData"] = ["nextstop.user_error_reports"]
    if purpose == "backup" and receipt["restoreSupplementRequired"]:
        supplement = directory / "report-schema.sql"
        if supplement.is_symlink() or not supplement.is_file():
            raise ValueError("Backup requires its catalog-only report schema supplement.")
        metadata = supplement.stat()
        if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & 0o077 or not 0 < metadata.st_size <= 65536:
            raise ValueError("Report schema supplement must be a bounded private operator-owned file.")
        receipt["reportSchema"] = {"file": supplement.name, "bytes": metadata.st_size,
                                   "sha256": hashlib.sha256(supplement.read_bytes()).hexdigest()}
    if purpose == "handoff":
        receipt["deleteBy"] = (datetime.fromtimestamp(info.st_mtime, timezone.utc) + timedelta(hours=4)).isoformat()
    write_private(directory / "restore.list", listing)
    write_private(directory / "archive-receipt.json", json.dumps(receipt, indent=2) + "\n")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["plan", "prepare"])
    parser.add_argument("--directory", required=True)
    parser.add_argument("--purpose", choices=["handoff", "backup"], required=True)
    parser.add_argument("--source-migrations", type=int, choices=[17, 18], default=17)
    parser.add_argument("--connection-name")
    parser.add_argument("--pg-restore", default="pg_restore")
    args = parser.parse_args()
    directory = checked_directory(args.directory)
    if args.operation == "plan":
        value = plan(args.connection_name or "", directory, args.purpose, args.source_migrations)
        write_private(directory / "plan.json", json.dumps(value, indent=2) + "\n")
        print(json.dumps({"prepared": "plan", "cloudOrDatabaseActions": 0}))
    else:
        value = prepare(directory / (args.purpose + ".dump"), directory, args.purpose,
                        args.source_migrations, args.pg_restore)
        print(json.dumps({"prepared": "archive", "dataTableCount": value["dataTableCount"],
                          "durableStorageAllowed": value["durableStorageAllowed"]}))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError):
        raise SystemExit("Local snapshot preparation failed; no cloud or database action was executed.") from None
