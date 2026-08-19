# webhook-ingest

A Go service that receives call-completion webhooks from a telephony provider, persists them in PostgreSQL, updates per-account call statistics, and processes associated recordings.

The original service had several production issues around duplicate deliveries, concurrent access to in-memory state, request cancellation, and error visibility. This version fixes those issues and makes webhook ingestion idempotent.

## What was fixed

### 1. Idempotent webhook ingestion

The provider delivers webhooks **at least once**, so the same `event_id` can be delivered multiple times.

The original implementation could insert the same event more than once, causing duplicate records and incorrect account statistics.

The fix uses PostgreSQL as the source of truth:

* Added a `UNIQUE` constraint on `events.event_id`.
* Inserted events using `INSERT ... ON CONFLICT DO NOTHING`.
* Duplicate deliveries are therefore ignored at the database boundary.
* Statistics are updated only for newly accepted events.

This makes the ingestion path safe against both provider retries and duplicate deliveries after a successful `200` response.

### 2. Fixed concurrent access to in-memory statistics

The in-memory statistics cache was not safe for concurrent access.

Multiple webhook requests can be processed simultaneously, which could result in concurrent map access and inconsistent state.

The statistics cache was updated to use mutex protection around shared state, making concurrent updates safe.

A concurrent test was also added to exercise duplicate delivery under concurrent requests.

### 3. Fixed background processing being cancelled with the HTTP request

The webhook handler starts additional processing after accepting the webhook.

The original implementation used the incoming HTTP request context for work that needed to continue after the request completed. When the request ended, its context could be cancelled, causing in-flight processing to disappear during normal request completion or deployment.

The background processing path now uses `context.Background()` instead of the request-scoped context.

This allows processing to continue independently of the HTTP request lifecycle.

### 4. Improved error visibility

Failures during background processing were not sufficiently visible in the logs.

Errors are now explicitly logged so that processing failures can be diagnosed instead of silently disappearing.

### 5. Added regression coverage

Tests were added for the concurrency/idempotency behavior, including:

* Duplicate webhook delivery
* Concurrent duplicate delivery
* Correct statistics after duplicate events
* Processing behavior after the HTTP request lifecycle ends

The goal is to ensure the production symptoms are reproduced by tests and remain fixed.

---

## Idempotency

The webhook provider guarantees only **at-least-once delivery**, so the application must assume that an event may arrive multiple times.

The stable `event_id` supplied by the provider is used as the idempotency key.

The database enforces uniqueness:

```sql
UNIQUE(event_id)
```

and ingestion uses:

```sql
INSERT ... ON CONFLICT DO NOTHING
```

This makes PostgreSQL the final authority for whether an event has already been accepted.

### Why PostgreSQL?

Redis was available in the environment, but PostgreSQL is already the durable store for webhook events.

Using the database for deduplication means:

* The deduplication state survives service restarts.
* It does not depend on Redis availability.
* The uniqueness guarantee is enforced atomically by the database.
* There is no separate TTL or cleanup policy for deduplication keys.
* Duplicate events cannot create additional durable event records.

Redis remains available for caching and other workloads, but it is not required for correctness of webhook deduplication.

For the current workload, this provides a simple and durable correctness guarantee.

---

## Running the service

Start PostgreSQL, Redis, and the service with Docker Compose:

```bash
docker compose up -d --build
```

Check the health endpoint:

```bash
curl localhost:8080/healthz
```

Expected response:

```text
ok
```

Run the test suite:

```bash
go test ./...
```

### Resetting the environment

To completely tear down the environment, remove the volumes, and start fresh:

```bash
make reset
```

### Local PostgreSQL or Redis

If PostgreSQL or Redis is already running locally, copy the example environment file:

```bash
cp .env.example .env
```

Then configure the ports and connection addresses as required.

The relevant settings include:

```text
APP_PORT
POSTGRES_PORT
REDIS_PORT
DATABASE_URL
REDIS_ADDR
```

Tests use the PostgreSQL instance started by Docker Compose unless the environment is configured otherwise.

---

## API

### POST `/webhooks/calls`

Accepts a call-completion webhook.

Example request:

```json
{
  "event_id": "evt_01H8XK2M9P",
  "call_id": "call_9f2ab31c",
  "account_id": "acc_123",
  "status": "completed",
  "duration_sec": 143,
  "recording_url": "https://recordings.example.com/9f2ab31c.wav",
  "occurred_at": "2026-08-13T09:12:00Z"
}
```

Supported `status` values:

* `completed`
* `failed`
* `no_answer`

The `event_id` must remain stable across provider redeliveries.

### GET `/accounts/{account_id}/stats`

Returns the current per-account call statistics.

The service maintains an in-memory aggregate while the durable copy is stored in PostgreSQL in the `account_stats` table.

### GET `/healthz`

Health/liveness endpoint.

Example:

```bash
curl localhost:8080/healthz
```

Response:

```text
ok
```

---

## Project structure

```text
cmd/server/
    Entrypoint and application wiring

internal/config/
    Environment and application configuration

internal/store/
    PostgreSQL repository and persistence logic

internal/stats/
    In-memory per-account statistics

internal/ingest/
    Webhook ingestion and processing logic

internal/httpapi/
    HTTP routes and request handlers

internal/redisclient/
    Redis connection and client setup

internal/testutil/
    Shared test setup and utilities

migrations/
    PostgreSQL schema migrations
```

---

## Database migrations

Database migrations are stored in:

```text
migrations/
```

The initial schema is applied when PostgreSQL starts with an empty volume.

The idempotency fix adds a migration for the unique event ID constraint:

```text
002_unique_event_id.sql
```

Additional schema changes should follow the existing migration naming convention:

```text
003_*.sql
004_*.sql
...
```

When testing schema changes from a clean database, use:

```bash
make reset
```

---

## Design decisions

### Database-backed idempotency

The database was chosen as the source of truth for deduplication because the event itself is already persisted there.

The unique constraint provides an atomic guarantee that two concurrent deliveries of the same `event_id` cannot both become accepted events.

### Thread-safe statistics

The in-memory statistics cache is protected with synchronization because webhook handlers can execute concurrently.

This prevents concurrent requests from corrupting shared map state or producing unsafe updates.

### Request-independent processing

Work that must continue after the webhook request has been acknowledged does not use the request-scoped context.

This prevents normal HTTP request cancellation from unintentionally terminating background processing.

---

## Testing

Run all tests with:

```bash
go test ./...
```

For verbose output:

```bash
go test ./... -v
```

The test suite includes regression coverage for the production issues identified during the investigation, including concurrent duplicate webhook delivery.

For race detection, the service can also be tested with:

```bash
go test -race ./...
```

---

## Original production symptoms

The original service exhibited four major symptoms:

* Duplicate call records appeared in the dashboard.
* Account call counts drifted higher than the actual number of calls.
* Recordings could fail to become processed without useful log output.
* Work that was in flight could disappear during deployment.

The fixes in this repository address these issues through database-level idempotency, thread-safe in-memory state, request-independent background processing, and explicit error logging.

---

## Solution details

A more detailed explanation of the investigation, the defects that were found, the idempotency decision, and considerations for scaling the service is available in:

**[SOLUTION.md](SOLUTION.md)**

That document contains the reasoning behind the implementation rather than duplicating all of the implementation details here.

---

## Requirements

* Go
* Docker
* Docker Compose
* PostgreSQL
* Redis

The recommended setup is to run PostgreSQL, Redis, and the application through Docker Compose.

---

## Quick start

```bash
# Start the full stack
docker compose up -d --build

# Verify the service
curl localhost:8080/healthz

# Run tests
go test ./...

# Run tests with race detection
go test -race ./...
```

The service entrypoint remains:

```text
./cmd/server
```

and the existing Docker build configuration is preserved.
