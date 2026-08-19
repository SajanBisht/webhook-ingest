-- Ensure event_id is unique so duplicates cannot be inserted concurrently
CREATE UNIQUE INDEX IF NOT EXISTS idx_events_event_id_unique ON events (event_id);
