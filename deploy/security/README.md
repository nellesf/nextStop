# Production security backport

This branch starts at the deployed production commit
`fbd248999625a6171e12986bba477b4e4c4a6ec4`. It preserves the application sources,
the original fifteen migrations and the VM deployment architecture. It does not
include the later Cloud Run, ingestion or availability feature changes.

The repair updates Fastify to 5.12.7, fast-uri to 3.1.9/4.2.3 and the affected
development dependency brace-expansion within its existing range. The runtime
uses the previously reviewed Node 24 Alpine 3.24 base, refreshes its OS packages,
and removes unused global npm/Yarn. Runtime imports, compression and German
locale/time-zone checks execute as the unprivileged application user at build
time. No application behavior is replaced by a security workaround.

Backend CI audits both runtime and complete npm dependencies. Moderate or higher
npm findings block. The pinned Trivy 0.75.0 scanner verifies its download checksum
and scans OS/application packages with current advisory data, no suppressions
and no unfixed-vulnerability exclusion. HIGH/CRITICAL findings, an unsupported
OS, missing package inventory or image identity mismatch block release.

`cloudbuild.yaml` builds one exact pushed commit, scans before publishing, and
binds the report to the published immutable digest. The final receipt and
Cloud Build `results.images` must agree. A local CI image scan alone is not
evidence that the production image has been replaced.

For production, first validate this exact image in isolated private staging
API/auth revisions and preserve the existing public staging traffic. Obtain a
fresh production backup, then use the already installed VM release controller
with `--skip-migrations`. Retain its readiness, synthetic-search, TLS, traffic
switch, worker sequencing and rollback checks. Do not upload the newer main
release tooling: its database-role SQL expects tables absent from this older
production schema. No application migrations or role changes belong to this
backport.

Host and database-container findings are separate from this application-image
gate. A clean backend image does not establish a clean production host or
PostGIS image. Record their current versions and findings independently and do
not suppress unresolved advisories to obtain a passing result.
