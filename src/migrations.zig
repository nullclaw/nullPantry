pub const sqlite_schema =
    \\PRAGMA journal_mode = WAL;
    \\PRAGMA foreign_keys = ON;
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
;

pub const postgres_schema =
    \\CREATE EXTENSION IF NOT EXISTS pg_trgm;
    \\CREATE EXTENSION IF NOT EXISTS vector;
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
;

test "sqlite migration includes core primitive tables and indexes" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS sources") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS artifacts") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS entities") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS relations") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS context_packs") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS memory_atoms") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE VIRTUAL TABLE IF NOT EXISTS memory_atoms_fts USING fts5") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS compat_memories") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS session_messages") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS session_usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS audit_events") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE UNIQUE INDEX IF NOT EXISTS idx_compat_memories_key_session") != null);
}

test "postgres migration includes fts vector and expression indexes" {
    const std = @import("std");
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS sources") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS artifacts") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS entities") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS relations") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS context_packs") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS compat_memories") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS session_messages") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS session_usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE EXTENSION IF NOT EXISTS vector") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "embedding vector(1536)") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "USING gin(search_tsv)") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE UNIQUE INDEX IF NOT EXISTS entities_type_name_idx") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE UNIQUE INDEX IF NOT EXISTS compat_memories_key_session_idx") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "UNIQUE(type, lower(name))") == null);
}
