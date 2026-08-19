What was broken, and why

1) Duplicate events and drifting call counts:
- Root cause: the events table did not enforce uniqueness on event_id and the ingestion flow first checked for existence then performed an INSERT. This created a race: two near-simultaneous deliveries could both see "not exists" and both insert, producing duplicate event rows and double-counting in account_stats.

2) Recordings never reliably marked processed and in-flight work lost on deploy:
- Root cause: recording processing was launched as a goroutine using the request context. The request context may be cancelled after the HTTP response or when the server shuts down, so background work could be abandoned without logs or retries. The code also ignored errors from the processing goroutine.

What was changed

1) Make event insertion atomic and idempotent
- Added a new migration (migrations/002_unique_event_id.sql) to enforce uniqueness on events.event_id at the database level.
- Reworked InsertEvent to use INSERT ... ON CONFLICT (event_id) DO NOTHING and return a boolean (inserted) indicating whether a row was created. This is atomic and avoids a read-then-write race.
- The ingest flow now relies on InsertEvent's result: if the insert did not create a row, the delivery is treated as a duplicate and the handler returns early, avoiding double-counting and duplicate call rows.

2) Fixed cache concurrency bug
- stats.Cache.Record now acquires the mutex when updating the in-memory totals (previously it mutated the map and counters without locking), preventing races under concurrent requests.

3) Make recording processing more robust
- The recording-processing goroutine now uses context.Background() (so it is not cancelled with the HTTP request) and any error during processing is logged. This prevents work from being accidentally cancelled when the request finishes; a production-ready system would push such work to a durable queue for retries.

Why this deduplication strategy was chosen

Options considered:
- Rely exclusively on application-level existence checks (SELECT then INSERT). Rejected: read-then-write races permit duplicates under concurrency.
- Use Redis to track delivered event_ids with an expiry. This is workable but moves the durability/truth into Redis and still requires coordination with the DB when updating durable aggregates.
- Use a database-side uniqueness constraint and an atomic INSERT with ON CONFLICT DO NOTHING. Chosen: it is simple, durable, single-source-of-truth, and forces correct behavior even if the application is concurrently running in multiple processes or after restarts. Also it keeps the code path simple and avoids extra distributed coordination.

What would change at 10,000 webhooks/sec

- Move recording processing and any other long-running work off the web request path into a durable work queue (e.g., Postgres advisory queue, Redis Streams, or a message broker). Workers would ack and retry jobs until successful, providing durability across deploys.
- Use batched or incremental updates to account aggregates when possible, or maintain a write-optimized table and compute aggregates asynchronously to reduce contention on account_stats for hot accounts.
- Provision strong DB resources and connection pools; consider sharding or partitioning account_stats if single-row hot spots appear.
- Add metrics and observability (histograms for processing time, counters for duplicates and errors) and structured retry/backoff policies for transient failures.

Notes and follow-ups

- I added a test (TestConcurrentDuplicateDeliveryIsIgnored) that posts the same event concurrently to demonstrate and guard against the race. It would fail against the original code and pass with the database uniqueness + ON CONFLICT approach.
- The overall durability of recording processing still needs work: the current change makes the goroutine less likely to be cancelled immediately, but durable, restart-proof processing requires a queue/worker design.

