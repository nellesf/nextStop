# ADR 0021: Separate native Cloud Run endpoints for production and staging

- Status: Accepted
- Date: 2026-11-01
- Amends: [ADR 0018](0018-staging-production-releases.md) and [ADR 0020](0020-cloud-run-cloud-sql-staging.md)

## Decision

The owner selected independent native HTTPS gateways for both environments before public App Store distribution. Each environment uses its own Cloud Run services, Cloud SQL PostgreSQL/PostGIS database, identities, secrets and backup objects in its existing project. Its public gateway owns the stable, untagged service address in Belgium. Private services and candidate revision URLs are restricted to their existing IAM and release paths.

| Environment | Project | Public application origin |
| --- | --- | --- |
| Staging | `nextstop-tech-testing` | `https://nextstop-gateway-353471052580.europe-west1.run.app` |
| Production | `nextstop-tech-staging` | `https://nextstop-gateway-1022346259037.europe-west1.run.app` |

The service name, project number and region determine each origin. Commissioning must confirm it in the actual gateway's `run.googleapis.com/urls`, then verify public readiness, image identity and an authenticated representative search there. Use the existing two-source limiter test on the public path. Native endpoints avoid a separate load balancer, custom-domain mapping and its frontend charge. Cloud Run, Cloud SQL, storage and traffic retain their ordinary costs.

## Client and rollback

New physical-device and archived builds always use the native production gateway. Debug Simulators pair the selected environment with its own loopback broker and IAM-protected token service. App Attest verification, its signing environment, token issuer/audience and the separate signing keys remain intact. The issuer string identifies a token protocol principal and is never fetched.

Production's existing VM retains its TLS endpoint `https://api.nextstop.tech` for a controlled return. DNS cannot move a native Google service hostname to that VM. Once a new client has written to Cloud SQL, stop and fence writers, drain jobs, verify the public corpus and reverse-transfer all current private state, including App Attest counters and report withdrawals, before enabling the VM. Follow the [production handoff](../../deploy/gcp-run/PRODUCTION-PRIVATE-HANDOFF.md). Keep exactly one writable database throughout.

During this internal rollout, retain and validate the previous VM-targeted build for physical test devices. Install it in place with the same signing identity and bundle identifier to preserve their data containers. The Debug Simulator supports explicit VM selection. Disable client access to an inactive native gateway before reopening the VM. Local App Attest keys and report withdrawal receipts retain each environment's original storage namespace across the host change. Production and staging capabilities never share a namespace. Public distribution requires revisiting the client rollback plan because an installed native-targeted build cannot be switched by DNS.
