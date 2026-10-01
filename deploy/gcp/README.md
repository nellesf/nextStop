# Environment infrastructure and release control

Status on 2026-10-01: the owner approved the smaller two-VM implementation.
Production remains on its existing VM/database in `nextstop-tech-staging` at
`api.nextstop.tech`. New staging provisioning and DNS/TLS, backup, CI identity and
release-gate activation are pending verification. Committed environment JSON
records the selected target; it does not prove those operations have completed.
Release workflows stay disabled until the activation checks below pass.

See [ADR 0018](../../docs/adr/0018-staging-production-releases.md), the
[release runner](../gcp-vm/README.md), and
[iOS development](../../docs/development.md).

## Selected topology and budget

| Environment | Project | VM / zone | Database | API |
| --- | --- | --- | --- | --- |
| Production | `nextstop-tech-staging` | `nextstop-backend` / `europe-west3-a` | Existing local PostGIS | `api.nextstop.tech` |
| Staging | `nextstop-tech-testing` | `nextstop-backend` / `europe-west3-a` | Independent local PostGIS | `api-staging.nextstop.tech` |

Each environment uses one `e2-standard-2` VM with a 30 GiB boot disk and 150 GiB
persistent data/cache disk. API, auth, one ingestion worker and a one-shot
migrator have separate process/database roles on that VM. Nginx terminates TLS
directly. PostgreSQL stays private and SSH uses IAP. Production retains its
existing data, volumes, keys and authentication/withdrawal state; no database move
or production DNS cutover is needed. The project ID `nextstop-tech-staging` is
historical and now identifies production.

The owner selected this scope with a EUR 200/month combined budget. Using the
reported current EUR 72/month as a baseline, two comparable environments plus
backups and an allowance are estimated at EUR 155–175/month on that same tax
basis. Actual traffic, storage and retention affect the bill. Report anticipated
overruns to the owner. Budget alerts must not automatically stop or remove the
service. This scope adds no managed database, load balancer, redundant hosts or
separate worker VM; it has no automatic host/database failover.

The central image repository remains
`europe-west3-docker.pkg.dev/nextstop-tech-staging/nextstop/backend`.
`registryProject` is independent of each environment's compute `project`.
Staging and production use the same verified image digest with separate databases,
credentials, token keys, authentication state, support storage and provider caches.

## Infrastructure activation order

1. Preserve the existing production VM, disk, database, public origin and keys.
   Create `nextstop-tech-testing` on the existing billing account with its own
   network and one VM. Expose HTTPS; permit SSH only through IAP. Do not expose
   PostgreSQL or the API/auth container ports directly.
2. Bootstrap Docker, Python 3 and Nginx, then create independent local PostGIS,
   persistent cache volumes and restricted database roles in staging. Install
   root-only `/etc/nextstop/backend.env` and environment-specific
   `/etc/nextstop/release.env`. Use the appropriate hostname and provision its local TLS certificate.
   Provision `api-staging.nextstop.tech` and its certificate before serving gates.
3. Populate staging from public charging/food sources. Do not copy production
   App Attest records, support reports, deletion proofs, signing keys or other
   private state. Verify useful published projections and authenticated synthetic
   searches before treating staging as ready.
4. Create the dedicated private production backup bucket
   `nextstop-tech-staging-release-backups`. Configure the local PostGIS dump/upload
   gate and bounded object retention. Exclude report payload data from durable
   backups; review recovery against the existing expiry and withdrawal rules.
   Verify an isolated restore before enabling production release DDL.
5. Adopt the existing production service into the parallel-slot release runner
   without recreating its database or persistent volumes. Preserve the legacy
   serving containers until the first candidate and rollback checks pass. Changing
   the environment label is not a data migration.
6. Establish the restricted CI identities and protected environments below.
   Rehearse a staging rollout, continuous synthetic searches during switching,
   failed-candidate recovery and retained-version rollback. Verify production
   App Attest continuity before activating production promotion.
7. Set `NEXTSTOP_RELEASES_ENABLED=true` only after the mapping, TLS, immutable
   registry, backup/restore and release gates have been verified. Record the
   deployed commit/digest and outstanding operational limitations.

Staging can be built and validated before the first production release. A backup
or provisioning failure must stop the candidate operation while the existing
production service remains available.

## GitHub identity and environment gates

The repository is `nellesf/nextStop`, numeric repository ID `1333251411`, numeric
owner ID `26274002`. Use Workload Identity Federation and separate staging and
production deploy service accounts. No service-account JSON key is needed.

Each provider's CEL condition checks the numeric repository and owner IDs,
`assertion.ref == 'refs/heads/main'`, the exact workflow file/ref, and the exact
environment subject. The staging workflow is
`nellesf/nextStop/.github/workflows/backend-staging.yml@refs/heads/main`; production
uses `backend-production.yml`. Subjects are respectively
`repo:nellesf/nextStop:environment:staging` and
`repo:nellesf/nextStop:environment:production`. Do not give a repository-wide
identity access to production without those workflow/environment restrictions.

The dedicated `nextstop` Artifact Registry repository in the existing
`nextstop-tech-staging` project must enforce immutable tags. The staging builder
may write it; deployers and runtime hosts may read it. Keep the unrelated
`cost-dashboard` repository and IAM unchanged. Staging deployment identity targets
only `nextstop-tech-testing`; production deployment identity targets only the
existing production VM. Grant OS Admin Login on each exact VM and IAP tunnel
access on that VM with `destination.port == 22`. The project-level custom role
`nextstopCiProjectMetadata` contains only `compute.projects.get`; instance reads
are covered by the VM-scoped OS Login role. No VM service account or
`roles/iam.serviceAccountUser` grant is needed.

On the dedicated production backup bucket only, grant the production deployer
`roles/storage.objectCreator`, `roles/storage.objectViewer`, and the custom role
`nextstopCiBackupMetadata` containing only `storage.buckets.get`. The metadata
permission lets `backup.py` verify uniform access and public-access prevention
before creating a backup. These roles allow no object deletion or overwrite and
no bucket configuration changes. The CI deployer has no project-wide storage
role or automatic restore permission. `configure-ci.py --apply` prepares these
exact grants and verifies their readback; execute it only after explicit owner
approval of the IAM and GitHub protection changes.

Create GitHub `staging` and `production` environments restricted to `main`.
Production requires owner review. Set these environment variables only after
verifying their values against the created resources:

- `NEXTSTOP_WORKLOAD_IDENTITY_PROVIDER`: full environment-specific provider path.
- `NEXTSTOP_DEPLOY_SERVICE_ACCOUNT`: that environment's deploy service account.
- `NEXTSTOP_BUILD_SERVICE_ACCOUNT`: staging only, central repository writer.

The repository variable `NEXTSTOP_RELEASES_ENABLED` stays absent/false until
deployment activation. Trusted main commits can build their immutable image while
deployment is disabled; they do not create successful staging deployment records.
Staging also requires a trusted repository push, successful Backend
checks and main ancestry. Production dispatch runs protected control code from
main. Pull-request code cannot deploy.

## Promotion and backups

Successful main backend checks trigger an image build and, after activation, a staging deployment. Before
building or reusing an image, `build-artifact.py` checks that the repository has
`dockerConfig.immutableTags=true`. Only an exact tag lookup returning HTTP 404
permits a build; permission, throttling and service failures abort. It verifies
the checked-out SHA, then pulls the selected immutable digest and checks its OCI
revision label. A rerun reuses that digest. Only the verified image reference is
written to the workflow output.

GitHub deployment records bind the actual application commit and digest using
task `nextstop-release`; automatic environment records alone cannot authorize
promotion. Dispatch **Backend production promotion** from main with the complete
staged commit and `repository@sha256:digest`. The workflow verifies main ancestry,
the registry's commit-to-digest mapping, and the latest matching staging
deployment's successful status and digest. It does not rebuild the application.

Before production DDL, `backup.py` must obtain a consistent dump from the existing
local database, upload it to the private GCS bucket, and verify the uploaded
object. The receipt identifies production project, VM/database, immutable object
generation, image and completion time. The host migrator rejects an expired or
mismatched receipt. This requirement is a release backup gate, not a claim of
continuous point-in-time recovery. Dump contents and retention must preserve the
report policy: submitted report payloads are excluded, and recovery must not
restore withdrawn content. Never restore a database automatically during an
application rollback.

The candidate API and auth start beside the serving slot, pass private readiness
and authenticated synthetic searches, then receive traffic through a graceful
Nginx reload. The previous slot remains available for rollback. Only after serving
checks and request drain does the singleton worker change. Expand-only schema
migration, bounded lock waits and database ownership guards protect that sequence;
they do not isolate production imports from the VM's finite CPU, memory and I/O.

Local deterministic verification:

```bash
python3 -m unittest discover -s deploy/gcp -p 'test_*.py'
python3 -m unittest discover -s deploy/releases -p 'test_*.py'
```

These tests use mocked cloud/host commands. They do not replace an actual staging
rollout, continuous-search check, App Attest continuity check or isolated backup
restoration. Record those outcomes before enabling production promotion.
