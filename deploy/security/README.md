# Release security checks

Every Backend CI run (push, pull request, manual and daily at 05:23 UTC) audits
both production and complete npm dependencies. Moderate, high and critical npm
advisories block the run. The same gates run in the manual Cloud Build below.
The daily run never starts a release: the staging release workflow accepts only
a successful Backend run whose original event was a trusted main-branch push.

The final runtime image is scanned with **Trivy 0.75.0** for OS packages and
application libraries. **HIGH and CRITICAL findings block, including unfixed
findings**. Low/medium/unknown findings remain in the report. End-of-life OS,
missing OS/npm inventory, mismatched image identity, tool failure or unavailable
advisory database also fail. There are no suppressions or `ignore-unfixed`
exceptions. Investigate a blocked base image and rebuild with updated packages;
do not silently weaken the policy.

`scan-image.py` downloads the official Linux amd64 release archive and verifies
its source-pinned SHA-256 before extracting only the executable. It uses a fresh
advisory cache, empty configuration/ignore files, and removes inherited `TRIVY_*`
overrides. Keep this version/checksum current through a reviewed change; the
scheduled check updates advisory data, not the executable itself.

```bash
python3 -m unittest discover -s deploy/security -p 'test_*.py'
node --test deploy/security/gaxios-uuid.test.cjs
# Linux amd64 runner with Docker; image must carry the exact OCI revision label.
python3 deploy/security/scan-image.py --image "$IMMUTABLE_IMAGE" \
  --commit "$COMMIT" --output security-results/image.json
```

`build-artifact.py` scans before pushing a newly built image, then scans the
exact immutable digest after pulling it. Reused commit tags also receive a fresh
scan. A failed scan cannot produce the release-image output. CI preserves the
receipt and full Trivy JSON, including failures, as workflow artifacts. Images
are built with `--pull` to obtain current Node 24 base-image packages.

For an operator build without a local Docker daemon, commit/push first, then use
the reviewed Cloud Build configuration (no cloud calls occur by reading it):

```bash
gcloud builds submit --no-source --project=nextstop-tech-staging --region=europe-west3 \
  --config=deploy/security/cloudbuild.yaml \
  --substitutions=_COMMIT="$COMMIT"
```

The build checks out that exact commit from the fixed project repository, audits
npm, builds/exports the image, and scans it **before** the first push. After push,
a separate Docker inspection binds the passing scan's configuration digest and
OCI revision to the actual repository digest. The final compact JSON receipt is
written to Cloud Logging, with no credentials. Root/operator must capture that
receipt and Cloud Build's `results.images`, then independently verify the
registry manifest/configuration and exact commit before accepting the image.
A pre-push receipt has `image: null` and is **not** a completed release receipt.
The full Trivy report lives in `/workspace/security-results/image.trivy.json`
during the build; blocking findings are also included in the logged receipt.
No extra logging bucket is created (`CLOUD_LOGGING_ONLY`).

A scan is evidence for one exact image at its recorded time. It does not make an
old image permanently safe; re-run the gate when selecting an existing image.
No deployment, IAM change or vulnerability exception is authorized by these
scripts themselves.

## Narrow dependency repair

Storage 8.2.0 uses gaxios 6.7.1, whose sole UUID operation is CommonJS `v4()` for
multipart boundaries. A scoped npm override upgrades its UUID 9.0.1 dependency to
11.1.1, the patched CommonJS line; it does not downgrade gaxios or force a new
Storage major. The executable transport regression exercises the actual gaxios
multipart preparation without network access. Remove the override when upstream
ships a compatible repaired dependency. The development-only brace-expansion
package is updated to 5.0.12 by the existing semver range.

Sources: [UUID advisory and patched versions](https://github.com/uuidjs/uuid/security/advisories/GHSA-w5hq-g745-h8pq),
[official Trivy release](https://github.com/aquasecurity/trivy/releases/tag/v0.75.0),
[Trivy JSON report schema](https://github.com/aquasecurity/trivy/blob/v0.75.0/pkg/types/report.go),
[Trivy vulnerability filtering](https://trivy.dev/docs/dev/configuration/filtering/).
