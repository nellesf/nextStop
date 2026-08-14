# Bundesnetzagentur import runbook

Status: implemented and locally verified on 2026-08-14.

## Source and license

Use only a file linked by the official
[Bundesnetzagentur Ladesäulenkarte](https://www.bundesnetzagentur.de/DE/Fachthemen/ElektrizitaetundGas/E-Mobilitaet/Ladesaeulenkarte/start.html).
The page publishes the register under CC BY 4.0 and specifies the attribution
`bundesnetzagentur.de`. Keep that attribution in product/legal surfaces that use
the data.

The verified initial file is `Ladesaeulenregister_BNetzA_2026-07-07.csv` with:

```text
sha256 dbc3a36f48b23759778addb5f7ef2a922e81a3924cca285a78838ecce99fdcc6
size   53114117 bytes
```

Provider files are operational inputs, not source artifacts. Keep them outside
the repository; `backend/data/` is ignored as a defensive backstop.

## Preconditions

- PostgreSQL 17 with PostGIS installed and reachable.
- A migrator-capable `DATABASE_URL` for migration, then a worker write role for
  import in managed environments.
- The source URL, displayed dataset date, byte size, and SHA-256 independently
  checked against the official page before import.
- At least the currently active projection retained until the new one publishes.

## Migrate

```bash
cd backend
DATABASE_URL=postgresql://127.0.0.1/nextstop npm run db:migrate
```

## Import and publish

```bash
cd backend
DATABASE_URL=postgresql://127.0.0.1/nextstop \
BUNDESNETZAGENTUR_CSV_PATH=/absolute/path/Ladesaeulenregister_BNetzA_2026-07-07.csv \
BUNDESNETZAGENTUR_DATASET_OBSERVED_AT=2026-07-07T00:00:00.000Z \
BUNDESNETZAGENTUR_EXPECTED_SHA256=dbc3a36f48b23759778addb5f7ef2a922e81a3924cca285a78838ecce99fdcc6 \
npm run import:bnetza
```

The job refuses a hash mismatch, validates the exact 47-column schema, enforces a
100 MiB input limit and 64 KiB record limit, quarantines invalid records, writes
raw and normalized observations in bounded batches, and builds the projection
under a new UUID. It publishes only after stored row counts match validated
counts and at least one park exists.

Publication takes an advisory transaction lock, retires the prior active version,
and activates the new one in the same transaction. API readers therefore see
either the complete prior version or the complete new version. Failed builds are
marked `failed` and never replace the active projection.

## Expected initial shadow counts

```text
locations           113384
EVSE observations   204076
charging parks       48256
quarantined rows         1
identity conflicts     170
```

Treat count changes as a review signal, not a hard eternal invariant: first check
the official schema/date, provider notes, quarantine distribution, implausible
jumps, and a representative route search. Never change the EVSE mapping or
clustering thresholds merely to reproduce historical counts.

## Rollback

Do not delete the new projection during incident diagnosis. In one database
transaction under the same publication advisory lock, retire the bad active
version and reactivate the most recent known-good retained version. Record the
incident and failure reason. Route requests are never stored, so no route-data
rollback or cleanup is involved.
