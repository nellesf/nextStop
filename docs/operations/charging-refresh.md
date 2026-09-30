# Charging refresh performance and recovery

The search API reads the last published charging version while the worker builds
the next one. A slow or failed build must retain that active version. Provider
refresh timing is not an availability safeguard.

## Build phases

The static writer commits park-power and campus-power construction separately,
before taking the shared charging/food publication lock. Each SQL build has a
five-minute statement budget. Both functions copy only the target version into
temporary working tables, index their join keys, and collect fresh statistics.
This prevents historical-table estimates for a previously unseen version UUID
from selecting repeated scans over the entire imported country dataset.

After both phases commit, a fixed-table, parameterless security-definer function
refreshes the permanent search tables' join/filter statistics with a 60-second
statement budget. Only the worker receives execution permission; it gains TEMP
permission for its own working tables, not schema ownership or general database
administration. The final transaction checks counts, builds matches against the
currently active food version under the shared publication lock, and atomically
switches the active charging version. Food matching remains inside that lock to
preserve charging/food pair consistency. Neither build phase modifies active rows.

`static-projection-stage` logs contain a fixed stage, started/completed state and
elapsed milliseconds. They contain no provider payload, route or credentials.
The worker role also has a five-minute SQL statement deadline; a deadline aborts
the unpublished work and preserves the active version. Inspect the last started
stage without a completion when diagnosing a slow build.

## Avoiding repeated inputs

`PROVIDER_CACHE_DIRECTORY` holds a bounded persistent cache for the current
Bundesnetzagentur CSV and Swiss static response. Cached validators are sent only
with an intact size/hash-verified body. HTTP 304 reuses that body; an invalid,
partial or failed response cannot replace it. An upstream outage is not treated
as a successful refresh from an unchecked stale body. Swiss live responses remain
uncached and keep their existing freshness rules.

The raw-file hash remains the first skip check. If raw files changed, validated
records are fingerprinted independently of their order, JSON object key order,
feed envelope and fetch timestamps. Every source-record payload field, normalized
value, quality/identity field, quarantine issue and record multiplicity still
participates. Equivalent inputs reuse the active version and record the checked
raw dataset hash separately; original projection provenance is not overwritten.
Actual source-record changes still rebuild the combined corpus, preserving
cross-provider EVSE deduplication and geographic clustering.

OSM retains its existing HTTP/PBF cache. Changed country extracts still undergo
full parsing; incremental OSM processing is not introduced by this fix.

## Retaining derived search history

Every two minutes the worker attempts at most eight batches of 250 derived rows.
Each batch uses a two-second SQL deadline, a short lock deadline and a nonblocking
publication-lock attempt. It yields when publication or the database is busy.
It resumes at the saved table stage after interruption.

Keep the active version and the two most recently retired complete versions for
rollback, plus every version retired less than seven days ago. The grace period
starts at retirement, not at publication. Versions already retired at migration
receive a full new grace period because their exact retirement time is unknown.
Explicitly failed versions become eligible after seven days; a merely old
`building` version is never assumed abandoned.

Before deleting any derived rows, mark that version pruned. Its pinned search
tokens then fail explicitly instead of returning a partially deleted result. A
database constraint prevents reactivating a pruned version. Cleanup removes only
charging park/campus search rows, memberships, power projections and their food
match cache. Original version metadata, normalized observations, provider records,
quarantines, conflicts and the OSM corpus remain available for audit. This is not
a retention policy for the underlying source/audit evidence.

## Incident diagnosis and recovery

Read current activity and aggregate search diagnostics first. Distinguish an
active CPU/I/O operation from a lock wait and a stale `building` status. Never
print complete query text, bound parameters, routes or secrets. `/health` checks
process liveness; successful synthetic searches establish search health.

On 2026-09-30 the campus-power SQL ran for more than 13 hours while searches hit
the API's 15-second deadline. A separate diagnostic plan estimated one location
for a newly imported version with 134,579 locations. The location-table change
counter of 403,750 was explained by three full inserts of 134,592, 134,579 and
134,579 locations; its cumulative update and deletion counters were both zero.
These counters describe database work, not changes in the real charging network.

For a stuck build, pause the worker, cancel only the verified long-running worker
operation if it remains after disconnect, and preserve the active version. Apply
bounded statistics maintenance and verify synthetic searches before resuming a
corrected worker. Never truncate active tables or rebuild in place. Apply tested
additive migrations and the matching role initializer together. Any rollback must
select a complete version with `search_pruned_at IS NULL`.

The single-VM staging topology still shares CPU/storage resources. Query fixes,
deadlines and bounded cleanup reduce this incident mechanism; they do not provide
infrastructure failover or a general availability guarantee.
