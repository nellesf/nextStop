# ADR 0015: App Attest authentication for candidate search

- Status: Accepted
- Date: 2026-08-21

## Context

The private staging search originally used one revocable bearer credential that
was embedded in each test build. That credential limited casual abuse but could
be extracted from the app. Rotating it also required rebuilding and distributing
the iOS app. Public distribution needs proof that search requests originate from
an authentic nextStop installation without introducing accounts, tracking, or a
long-lived shared secret in the app.

Apple App Attest is unavailable in the iOS Simulator. Local UI and route testing
must remain possible without copying a long-lived credential into Xcode or
weakening distributed builds.

## Decision

Use Apple App Attest on supported physical devices. The app creates one
installation-scoped App Attest key, obtains a unique single-use backend challenge,
and sends an attestation for the first exchange. Later exchanges use assertions
from the same key. The backend validates the Apple certificate chain, nonce, full
App ID, environment, key identity, assertion signature, and strictly increasing
counter before issuing a 15-minute search access token.

The app stores the App Attest key identifier, lifecycle state, and any transient
pending attestation challenge in a non-synchronizing, device-only Keychain item.
This lets an Apple `serverUnavailable` retry reuse the exact key and client-data
hash; the challenge is removed after Apple returns an attestation. Search access
tokens remain in memory and refresh 60 seconds before expiry. A search that
receives `401` clears the memory token, performs one fresh exchange, and retries
exactly once. It never loops or silently relaxes authentication. The iPhone and
CarPlay scenes receive one shared authentication coordinator from the app
composition root so key creation and assertion counters cannot race in-process.

Backend challenges expire after three minutes, are bound to the hash of the key
identifier and to either attestation or assertion, and are consumed atomically.
The server stores only a hash of the key identifier, the verified public key,
Apple receipt, environment, assertion counter, and coarse lifecycle timestamps.
It does not associate the credential with a profile, route, destination, account,
advertising identifier, or analytics identity.

Candidate search accepts a signed, short-lived server token. Token signing keys
rotate on the server without an app update. During the private staging rollout,
the backend may additionally accept the previous shared bearer only when an
explicit deployment flag enables it for already installed builds. Disable that
compatibility path after the App Attest TestFlight build is verified.

App Attest authentication uses a dedicated database login and pool. It may modify
only App Attest challenge and credential tables. The candidate-search login
remains read-only and cannot access those tables; the worker cannot access them.
The migrator alone owns their schema.

For Simulator development:

- A loopback-only helper authenticates the developer's Mac through Google Cloud
  IAP, invokes a non-HTTP token-minting command in a networkless one-shot container
  that receives only the token signing key, and serves only the resulting
  short-lived development token from `127.0.0.1`.
- A Debug-only provider may request that token when App Attest reports unsupported.
  It contains no staging signing key or long-lived bearer.
- Release builds do not compile the loopback provider and fail closed if App
  Attest is unexpectedly unavailable.
- Development-signed physical builds use the App Attest development environment;
  the backend accepts Apple's current sandbox and legacy development AAGUIDs only
  behind the deployment's explicit development flag. Disabling that flag also
  invalidates assertion exchanges for previously registered development keys.
  TestFlight and App Store builds use production.

The backend uses the exact App ID prefix plus `de.nextstop.app`. The prefix is an
external deployment value and must not be guessed from the Team ID. App Attest
must be enabled for that App ID before the attested path is activated.

## Alternatives

- Continue embedding the shared bearer: rejected because extraction bypasses the
  intended client boundary and rotation requires an app release.
- Put a different permanent secret in Keychain: rejected because it must still be
  shipped or provisioned without proving app integrity.
- Require App Attest in the Simulator: impossible because Apple reports the
  service as unsupported there.
- Put the prior staging bearer in an ignored Xcode file: rejected because every
  Mac needs manual secret synchronization and the app process receives a
  long-lived credential.
- Add accounts or a third-party attestation platform: rejected for the MVP because
  accounts are out of scope and an additional identity/data processor is not
  needed for this boundary.

## Consequences

Initial key attestation requires Apple network availability on a physical device.
Subsequent assertions are local cryptographic operations but still require a
nextStop challenge. Reinstall, restore, or invalid-key responses can legitimately
require one bounded key replacement.

The backend gains a small persistent installation-security record, so the prior
claim of no persistent server-side device credential is amended. It remains a
security credential rather than an account or product identifier and must never
be used for profiling, quotas across reinstallations, or route linkage. Expired
challenges are removed promptly; inactive or revoked key records follow the
documented security-retention window.

Activation requires the exact Apple App ID prefix, refreshed provisioning
profiles, one physical-device development check, and one TestFlight production
check. The Simulator validates only the explicitly isolated Debug loopback flow;
the developer must have authorized Google Cloud/IAP access, but never handles the
token value directly.
