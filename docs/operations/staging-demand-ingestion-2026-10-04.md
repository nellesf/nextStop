# Staging demand-driven ingestion, 2026-10-04

## Scope and cost baseline

The owner authorized staging only and supplied approximately **EUR 70/month**
as the comparison ceiling. The tax basis, credits and exact invoice period were
not supplied. Production and TestFlight remain on their existing configuration.

The initial implementation removes idle Swiss live polling and changes static
charging/OSM imports to monthly runs. It reuses the existing VM, database, disks,
cache, IP and TLS proxy. It does **not** implement scale-to-zero hosting or claim
a reduction in the fixed VM bill. A later hosting migration needs a measured
workload, a separate cost comparison and the required provider access.

Read-only inventory at approximately 05:48 UTC on 2026-10-04:

| Item | Existing staging allocation or measurement |
| --- | --- |
| Project / VM | `nextstop-tech-testing` / `nextstop-backend`, `europe-west3-a` |
| Compute | One running `e2-standard-2`: 2 vCPU, 8 GiB RAM |
| Persistent disks | 30 GiB boot + 150 GiB balanced data disk |
| Network | One reserved external IPv4; no load balancer, NAT or router |
| Other paid infrastructure | No snapshots, reservations, commitments or buckets found in this project |
| Database size | 24,463,199,379 bytes (22.78 GiB) |
| Existing OSM/provider caches | 948,291,609 bytes combined (0.883 GiB) |

Cache size is an observation, not a peak-storage guarantee. Downloads can retain
old and new copies, and the configured per-source download bound is larger.

The current public EUR list-price estimate for the existing VM and disks is
approximately EUR 74.47 per 730-hour month, before IP/usage, discounts, credits
and tax. It is **not an actual billed amount** and does not replace the owner's
EUR 70 baseline. An accessible Billing export was not found. The existing local
cost dashboard omits `nextstop-tech-testing` and estimates inventory prices;
it cannot establish billed costs for this change.

No extra always-on allocation is required by this implementation. Holding the
allocation constant keeps its fixed infrastructure charge unchanged. Usage,
artifact storage and one-time release activity still require a later billing
comparison; an invoice-level non-increase cannot be certified in advance.
Budget alerts must not automatically stop or delete service resources.

## Activation and recovery

Use [ADR 0019](../adr/0019-demand-driven-staging-ingestion.md) and the existing
immutable-image release runner. Build off the serving VM, and require successful
backend/PostGIS CI for the exact branch commit before deployment. Do not weaken
main-only production or CI federation rules to stage an experiment.

On the verified staging host, install and run
`deploy/releases/configure-staging-ingestion.py --enable` with the existing
root-only host and private environment files. The helper checks both staging
identity and hostname before writing. It creates a dedicated private signal
credential without printing it. Then deploy the tested digest through
`deploy/gcp-vm/deploy.sh --environment staging --image <registry@sha256:digest>`.

The helper changes configuration only; activation occurs with the gated release.
Port 8091 stays inside the Docker network. Additive migrations preserve old
application readers/writers. Existing search readiness, authenticated synthetic
search, proxy-switch and retained-slot rollback gates continue to apply.

To restore the previous schedule, run the helper with `--disable`, then deploy
the selected tested digest through the same gates. A prior image ignores the
new opt-in flags. Never reverse the additive migrations during rollback.

## Verification record

Implementation is prepared; live activation and exact-artifact CI are pending.
Record the commit/digest and outcomes here before treating staging as complete:

- Exact branch CI: backend unit tests, migration manifest, real PostGIS integration,
  release runner tests, Swift Core and iOS/CarPlay tests.
- API/worker active digest, authenticated static searches and read-only API grants.
- Persisted next monthly due dates without an activation-time corpus rebuild.
- No live refresh while idle or for a German-only selection.
- Concurrent Swiss demand shares one refresh; the response does not wait for download.
- Stale/unavailable live information remains unknown and cannot remove search results.
- Infrastructure allocation unchanged and production unaffected.

The local iOS test attempt triggered repeated Simulator `PosterBoard` crashes.
The affected simulator, test/diagnostic processes and queued crash reporter were
stopped. Further checks use compilation without booting a local simulator,
platform-neutral tests, and hosted iOS CI. No global crash reporting setting was
disabled.
