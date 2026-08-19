# SOLUTION.md – Webhook Ingestion Fixes

## What was broken, and why

### 1. Duplicate events and drifting call counts
- **Root cause:** the `events` table did not enforce uniqueness on `event_id`, and the ingestion flow performed an existence check (`SELECT`) before inserting (`INSERT`).  
- Under concurrent deliveries (which our provider sends during retries), two requests could both see “not exists” and proceed to insert, creating duplicate event rows and double‑counting stats in `account_stats`.

### 2. Recordings never reliably marked processed, and in‑flight work disappeared on deploy
- Recording processing was launched as a goroutine that used the **HTTP request context**.  
- When the request finished or the server shut down, the context was cancelled – meaning the background work was abandoned silently (no retries, no logs).  
- The code also ignored errors from the processing goroutine, making it impossible to tell whether a recording was ever processed.

---

## What was changed

### 1. Make event insertion atomic and idempotent
- Added a new migration (`migrations/002_unique_event_id.sql`) to enforce `UNIQUE` on `events.event_id` at the database level.  
- Reworked `InsertEvent` to use `INSERT ... ON CONFLICT (event_id) DO NOTHING` and return a boolean (`inserted`) indicating whether a row was created.  
- The ingest flow now checks this result: if `inserted` is `false`, the delivery is treated as a duplicate and the handler returns early – preventing double‑counting and duplicate call rows.

### 2. Fixed a cache concurrency bug
- `stats.Cache.Record` now acquires its mutex before updating the in‑memory totals. Previously it mutated the map and counters without locking, which caused races under concurrent requests.

### 3. Make recording processing robust
- The recording‑processing goroutine now uses `context.Background()` so it is not cancelled when the HTTP request finishes.  
- Any error during processing is logged.  
- **Note:** a production system would push this work to a durable queue for guaranteed retries; this change removes the immediate cancellation risk and adds visibility.

---

## Why this deduplication strategy was chosen over alternatives

| Approach | Why it was rejected |
| :--- | :--- |
| **SELECT then INSERT** (application‑side check) | Read‑then‑write races permit duplicates under concurrency – it is **not atomic**. |
| **Redis with TTL** | Moves the source of truth into a volatile cache. It still needs coordination with the DB when updating aggregates, and if Redis restarts or the TTL expires before the provider stops retrying, duplicates can slip through. |
| **Postgres UNIQUE + `ON CONFLICT DO NOTHING`** (chosen) | **Simple, durable, and ACID‑compliant.** It provides a single source of truth, works across multiple instances and restarts, and keeps the code path clean without extra distributed coordination. It is also the natural fit because the data is already stored in Postgres. |

---

## What would change at 10,000 webhooks/second

- **Move long‑running work off the request path** – recording processing and any other heavy tasks would go into a durable queue (e.g., Postgres advisory queue, Redis Streams, or a proper message broker). Workers would acknowledge and retry jobs until success, making deploys safe.
- **Batch or async aggregate updates** – instead of updating `account_stats` on every single webhook, we would batch increments in Redis and flush them periodically, or maintain a write‑optimised staging table and recompute aggregates asynchronously.
- **Scale the database** – provision strong DB resources, tune connection pools, and consider partitioning or sharding `account_stats` to avoid hot‑row contention for popular accounts.
- **Add observability** – expose metrics for processing latency, duplicate rates, and error counts, with structured logging and distributed tracing to spot bottlenecks quickly.
- **Idempotency at scale** – keep the Postgres UNIQUE constraint, but add a **Redis‑side bloom filter** or TTL cache as a cheap first check to reduce DB load; the DB remains the ultimate source of truth.

---

## Notes and follow‑ups

- A new concurrent test (`TestConcurrentDuplicateDeliveryIsIgnored`) was added to reproduce and guard against the race. It fails on the original code and passes with the `ON CONFLICT` fix.
- The recording processing fix removes **immediate cancellation**, but truly durable processing would require a queue/worker architecture – this is called out as the top priority if the service were scaled further.