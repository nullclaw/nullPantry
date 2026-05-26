pub const sqlite_schema =
    \\PRAGMA journal_mode = WAL;
    \\PRAGMA foreign_keys = ON;
    \\CREATE TABLE IF NOT EXISTS schema_migrations (
    \\  version INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL,
    \\  applied_at_ms INTEGER NOT NULL
    \\);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (1, 'core_primitives', strftime('%s','now') * 1000);
    \\CREATE TABLE IF NOT EXISTS sources (
    \\  id TEXT PRIMARY KEY,
    \\  type TEXT NOT NULL,
    \\  title TEXT NOT NULL,
    \\  raw_content_uri TEXT,
    \\  content TEXT NOT NULL DEFAULT '',
    \\  author TEXT,
    \\  participants_json TEXT NOT NULL DEFAULT '[]',
    \\  permissions_json TEXT NOT NULL DEFAULT '[]',
    \\  scope TEXT NOT NULL DEFAULT 'workspace',
    \\  created_at_ms INTEGER NOT NULL,
    \\  imported_at_ms INTEGER NOT NULL,
    \\  checksum TEXT,
    \\  language TEXT,
    \\  related_entities_json TEXT NOT NULL DEFAULT '[]',
    \\  metadata_json TEXT NOT NULL DEFAULT '{}'
    \\);
    \\CREATE VIRTUAL TABLE IF NOT EXISTS sources_fts USING fts5(id UNINDEXED, title, content);
    \\CREATE TABLE IF NOT EXISTS artifacts (
    \\  id TEXT PRIMARY KEY,
    \\  type TEXT NOT NULL,
    \\  title TEXT NOT NULL,
    \\  body TEXT NOT NULL,
    \\  status TEXT NOT NULL DEFAULT 'draft',
    \\  owner TEXT,
    \\  space_id TEXT,
    \\  version INTEGER NOT NULL DEFAULT 1,
    \\  created_at_ms INTEGER NOT NULL,
    \\  updated_at_ms INTEGER NOT NULL,
    \\  last_verified_at_ms INTEGER,
    \\  source_ids_json TEXT NOT NULL DEFAULT '[]',
    \\  related_entities_json TEXT NOT NULL DEFAULT '[]',
    \\  permissions_json TEXT NOT NULL DEFAULT '[]',
    \\  summary TEXT,
    \\  agent_summary TEXT
    \\);
    \\CREATE VIRTUAL TABLE IF NOT EXISTS artifacts_fts USING fts5(id UNINDEXED, title, body);
    \\CREATE TABLE IF NOT EXISTS entities (
    \\  id TEXT PRIMARY KEY,
    \\  type TEXT NOT NULL,
    \\  name TEXT NOT NULL,
    \\  aliases_json TEXT NOT NULL DEFAULT '[]',
    \\  description TEXT,
    \\  canonical_artifact_id TEXT,
    \\  metadata_json TEXT NOT NULL DEFAULT '{}',
    \\  created_at_ms INTEGER NOT NULL,
    \\  updated_at_ms INTEGER NOT NULL
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_entities_type_name ON entities(type, lower(name));
    \\CREATE TABLE IF NOT EXISTS memory_atoms (
    \\  id TEXT PRIMARY KEY,
    \\  subject_entity_id TEXT,
    \\  predicate TEXT NOT NULL DEFAULT 'states',
    \\  object TEXT NOT NULL DEFAULT '',
    \\  text TEXT NOT NULL,
    \\  scope TEXT NOT NULL DEFAULT 'workspace',
    \\  confidence REAL NOT NULL DEFAULT 0.5,
    \\  status TEXT NOT NULL DEFAULT 'proposed',
    \\  source_ids_json TEXT NOT NULL DEFAULT '[]',
    \\  evidence_ranges_json TEXT NOT NULL DEFAULT '[]',
    \\  created_by TEXT NOT NULL DEFAULT 'human',
    \\  created_at_ms INTEGER NOT NULL,
    \\  valid_from_ms INTEGER,
    \\  valid_until_ms INTEGER,
    \\  last_verified_at_ms INTEGER,
    \\  owner TEXT,
    \\  permissions_json TEXT NOT NULL DEFAULT '[]',
    \\  tags_json TEXT NOT NULL DEFAULT '[]'
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_memory_atoms_scope_status ON memory_atoms(scope, status);
    \\CREATE VIRTUAL TABLE IF NOT EXISTS memory_atoms_fts USING fts5(id UNINDEXED, text, predicate, object);
    \\CREATE TABLE IF NOT EXISTS vector_chunks (
    \\  id TEXT PRIMARY KEY,
    \\  object_type TEXT NOT NULL,
    \\  object_id TEXT NOT NULL,
    \\  chunk_ordinal INTEGER NOT NULL DEFAULT 0,
    \\  text TEXT NOT NULL DEFAULT '',
    \\  scope TEXT NOT NULL DEFAULT 'workspace',
    \\  permissions_json TEXT NOT NULL DEFAULT '[]',
    \\  embedding_json TEXT NOT NULL,
    \\  model TEXT,
    \\  dimensions INTEGER NOT NULL,
    \\  created_at_ms INTEGER NOT NULL,
    \\  updated_at_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_vector_chunks_object ON vector_chunks(object_type, object_id);
    \\CREATE INDEX IF NOT EXISTS idx_vector_chunks_scope ON vector_chunks(scope);
    \\CREATE TABLE IF NOT EXISTS vector_outbox (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  action TEXT NOT NULL,
    \\  object_type TEXT NOT NULL,
    \\  object_id TEXT NOT NULL,
    \\  status TEXT NOT NULL DEFAULT 'pending',
    \\  attempts INTEGER NOT NULL DEFAULT 0,
    \\  payload_json TEXT NOT NULL DEFAULT '{}',
    \\  created_at_ms INTEGER NOT NULL,
    \\  updated_at_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_vector_outbox_status ON vector_outbox(status, id);
    \\CREATE TABLE IF NOT EXISTS relations (
    \\  id TEXT PRIMARY KEY,
    \\  from_entity_id TEXT NOT NULL,
    \\  relation_type TEXT NOT NULL,
    \\  to_entity_id TEXT NOT NULL,
    \\  source_ids_json TEXT NOT NULL DEFAULT '[]',
    \\  confidence REAL NOT NULL DEFAULT 0.5,
    \\  status TEXT NOT NULL DEFAULT 'proposed',
    \\  created_at_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_relations_from ON relations(from_entity_id);
    \\CREATE INDEX IF NOT EXISTS idx_relations_to ON relations(to_entity_id);
    \\CREATE TABLE IF NOT EXISTS context_packs (
    \\  id TEXT PRIMARY KEY,
    \\  purpose TEXT NOT NULL,
    \\  target TEXT NOT NULL,
    \\  query_text TEXT NOT NULL,
    \\  included_sources_json TEXT NOT NULL DEFAULT '[]',
    \\  included_artifacts_json TEXT NOT NULL DEFAULT '[]',
    \\  included_memory_atoms_json TEXT NOT NULL DEFAULT '[]',
    \\  generated_summary TEXT NOT NULL,
    \\  token_budget INTEGER NOT NULL DEFAULT 12000,
    \\  created_at_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS compat_memories (
    \\  key TEXT NOT NULL,
    \\  session_id TEXT,
    \\  memory_atom_id TEXT NOT NULL,
    \\  category TEXT NOT NULL DEFAULT 'core',
    \\  timestamp_ms INTEGER NOT NULL
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_compat_memories_key_session ON compat_memories(key, coalesce(session_id, ''));
    \\CREATE TABLE IF NOT EXISTS session_messages (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  session_id TEXT NOT NULL,
    \\  role TEXT NOT NULL,
    \\  content TEXT NOT NULL,
    \\  created_at_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_session_messages_session ON session_messages(session_id, id);
    \\CREATE TABLE IF NOT EXISTS session_usage (
    \\  session_id TEXT PRIMARY KEY,
    \\  total_tokens INTEGER NOT NULL DEFAULT 0,
    \\  updated_at_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS audit_events (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  event_type TEXT NOT NULL,
    \\  actor TEXT,
    \\  object_type TEXT NOT NULL,
    \\  object_id TEXT NOT NULL,
    \\  payload_json TEXT NOT NULL DEFAULT '{}',
    \\  created_at_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS memory_feed_events (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  event_type TEXT NOT NULL,
    \\  object_type TEXT NOT NULL,
    \\  object_id TEXT NOT NULL,
    \\  scope TEXT NOT NULL DEFAULT 'workspace',
    \\  dedupe_key TEXT,
    \\  payload_json TEXT NOT NULL DEFAULT '{}',
    \\  status TEXT NOT NULL DEFAULT 'pending',
    \\  created_at_ms INTEGER NOT NULL,
    \\  applied_at_ms INTEGER
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_memory_feed_events_scope_id ON memory_feed_events(scope, id);
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_feed_events_dedupe_key ON memory_feed_events(dedupe_key) WHERE dedupe_key IS NOT NULL;
    \\CREATE TABLE IF NOT EXISTS response_cache (
    \\  cache_key TEXT PRIMARY KEY,
    \\  value_json TEXT NOT NULL,
    \\  created_at_ms INTEGER NOT NULL,
    \\  ttl_ms INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE TABLE IF NOT EXISTS semantic_cache (
    \\  cache_key TEXT PRIMARY KEY,
    \\  value_json TEXT NOT NULL,
    \\  embedding_json TEXT NOT NULL,
    \\  created_at_ms INTEGER NOT NULL,
    \\  ttl_ms INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE TABLE IF NOT EXISTS lifecycle_snapshots (
    \\  id TEXT PRIMARY KEY,
    \\  snapshot_type TEXT NOT NULL,
    \\  summary_json TEXT NOT NULL DEFAULT '{}',
    \\  created_at_ms INTEGER NOT NULL
    \\);
;

pub const postgres_schema =
    \\CREATE EXTENSION IF NOT EXISTS pg_trgm;
    \\CREATE EXTENSION IF NOT EXISTS vector;
    \\CREATE TABLE IF NOT EXISTS schema_migrations (
    \\  version bigint PRIMARY KEY,
    \\  name text NOT NULL,
    \\  applied_at_ms bigint NOT NULL
    \\);
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (1, 'core_primitives', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
    \\CREATE TABLE IF NOT EXISTS sources (
    \\  id text PRIMARY KEY,
    \\  type text NOT NULL,
    \\  title text NOT NULL,
    \\  raw_content_uri text,
    \\  content text NOT NULL DEFAULT '',
    \\  author text,
    \\  participants_json jsonb NOT NULL DEFAULT '[]',
    \\  permissions_json jsonb NOT NULL DEFAULT '[]',
    \\  scope text NOT NULL DEFAULT 'workspace',
    \\  created_at_ms bigint NOT NULL,
    \\  imported_at_ms bigint NOT NULL,
    \\  checksum text,
    \\  language text,
    \\  related_entities_json jsonb NOT NULL DEFAULT '[]',
    \\  metadata_json jsonb NOT NULL DEFAULT '{}'
    \\);
    \\CREATE TABLE IF NOT EXISTS artifacts (
    \\  id text PRIMARY KEY,
    \\  type text NOT NULL,
    \\  title text NOT NULL,
    \\  body text NOT NULL,
    \\  status text NOT NULL DEFAULT 'draft',
    \\  owner text,
    \\  space_id text,
    \\  version bigint NOT NULL DEFAULT 1,
    \\  created_at_ms bigint NOT NULL,
    \\  updated_at_ms bigint NOT NULL,
    \\  last_verified_at_ms bigint,
    \\  source_ids_json jsonb NOT NULL DEFAULT '[]',
    \\  related_entities_json jsonb NOT NULL DEFAULT '[]',
    \\  permissions_json jsonb NOT NULL DEFAULT '[]',
    \\  summary text,
    \\  agent_summary text,
    \\  search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('simple', coalesce(title,'') || ' ' || coalesce(body,''))) STORED
    \\);
    \\CREATE INDEX IF NOT EXISTS artifacts_search_idx ON artifacts USING gin(search_tsv);
    \\CREATE TABLE IF NOT EXISTS entities (
    \\  id text PRIMARY KEY,
    \\  type text NOT NULL,
    \\  name text NOT NULL,
    \\  aliases_json jsonb NOT NULL DEFAULT '[]',
    \\  description text,
    \\  canonical_artifact_id text,
    \\  metadata_json jsonb NOT NULL DEFAULT '{}',
    \\  created_at_ms bigint NOT NULL,
    \\  updated_at_ms bigint NOT NULL
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS entities_type_name_idx ON entities(type, lower(name));
    \\CREATE TABLE IF NOT EXISTS memory_atoms (
    \\  id text PRIMARY KEY,
    \\  subject_entity_id text,
    \\  predicate text NOT NULL DEFAULT 'states',
    \\  object text NOT NULL DEFAULT '',
    \\  text text NOT NULL,
    \\  scope text NOT NULL DEFAULT 'workspace',
    \\  confidence double precision NOT NULL DEFAULT 0.5,
    \\  status text NOT NULL DEFAULT 'proposed',
    \\  source_ids_json jsonb NOT NULL DEFAULT '[]',
    \\  evidence_ranges_json jsonb NOT NULL DEFAULT '[]',
    \\  created_by text NOT NULL DEFAULT 'human',
    \\  created_at_ms bigint NOT NULL,
    \\  valid_from_ms bigint,
    \\  valid_until_ms bigint,
    \\  last_verified_at_ms bigint,
    \\  owner text,
    \\  permissions_json jsonb NOT NULL DEFAULT '[]',
    \\  tags_json jsonb NOT NULL DEFAULT '[]',
    \\  embedding vector(1536),
    \\  search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('simple', coalesce(text,'') || ' ' || coalesce(predicate,'') || ' ' || coalesce(object,''))) STORED
    \\);
    \\CREATE INDEX IF NOT EXISTS memory_atoms_search_idx ON memory_atoms USING gin(search_tsv);
    \\CREATE INDEX IF NOT EXISTS memory_atoms_scope_status_idx ON memory_atoms(scope, status);
    \\CREATE TABLE IF NOT EXISTS vector_chunks (
    \\  id text PRIMARY KEY,
    \\  object_type text NOT NULL,
    \\  object_id text NOT NULL,
    \\  chunk_ordinal bigint NOT NULL DEFAULT 0,
    \\  text text NOT NULL DEFAULT '',
    \\  scope text NOT NULL DEFAULT 'workspace',
    \\  permissions_json jsonb NOT NULL DEFAULT '[]',
    \\  embedding_json jsonb NOT NULL,
    \\  embedding vector(1536),
    \\  model text,
    \\  dimensions bigint NOT NULL,
    \\  created_at_ms bigint NOT NULL,
    \\  updated_at_ms bigint NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS vector_chunks_object_idx ON vector_chunks(object_type, object_id);
    \\CREATE INDEX IF NOT EXISTS vector_chunks_scope_idx ON vector_chunks(scope);
    \\CREATE INDEX IF NOT EXISTS vector_chunks_embedding_idx ON vector_chunks USING ivfflat (embedding vector_cosine_ops);
    \\CREATE TABLE IF NOT EXISTS vector_outbox (
    \\  id bigserial PRIMARY KEY,
    \\  action text NOT NULL,
    \\  object_type text NOT NULL,
    \\  object_id text NOT NULL,
    \\  status text NOT NULL DEFAULT 'pending',
    \\  attempts bigint NOT NULL DEFAULT 0,
    \\  payload_json jsonb NOT NULL DEFAULT '{}',
    \\  created_at_ms bigint NOT NULL,
    \\  updated_at_ms bigint NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS vector_outbox_status_idx ON vector_outbox(status, id);
    \\CREATE TABLE IF NOT EXISTS relations (
    \\  id text PRIMARY KEY,
    \\  from_entity_id text NOT NULL,
    \\  relation_type text NOT NULL,
    \\  to_entity_id text NOT NULL,
    \\  source_ids_json jsonb NOT NULL DEFAULT '[]',
    \\  confidence double precision NOT NULL DEFAULT 0.5,
    \\  status text NOT NULL DEFAULT 'proposed',
    \\  created_at_ms bigint NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS context_packs (
    \\  id text PRIMARY KEY,
    \\  purpose text NOT NULL,
    \\  target text NOT NULL,
    \\  query_text text NOT NULL,
    \\  included_sources_json jsonb NOT NULL DEFAULT '[]',
    \\  included_artifacts_json jsonb NOT NULL DEFAULT '[]',
    \\  included_memory_atoms_json jsonb NOT NULL DEFAULT '[]',
    \\  generated_summary text NOT NULL,
    \\  token_budget bigint NOT NULL DEFAULT 12000,
    \\  created_at_ms bigint NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS compat_memories (
    \\  key text NOT NULL,
    \\  session_id text,
    \\  memory_atom_id text NOT NULL,
    \\  category text NOT NULL DEFAULT 'core',
    \\  timestamp_ms bigint NOT NULL
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS compat_memories_key_session_idx ON compat_memories(key, coalesce(session_id, ''));
    \\CREATE TABLE IF NOT EXISTS session_messages (
    \\  id bigserial PRIMARY KEY,
    \\  session_id text NOT NULL,
    \\  role text NOT NULL,
    \\  content text NOT NULL,
    \\  created_at_ms bigint NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS session_usage (
    \\  session_id text PRIMARY KEY,
    \\  total_tokens bigint NOT NULL DEFAULT 0,
    \\  updated_at_ms bigint NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS audit_events (
    \\  id bigserial PRIMARY KEY,
    \\  event_type text NOT NULL,
    \\  actor text,
    \\  object_type text NOT NULL,
    \\  object_id text NOT NULL,
    \\  payload_json jsonb NOT NULL DEFAULT '{}',
    \\  created_at_ms bigint NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS memory_feed_events (
    \\  id bigserial PRIMARY KEY,
    \\  event_type text NOT NULL,
    \\  object_type text NOT NULL,
    \\  object_id text NOT NULL,
    \\  scope text NOT NULL DEFAULT 'workspace',
    \\  dedupe_key text,
    \\  payload_json jsonb NOT NULL DEFAULT '{}',
    \\  status text NOT NULL DEFAULT 'pending',
    \\  created_at_ms bigint NOT NULL,
    \\  applied_at_ms bigint
    \\);
    \\CREATE INDEX IF NOT EXISTS memory_feed_events_scope_id_idx ON memory_feed_events(scope, id);
    \\CREATE UNIQUE INDEX IF NOT EXISTS memory_feed_events_dedupe_key_idx ON memory_feed_events(dedupe_key) WHERE dedupe_key IS NOT NULL;
    \\CREATE TABLE IF NOT EXISTS response_cache (
    \\  cache_key text PRIMARY KEY,
    \\  value_json jsonb NOT NULL,
    \\  created_at_ms bigint NOT NULL,
    \\  ttl_ms bigint NOT NULL DEFAULT 0
    \\);
    \\CREATE TABLE IF NOT EXISTS semantic_cache (
    \\  cache_key text PRIMARY KEY,
    \\  value_json jsonb NOT NULL,
    \\  embedding_json jsonb NOT NULL,
    \\  embedding vector(1536),
    \\  created_at_ms bigint NOT NULL,
    \\  ttl_ms bigint NOT NULL DEFAULT 0
    \\);
    \\CREATE TABLE IF NOT EXISTS lifecycle_snapshots (
    \\  id text PRIMARY KEY,
    \\  snapshot_type text NOT NULL,
    \\  summary_json jsonb NOT NULL DEFAULT '{}',
    \\  created_at_ms bigint NOT NULL
    \\);
;

test "sqlite migration includes core primitive tables and indexes" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS sources") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS schema_migrations") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS artifacts") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS entities") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS relations") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS context_packs") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS memory_atoms") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE VIRTUAL TABLE IF NOT EXISTS memory_atoms_fts USING fts5") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS vector_chunks") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "permissions_json TEXT NOT NULL DEFAULT '[]'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS vector_outbox") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS compat_memories") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS session_messages") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS session_usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS audit_events") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS memory_feed_events") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "idx_memory_feed_events_dedupe_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS response_cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS semantic_cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS lifecycle_snapshots") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE UNIQUE INDEX IF NOT EXISTS idx_compat_memories_key_session") != null);
}

test "postgres migration includes fts vector and expression indexes" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS sources") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS schema_migrations") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS artifacts") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS entities") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS relations") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS context_packs") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS compat_memories") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS session_messages") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS session_usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS vector_chunks") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS vector_outbox") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS memory_feed_events") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "memory_feed_events_dedupe_key_idx") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS response_cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS semantic_cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS lifecycle_snapshots") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE EXTENSION IF NOT EXISTS vector") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "embedding vector(1536)") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "vector_cosine_ops") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "USING gin(search_tsv)") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE UNIQUE INDEX IF NOT EXISTS entities_type_name_idx") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE UNIQUE INDEX IF NOT EXISTS compat_memories_key_session_idx") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "UNIQUE(type, lower(name))") == null);
}
