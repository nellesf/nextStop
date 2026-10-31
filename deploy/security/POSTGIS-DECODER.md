# Restrict the unused FlatGeobuf input functions

PostGIS's `public.st_fromflatgeobuf(anyelement,bytea)` reads binary input into SQL
rows. CVE-2026-73515 affects variable-length input in that decoder. The same
upstream patch also adds bounds checks to the header decoder used by
`public.st_fromflatgeobuftotable(text,text,bytea)` before it creates a table.
The app uses
PostGIS's geography, distance and index functions, and has no FlatGeobuf import
feature. The upstream 3.6.4 release fixed a separate schema mismatch. Treat a
provider backport of the later bounds check as unconfirmed until verified.
[Advisory](https://www.vulncheck.com/advisories/postgis-0beta2-out-of-bounds-read-via-flatgeobuf-buffer),
[stable branch fix](https://github.com/postgis/postgis/commit/767fa40644253281f6d4e8b06811489b0a0f9b0d)
and [upstream release notes](https://github.com/postgis/postgis/blob/3.6.4/NEWS).

## Apply on a verified instance

Use `restrict-postgis-flatbuffer-decoder.sql` as an explicit owner operation.
Pin the target VM system identifier or Cloud SQL project, region, instance and
database using the deployment inventory. Before changing grants, enumerate
connectable databases including templates, check that PostGIS owns that exact
pair of signatures and retain their current ACLs. The VM has the inputs in both `nextstop`
and the connectable `template_postgis`. The managed staging installation has it
only in `nextstop`. Apply and check each database separately. Preserve the
existing provider-managed administrative database boundary.

For the legacy VM use the established local database-container maintenance
connection as `nextstop_app`, feeding the SQL file to
`psql -X --set ON_ERROR_STOP=1`. For a managed instance run it as the PostGIS
owner `postgres` over its normal maintenance connection. An authorized operator
without the owner's password can use the protected Cloud SQL Admin SQL import
with the exact database and `--user=postgres`. Upload only the reviewed SQL
to a unique create-only, private object. Verify its SHA-256 and generation,
grant the instance service agent time-limited `storage.objects.get` on that
single object and inspect the completed import operation. Remove the temporary
binding and object generation, and independently read the live ACLs. The SQL
changes only these two functions' EXECUTE privileges and checks direct, inherited and
SET ROLE access. The owner retains administrative access.
[Cloud SQL import procedure](https://docs.cloud.google.com/sql/docs/postgres/import-export/import-export-sql).

Run `verify-postgis-flatbuffer-decoder.sql` with `psql -X -v ON_ERROR_STOP=1`
as the API role and retain the successful result. It raises an error if an
expected role is absent or can use either decoder. For per-role evidence,
run the following query from an ordinary application connection after every
restore, extension install or upgrade. An extension can recreate the function
with PostgreSQL's default PUBLIC EXECUTE. Reapply the owner restriction before
opening the endpoint if any runtime role has access. A filtered data archive,
application image scan or successful app search does not verify these ACLs.

```sql
SELECT r.rolname, f.oid::regprocedure AS input_function,
       has_function_privilege(r.oid, f.oid, 'EXECUTE') OR EXISTS (
         SELECT FROM pg_roles t WHERE pg_has_role(r.oid,t.oid,'SET')
           AND has_function_privilege(t.oid,f.oid,'EXECUTE')
       ) AS decoder_access
FROM pg_roles r CROSS JOIN pg_proc f
WHERE f.oid IN ('public.st_fromflatgeobuf(anyelement,bytea)'::regprocedure,
                'public.st_fromflatgeobuftotable(text,text,bytea)'::regprocedure)
  AND r.rolname IN ('nextstop_api','nextstop_auth','nextstop_support','nextstop_worker',
                    'nextstop_backup','nextstop_app')
ORDER BY r.rolname, input_function;
```

All runtime roles must return false. The legacy maintenance owner
`nextstop_app` is the VM's PostgreSQL superuser, and its row remains true.
Also run the ordinary authenticated candidate search against the deployed
backend. This mitigation closes application-role access. The underlying
extension binary requires a vendor fix or a verified patched upgrade.
