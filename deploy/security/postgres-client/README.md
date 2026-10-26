# PostgreSQL 17 backup clients

This image contains PostgreSQL 17.11 `pg_dump`, `pg_restore` and `psql` for the
existing PostgreSQL 17 server. It does not upgrade the server, change its locale,
apply migrations or mount its data volume. The fixed runtime user is
`65532:65532`; `/bin/sh` and `/usr/local/bin/{psql,pg_dump,pg_restore}` are available.
The default command prints the psql version. There is no server entrypoint,
exposed port or image-declared volume.

The base is the exact official `postgres:17.11-alpine3.24` Linux amd64 manifest
`sha256:e4cb93687b062cd25a0e8f672d85a7708235009d70d31f8a7698d9370092a9c4`.
Its 2026-10-26 Trivy scan found no Alpine OS-package vulnerabilities; all 61
findings came from the unused `gosu` executable and its embedded Go libraries.
The build removes that executable and the server/init/start programs. A fresh
final image configuration avoids inheriting PostgreSQL's automatic data volume.
The complete Alpine package inventory remains available to the scanner.

PostgreSQL 17.11 fixes the backup-client vulnerabilities
[CVE-2026-19385](https://www.postgresql.org/support/security/CVE-2026-19385/) and
[CVE-2026-18408](https://www.postgresql.org/support/security/CVE-2026-18408/).
The [official Docker metadata](https://github.com/docker-library/official-images/blob/master/library/postgres)
lists the selected Alpine tag. Using a musl-based client does not change the
server's collation. Cloud Build requires a real isolated synthetic dump/restore
before accepting the tools. This checks client/server transfer compatibility;
it does not validate migration of the production database, PostGIS extensions,
production data, ownership, collations or recovery continuity.

## Build and acceptance

Commit and push the reviewed source, then an authorized operator can submit:

```bash
gcloud builds submit --no-source --project=nextstop-tech-staging --region=europe-west3 \
  --config=deploy/security/postgres-client/cloudbuild.yaml \
  --substitutions=_COMMIT="$COMMIT"
```

The build fetches exactly that 40-character commit from the fixed repository.
All three actual binaries must report 17.11 both during the image build and in
a read-only, unprivileged, networkless runtime check. A separate synthetic
roundtrip starts the pinned official PG17.11 fixture as UID/GID 70 without its
entrypoint or `gosu`, with fresh tmpfs data, `network=none` and no host ports.
The new clients join only its loopback namespace, authenticate using stdin and
a private tmpfs `.pgpass`, and dump/restore Unicode, binary, foreign-key and
sequence data. Incorrect credentials must fail; restored content, sequences
and constraints must pass. Archive catalogue validation uses `network=none`.
Containers and synthetic files are removed on success or failure. The new
client image never starts a server and contains no server/init programs.
The shared pinned Trivy 0.75.0 gate then scans the exported image with a fresh
advisory database **before push**. HIGH/CRITICAL findings, including unfixed ones,
block publication. Lower findings remain in the report; there are no suppressions.

The explicit `postgres-client` inventory profile requires Alpine package
inventory and verifies the fixed user, purpose/base/revision labels, harmless
default command and absence of image-declared volumes, ports and entrypoint.
The ordinary backend profile continues to require npm inventory. After push,
the receipt binds the scanned configuration digest and source commit to the
repository digest. Capture that final JSON receipt from Cloud Logging together
with Cloud Build's `results.images`; `image: null` is not an accepted receipt.
The full report is `/workspace/security-results/postgres-client.trivy.json` during
the build. Independently verify the manifest, configuration and source revision.

Production adoption must select that exact accepted digest, use a private
database network, a read-only filesystem, dropped capabilities and
`no-new-privileges`. Pass credentials only through private stdin/tmpfs handling,
never image configuration or command-line arguments. Mount no production data
volume. No Cloud Build submission or production adoption is performed merely by
adding these files; a passing image scan and restore evidence are still pending.

## Prepare the exact private image before backup

After the successful build and independent registry checks, add `image.json`
beside this document with the accepted `image` (this repository plus manifest
digest), `configDigest`, `sourceCommit` (full commit), `version` (`17.11`) and
`platform` (`linux/amd64`). No placeholder file is provided: preparation and
backup fail closed until actual accepted metadata exists.

The protected production workflow invokes `python3
deploy/security/postgres-client/prepare.py` before `backup.py`. Preparation
requires the existing production deploy account and source ancestry on
`origin/main`. It checks the production host identity, logs into the one registry
using an access token passed only through stdin, checks the registry manifest's
configuration digest, pulls the exact image and verifies its complete client
configuration. A temporary root-only Docker configuration under `/run` is owned
and cleaned by the remote process on success or failure; ordinary termination
signals also run cleanup. No token or raw subprocess output is logged. It starts
no container and touches no application, database, roles or deployment state.
The following backup step uses `--pull=never` and rechecks the same metadata.
