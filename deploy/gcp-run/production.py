#!/usr/bin/env python3
"""Prepare a production Cloud Run definition or update the already commissioned installation.

Initial restore, writer handoff, domain and scheduler commissioning are separate.
Protected hosting selection only switches after those gates have succeeded.
"""
import argparse
import json
import os
from pathlib import Path
import sys

import deploy
import production_backup
import release
import render

TARGET = render.PRODUCTION
BASE = deploy.ROOT / "deploy/environments/production-cloud-run.json"


def configuration(commit, image, evidence, *, offline=False):
    config = json.loads(BASE.read_text())
    config.update(commit=commit, backendImage=image, retainedTraffic={}, acceptanceEvidence=evidence)
    return render.validate(config, TARGET.environment, offline=offline)


def require_clean_scan(config, report):
    counts = report.get("counts")
    if (report.get("commit") != config["commit"] or report.get("image") != config["backendImage"]
            or report.get("passed") is not True or report.get("inventoryProfile") != "backend"
            or report.get("scanner") != "trivy" or report.get("blockingFindings") != []
            or not isinstance(counts, dict) or set(counts) != {"UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL"}
            or any(type(count) is not int or count != 0 for count in counts.values())):
        raise release.ReleaseError("Production requires zero known findings in the freshly scanned exact image.")


def sql_definition(config):
    return {"name": TARGET.connection.split(":")[-1], "region": render.REGION, "databaseVersion": "POSTGRES_17",
            "settings": {"edition": "ENTERPRISE", "tier": "db-g1-small", "availabilityType": "ZONAL",
                         "dataDiskType": "PD_SSD", "dataDiskSizeGb": str(config["cloudSqlDiskGb"]),
                         "storageAutoResize": False, "deletionProtectionEnabled": True,
                         "backupConfiguration": {"enabled": False, "pointInTimeRecoveryEnabled": False},
                         "connectorEnforcement": "REQUIRED", "ipConfiguration": {"ipv4Enabled": True,
                         "authorizedNetworks": [], "sslMode": "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"},
                         "databaseFlags": [{"name": k, "value": v} for k, v in release.SQL_LOG_FLAGS.items()]}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("render", "hashes", "backup", "promote"))
    parser.add_argument("--commit")
    parser.add_argument("--image")
    parser.add_argument("--scan", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.mode in {"backup", "promote"}:
            if release.run(["gcloud", "config", "get-value", "account"]).strip() != TARGET.deploy_account:
                raise release.ReleaseError("Production requires its protected deployment identity.")
        if args.mode == "backup":
            print(json.dumps(production_backup.backup()))
            return
        # The production environment protects the operator receipt pin. Disk sizing is reviewed on the release branch.
        # No assumed evidence, secret values or mutable object references are accepted.
        offline = args.mode in {"hashes", "render"}
        evidence = json.loads(os.environ.get("NEXTSTOP_PRODUCTION_RUN_EVIDENCE") or "null")
        config = configuration(args.commit, args.image, evidence, offline=offline)
        if args.mode == "hashes":
            print(json.dumps(deploy.acceptance_hashes(config)))
        elif args.mode == "render":
            manifests = render.write_rendered(config, args.output)
            (args.output / "cloud-sql.json").write_text(json.dumps(sql_definition(config), indent=2) + "\n")
            print(json.dumps({"project": TARGET.project, "release": render.release_id(config), "manifests": len(manifests)}))
        else:
            if args.scan is None:
                raise release.ReleaseError("A fresh exact-image scan is required.")
            require_clean_scan(config, json.loads(args.scan.read_text()))
            release.run([sys.executable, str(deploy.ROOT / "deploy/gcp/verify-promotion.py"), "--require-cloud-run",
                         "--commit", args.commit, "--image", args.image])
            print(json.dumps(production_backup.backup()), flush=True)
            deploy.deploy(config, target=TARGET)
    except Exception as error:
        message = str(error) if isinstance(error, (release.ReleaseError, render.ConfigurationError)) else "Invalid production configuration or receipt."
        print(message, file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
