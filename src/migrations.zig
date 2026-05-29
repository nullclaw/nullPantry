const std = @import("std");

pub const expected_schema_version: i64 = 17;

pub const Migration = struct {
    version: i64,
    name: []const u8,
    checksum: []const u8,
};

pub const migration_manifest = [_]Migration{
    .{ .version = 1, .name = "core_primitives", .checksum = "np-001-core-primitives" },
    .{ .version = 2, .name = "security_and_retrieval_hardening", .checksum = "np-002-security-retrieval" },
    .{ .version = 3, .name = "runtime_lifecycle_cache", .checksum = "np-003-runtime-lifecycle-cache" },
    .{ .version = 4, .name = "ingest_jobs_conflicts", .checksum = "np-004-ingest-jobs-conflicts" },
    .{ .version = 5, .name = "spaces_policy_scopes", .checksum = "np-005-spaces-policy-scopes" },
    .{ .version = 6, .name = "connector_cursor_permissions", .checksum = "np-006-connector-cursor-permissions" },
    .{ .version = 7, .name = "vector_backing_invariant", .checksum = "np-007-vector-backing-invariant" },
    .{ .version = 8, .name = "agent_actor_isolation", .checksum = "np-008-agent-actor-isolation" },
    .{ .version = 9, .name = "strict_actor_memory", .checksum = "np-009-strict-actor-memory" },
    .{ .version = 10, .name = "cache_actor_isolation", .checksum = "np-010-cache-actor-isolation" },
    .{ .version = 11, .name = "native_agent_memory", .checksum = "np-011-native-agent-memory" },
    .{ .version = 12, .name = "context_pack_acl", .checksum = "np-012-context-pack-acl" },
    .{ .version = 13, .name = "context_pack_result_refs", .checksum = "np-013-context-pack-result-refs" },
    .{ .version = 14, .name = "memory_feed_lifecycle", .checksum = "np-014-memory-feed-lifecycle" },
    .{ .version = 15, .name = "agent_memory_writer_identity", .checksum = "np-015-agent-memory-writer-identity" },
    .{ .version = 16, .name = "job_leases", .checksum = "np-016-job-leases" },
    .{ .version = 17, .name = "vector_outbox_leases", .checksum = "np-017-vector-outbox-leases" },
};

pub fn expectedMigration(version: i64) ?Migration {
    for (migration_manifest) |migration| {
        if (migration.version == version) return migration;
    }
    return null;
}

pub const sqlite_schema =
    \\PRAGMA journal_mode = WAL;
    \\PRAGMA foreign_keys = ON;
    \\CREATE TABLE IF NOT EXISTS schema_migrations (
    \\  version INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL,
    \\  checksum TEXT NOT NULL DEFAULT '',
    \\  applied_at_ms INTEGER NOT NULL
    \\);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (1, 'core_primitives', strftime('%s','now') * 1000);
    \\CREATE TABLE IF NOT EXISTS spaces (
    \\  id TEXT PRIMARY KEY,
    \\  name TEXT NOT NULL UNIQUE,
    \\  title TEXT NOT NULL,
    \\  description TEXT,
    \\  scope TEXT NOT NULL DEFAULT 'workspace',
    \\  permissions_json TEXT NOT NULL DEFAULT '[]',
    \\  metadata_json TEXT NOT NULL DEFAULT '{}',
    \\  created_at_ms INTEGER NOT NULL,
    \\  updated_at_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_spaces_scope ON spaces(scope);
    \\CREATE TABLE IF NOT EXISTS policy_scopes (
    \\  scope TEXT PRIMARY KEY,
    \\  visibility TEXT NOT NULL DEFAULT 'workspace',
    \\  permissions_json TEXT NOT NULL DEFAULT '[]',
    \\  owner TEXT,
    \\  ttl_ms INTEGER,
    \\  review_after_ms INTEGER,
    \\  metadata_json TEXT NOT NULL DEFAULT '{}',
    \\  created_at_ms INTEGER NOT NULL,
    \\  updated_at_ms INTEGER NOT NULL
    \\);
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
    \\  scope TEXT NOT NULL DEFAULT 'workspace',
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
    \\  scope TEXT NOT NULL DEFAULT 'workspace',
    \\  permissions_json TEXT NOT NULL DEFAULT '[]',
    \\  metadata_json TEXT NOT NULL DEFAULT '{}',
    \\  created_at_ms INTEGER NOT NULL,
    \\  updated_at_ms INTEGER NOT NULL
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_entities_type_name_scope ON entities(type, lower(name), scope);
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
    \\  object_type TEXT NOT NULL CHECK (object_type IN ('memory_atom','source','artifact')),
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
    \\  locked_until_ms INTEGER,
    \\  worker_id TEXT,
    \\  created_at_ms INTEGER NOT NULL,
    \\  updated_at_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_vector_outbox_status ON vector_outbox(status, id);
    \\CREATE INDEX IF NOT EXISTS idx_vector_outbox_status_locked ON vector_outbox(status, locked_until_ms);
    \\CREATE TABLE IF NOT EXISTS relations (
    \\  id TEXT PRIMARY KEY,
    \\  from_entity_id TEXT NOT NULL,
    \\  relation_type TEXT NOT NULL,
    \\  to_entity_id TEXT NOT NULL,
    \\  source_ids_json TEXT NOT NULL DEFAULT '[]',
    \\  scope TEXT NOT NULL DEFAULT 'workspace',
    \\  permissions_json TEXT NOT NULL DEFAULT '[]',
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
    \\  included_result_refs_json TEXT NOT NULL DEFAULT '[]',
    \\  required_scopes_json TEXT NOT NULL DEFAULT '["admin"]',
    \\  actor_id TEXT,
    \\  actor_isolated INTEGER NOT NULL DEFAULT 0,
    \\  generated_summary TEXT NOT NULL,
    \\  token_budget INTEGER NOT NULL DEFAULT 12000,
    \\  created_at_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS agent_memory_items (
    \\  id TEXT PRIMARY KEY,
    \\  key TEXT NOT NULL,
    \\  session_id TEXT,
    \\  actor_id TEXT NOT NULL,
    \\  writer_actor_id TEXT NOT NULL DEFAULT '',
    \\  scope TEXT NOT NULL DEFAULT 'personal',
    \\  permissions_json TEXT NOT NULL DEFAULT '[]',
    \\  memory_atom_id TEXT NOT NULL,
    \\  category TEXT NOT NULL DEFAULT 'core',
    \\  timestamp_ms INTEGER NOT NULL,
    \\  metadata_json TEXT NOT NULL DEFAULT '{}'
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_memory_key_session_actor ON agent_memory_items(key, coalesce(session_id, ''), actor_id);
    \\CREATE INDEX IF NOT EXISTS idx_agent_memory_actor_session ON agent_memory_items(actor_id, session_id, timestamp_ms);
    \\CREATE INDEX IF NOT EXISTS idx_agent_memory_writer ON agent_memory_items(writer_actor_id, timestamp_ms);
    \\CREATE TABLE IF NOT EXISTS session_messages (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  session_id TEXT NOT NULL,
    \\  actor_id TEXT NOT NULL,
    \\  role TEXT NOT NULL,
    \\  content TEXT NOT NULL,
    \\  created_at_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_session_messages_session_actor ON session_messages(session_id, actor_id, id);
    \\CREATE TABLE IF NOT EXISTS session_usage (
    \\  session_id TEXT NOT NULL,
    \\  actor_id TEXT NOT NULL,
    \\  total_tokens INTEGER NOT NULL DEFAULT 0,
    \\  updated_at_ms INTEGER NOT NULL,
    \\  PRIMARY KEY (session_id, actor_id)
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
    \\  operation TEXT NOT NULL DEFAULT 'put',
    \\  object_type TEXT NOT NULL,
    \\  object_id TEXT NOT NULL,
    \\  scope TEXT NOT NULL DEFAULT 'workspace',
    \\  permissions_json TEXT NOT NULL DEFAULT '[]',
    \\  actor_id TEXT,
    \\  dedupe_key TEXT,
    \\  causality_json TEXT NOT NULL DEFAULT '{}',
    \\  payload_json TEXT NOT NULL DEFAULT '{}',
    \\  status TEXT NOT NULL DEFAULT 'pending',
    \\  created_at_ms INTEGER NOT NULL,
    \\  applied_at_ms INTEGER,
    \\  compacted_at_ms INTEGER
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_memory_feed_events_scope_id ON memory_feed_events(scope, id);
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_feed_events_dedupe_key ON memory_feed_events(dedupe_key) WHERE dedupe_key IS NOT NULL;
    \\CREATE TABLE IF NOT EXISTS memory_feed_state (
    \\  id INTEGER PRIMARY KEY CHECK (id = 1),
    \\  cursor_floor INTEGER NOT NULL DEFAULT 0,
    \\  updated_at_ms INTEGER NOT NULL
    \\);
    \\INSERT OR IGNORE INTO memory_feed_state (id, cursor_floor, updated_at_ms) VALUES (1, 0, strftime('%s','now') * 1000);
    \\CREATE TABLE IF NOT EXISTS response_cache (
    \\  cache_key TEXT NOT NULL,
    \\  response_json TEXT NOT NULL,
    \\  scopes_json TEXT NOT NULL DEFAULT '[]',
    \\  actor_id TEXT NOT NULL DEFAULT '',
    \\  created_at_ms INTEGER NOT NULL,
    \\  expires_at_ms INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (actor_id, cache_key)
    \\);
    \\CREATE TABLE IF NOT EXISTS semantic_cache (
    \\  cache_key TEXT NOT NULL,
    \\  query TEXT NOT NULL DEFAULT '',
    \\  response_json TEXT NOT NULL,
    \\  embedding_json TEXT NOT NULL,
    \\  scopes_json TEXT NOT NULL DEFAULT '[]',
    \\  actor_id TEXT NOT NULL DEFAULT '',
    \\  created_at_ms INTEGER NOT NULL,
    \\  expires_at_ms INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (actor_id, cache_key)
    \\);
    \\CREATE TABLE IF NOT EXISTS lifecycle_snapshots (
    \\  id TEXT PRIMARY KEY,
    \\  snapshot_type TEXT NOT NULL,
    \\  summary_json TEXT NOT NULL DEFAULT '{}',
    \\  created_at_ms INTEGER NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS jobs (
    \\  id TEXT PRIMARY KEY,
    \\  job_type TEXT NOT NULL,
    \\  status TEXT NOT NULL DEFAULT 'queued',
    \\  scope TEXT NOT NULL DEFAULT 'workspace',
    \\  permissions_json TEXT NOT NULL DEFAULT '[]',
    \\  object_type TEXT NOT NULL DEFAULT '',
    \\  object_id TEXT NOT NULL DEFAULT '',
    \\  input_json TEXT NOT NULL DEFAULT '{}',
    \\  result_json TEXT NOT NULL DEFAULT '{}',
    \\  error_text TEXT,
    \\  attempts INTEGER NOT NULL DEFAULT 0,
    \\  locked_until_ms INTEGER,
    \\  worker_id TEXT,
    \\  created_at_ms INTEGER NOT NULL,
    \\  updated_at_ms INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_jobs_scope_status ON jobs(scope, status, created_at_ms);
    \\CREATE INDEX IF NOT EXISTS idx_jobs_status_locked ON jobs(status, locked_until_ms);
    \\CREATE TABLE IF NOT EXISTS knowledge_conflicts (
    \\  id TEXT PRIMARY KEY,
    \\  conflict_type TEXT NOT NULL,
    \\  object_a_type TEXT NOT NULL,
    \\  object_a_id TEXT NOT NULL,
    \\  object_b_type TEXT NOT NULL,
    \\  object_b_id TEXT NOT NULL,
    \\  scope TEXT NOT NULL DEFAULT 'workspace',
    \\  permissions_json TEXT NOT NULL DEFAULT '[]',
    \\  status TEXT NOT NULL DEFAULT 'open',
    \\  summary TEXT NOT NULL,
    \\  created_at_ms INTEGER NOT NULL,
    \\  resolved_at_ms INTEGER
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_knowledge_conflicts_pair ON knowledge_conflicts(conflict_type, object_a_id, object_b_id);
    \\CREATE TABLE IF NOT EXISTS connector_cursors (
    \\  connector TEXT NOT NULL,
    \\  scope TEXT NOT NULL,
    \\  cursor TEXT NOT NULL DEFAULT '',
    \\  config_json TEXT NOT NULL DEFAULT '{}',
    \\  permissions_json TEXT NOT NULL DEFAULT '[]',
    \\  updated_at_ms INTEGER NOT NULL,
    \\  PRIMARY KEY (connector, scope)
    \\);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (4, 'ingest_jobs_conflicts', strftime('%s','now') * 1000);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (5, 'spaces_policy_scopes', strftime('%s','now') * 1000);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (6, 'connector_cursor_permissions', strftime('%s','now') * 1000);
    \\DELETE FROM vector_chunks WHERE object_type NOT IN ('memory_atom','source','artifact');
    \\DELETE FROM vector_chunks WHERE object_type = 'memory_atom' AND NOT EXISTS (SELECT 1 FROM memory_atoms WHERE memory_atoms.id = vector_chunks.object_id);
    \\DELETE FROM vector_chunks WHERE object_type = 'source' AND NOT EXISTS (SELECT 1 FROM sources WHERE sources.id = vector_chunks.object_id);
    \\DELETE FROM vector_chunks WHERE object_type = 'artifact' AND NOT EXISTS (SELECT 1 FROM artifacts WHERE artifacts.id = vector_chunks.object_id);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (7, 'vector_backing_invariant', strftime('%s','now') * 1000);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (8, 'agent_actor_isolation', strftime('%s','now') * 1000);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (9, 'strict_actor_memory', strftime('%s','now') * 1000);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (10, 'cache_actor_isolation', strftime('%s','now') * 1000);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (11, 'native_agent_memory', strftime('%s','now') * 1000);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (12, 'context_pack_acl', strftime('%s','now') * 1000);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (13, 'context_pack_result_refs', strftime('%s','now') * 1000);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (14, 'memory_feed_lifecycle', strftime('%s','now') * 1000);
    \\INSERT OR IGNORE INTO schema_migrations (version, name, applied_at_ms) VALUES (15, 'agent_memory_writer_identity', strftime('%s','now') * 1000);
;

pub const postgres_schema =
    \\CREATE EXTENSION IF NOT EXISTS pg_trgm;
    \\CREATE EXTENSION IF NOT EXISTS vector;
    \\CREATE TABLE IF NOT EXISTS schema_migrations (
    \\  version bigint PRIMARY KEY,
    \\  name text NOT NULL,
    \\  checksum text NOT NULL DEFAULT '',
    \\  applied_at_ms bigint NOT NULL
    \\);
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (1, 'core_primitives', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
    \\CREATE TABLE IF NOT EXISTS spaces (
    \\  id text PRIMARY KEY,
    \\  name text NOT NULL UNIQUE,
    \\  title text NOT NULL,
    \\  description text,
    \\  scope text NOT NULL DEFAULT 'workspace',
    \\  permissions_json jsonb NOT NULL DEFAULT '[]'::jsonb,
    \\  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    \\  created_at_ms bigint NOT NULL,
    \\  updated_at_ms bigint NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_spaces_scope ON spaces(scope);
    \\CREATE TABLE IF NOT EXISTS policy_scopes (
    \\  scope text PRIMARY KEY,
    \\  visibility text NOT NULL DEFAULT 'workspace',
    \\  permissions_json jsonb NOT NULL DEFAULT '[]'::jsonb,
    \\  owner text,
    \\  ttl_ms bigint,
    \\  review_after_ms bigint,
    \\  metadata_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    \\  created_at_ms bigint NOT NULL,
    \\  updated_at_ms bigint NOT NULL
    \\);
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
    \\  scope text NOT NULL DEFAULT 'workspace',
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
    \\  scope text NOT NULL DEFAULT 'workspace',
    \\  permissions_json jsonb NOT NULL DEFAULT '[]',
    \\  metadata_json jsonb NOT NULL DEFAULT '{}',
    \\  created_at_ms bigint NOT NULL,
    \\  updated_at_ms bigint NOT NULL
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS entities_type_name_scope_idx ON entities(type, lower(name), scope);
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
    \\  embedding vector,
    \\  search_tsv tsvector GENERATED ALWAYS AS (to_tsvector('simple', coalesce(text,'') || ' ' || coalesce(predicate,'') || ' ' || coalesce(object,''))) STORED
    \\);
    \\CREATE INDEX IF NOT EXISTS memory_atoms_search_idx ON memory_atoms USING gin(search_tsv);
    \\CREATE INDEX IF NOT EXISTS memory_atoms_scope_status_idx ON memory_atoms(scope, status);
    \\CREATE TABLE IF NOT EXISTS vector_chunks (
    \\  id text PRIMARY KEY,
    \\  object_type text NOT NULL CHECK (object_type IN ('memory_atom','source','artifact')),
    \\  object_id text NOT NULL,
    \\  chunk_ordinal bigint NOT NULL DEFAULT 0,
    \\  text text NOT NULL DEFAULT '',
    \\  scope text NOT NULL DEFAULT 'workspace',
    \\  permissions_json jsonb NOT NULL DEFAULT '[]',
    \\  embedding_json jsonb NOT NULL,
    \\  embedding vector,
    \\  model text,
    \\  dimensions bigint NOT NULL,
    \\  created_at_ms bigint NOT NULL,
    \\  updated_at_ms bigint NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS vector_chunks_object_idx ON vector_chunks(object_type, object_id);
    \\CREATE INDEX IF NOT EXISTS vector_chunks_scope_idx ON vector_chunks(scope);
    \\CREATE INDEX IF NOT EXISTS vector_chunks_embedding_1536_idx ON vector_chunks USING ivfflat ((embedding::vector(1536)) vector_cosine_ops) WHERE dimensions = 1536;
    \\CREATE TABLE IF NOT EXISTS vector_outbox (
    \\  id bigserial PRIMARY KEY,
    \\  action text NOT NULL,
    \\  object_type text NOT NULL,
    \\  object_id text NOT NULL,
    \\  status text NOT NULL DEFAULT 'pending',
    \\  attempts bigint NOT NULL DEFAULT 0,
    \\  payload_json jsonb NOT NULL DEFAULT '{}',
    \\  locked_until_ms bigint,
    \\  worker_id text,
    \\  created_at_ms bigint NOT NULL,
    \\  updated_at_ms bigint NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS vector_outbox_status_idx ON vector_outbox(status, id);
    \\CREATE INDEX IF NOT EXISTS vector_outbox_status_locked_idx ON vector_outbox(status, locked_until_ms);
    \\CREATE TABLE IF NOT EXISTS relations (
    \\  id text PRIMARY KEY,
    \\  from_entity_id text NOT NULL,
    \\  relation_type text NOT NULL,
    \\  to_entity_id text NOT NULL,
    \\  source_ids_json jsonb NOT NULL DEFAULT '[]',
    \\  scope text NOT NULL DEFAULT 'workspace',
    \\  permissions_json jsonb NOT NULL DEFAULT '[]',
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
    \\  included_result_refs_json jsonb NOT NULL DEFAULT '[]',
    \\  required_scopes_json jsonb NOT NULL DEFAULT '["admin"]',
    \\  actor_id text,
    \\  actor_isolated boolean NOT NULL DEFAULT false,
    \\  generated_summary text NOT NULL,
    \\  token_budget bigint NOT NULL DEFAULT 12000,
    \\  created_at_ms bigint NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS agent_memory_items (
    \\  id text PRIMARY KEY,
    \\  key text NOT NULL,
    \\  session_id text,
    \\  actor_id text NOT NULL,
    \\  writer_actor_id text NOT NULL DEFAULT '',
    \\  scope text NOT NULL DEFAULT 'personal',
    \\  permissions_json jsonb NOT NULL DEFAULT '[]',
    \\  memory_atom_id text NOT NULL,
    \\  category text NOT NULL DEFAULT 'core',
    \\  timestamp_ms bigint NOT NULL,
    \\  metadata_json jsonb NOT NULL DEFAULT '{}'
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS agent_memory_key_session_actor_idx ON agent_memory_items(key, coalesce(session_id, ''), actor_id);
    \\CREATE INDEX IF NOT EXISTS agent_memory_actor_session_idx ON agent_memory_items(actor_id, session_id, timestamp_ms);
    \\CREATE INDEX IF NOT EXISTS agent_memory_writer_idx ON agent_memory_items(writer_actor_id, timestamp_ms);
    \\CREATE TABLE IF NOT EXISTS session_messages (
    \\  id bigserial PRIMARY KEY,
    \\  session_id text NOT NULL,
    \\  actor_id text NOT NULL,
    \\  role text NOT NULL,
    \\  content text NOT NULL,
    \\  created_at_ms bigint NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS session_messages_session_actor_idx ON session_messages(session_id, actor_id, id);
    \\CREATE TABLE IF NOT EXISTS session_usage (
    \\  session_id text NOT NULL,
    \\  actor_id text NOT NULL,
    \\  total_tokens bigint NOT NULL DEFAULT 0,
    \\  updated_at_ms bigint NOT NULL,
    \\  PRIMARY KEY (session_id, actor_id)
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
    \\  operation text NOT NULL DEFAULT 'put',
    \\  object_type text NOT NULL,
    \\  object_id text NOT NULL,
    \\  scope text NOT NULL DEFAULT 'workspace',
    \\  permissions_json jsonb NOT NULL DEFAULT '[]'::jsonb,
    \\  actor_id text,
    \\  dedupe_key text,
    \\  causality_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    \\  payload_json jsonb NOT NULL DEFAULT '{}',
    \\  status text NOT NULL DEFAULT 'pending',
    \\  created_at_ms bigint NOT NULL,
    \\  applied_at_ms bigint,
    \\  compacted_at_ms bigint
    \\);
    \\CREATE INDEX IF NOT EXISTS memory_feed_events_scope_id_idx ON memory_feed_events(scope, id);
    \\CREATE UNIQUE INDEX IF NOT EXISTS memory_feed_events_dedupe_key_idx ON memory_feed_events(dedupe_key) WHERE dedupe_key IS NOT NULL;
    \\CREATE TABLE IF NOT EXISTS memory_feed_state (
    \\  id integer PRIMARY KEY CHECK (id = 1),
    \\  cursor_floor bigint NOT NULL DEFAULT 0,
    \\  updated_at_ms bigint NOT NULL
    \\);
    \\INSERT INTO memory_feed_state (id, cursor_floor, updated_at_ms) VALUES (1, 0, (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (id) DO NOTHING;
    \\CREATE TABLE IF NOT EXISTS response_cache (
    \\  cache_key text NOT NULL,
    \\  response_json jsonb NOT NULL,
    \\  scopes_json jsonb NOT NULL DEFAULT '[]'::jsonb,
    \\  actor_id text NOT NULL DEFAULT '',
    \\  created_at_ms bigint NOT NULL,
    \\  expires_at_ms bigint NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (actor_id, cache_key)
    \\);
    \\CREATE TABLE IF NOT EXISTS semantic_cache (
    \\  cache_key text NOT NULL,
    \\  query text NOT NULL DEFAULT '',
    \\  response_json jsonb NOT NULL,
    \\  embedding_json jsonb NOT NULL,
    \\  scopes_json jsonb NOT NULL DEFAULT '[]'::jsonb,
    \\  actor_id text NOT NULL DEFAULT '',
    \\  embedding vector,
    \\  created_at_ms bigint NOT NULL,
    \\  expires_at_ms bigint NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (actor_id, cache_key)
    \\);
    \\CREATE TABLE IF NOT EXISTS lifecycle_snapshots (
    \\  id text PRIMARY KEY,
    \\  snapshot_type text NOT NULL,
    \\  summary_json jsonb NOT NULL DEFAULT '{}',
    \\  created_at_ms bigint NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS jobs (
    \\  id text PRIMARY KEY,
    \\  job_type text NOT NULL,
    \\  status text NOT NULL DEFAULT 'queued',
    \\  scope text NOT NULL DEFAULT 'workspace',
    \\  permissions_json jsonb NOT NULL DEFAULT '[]',
    \\  object_type text NOT NULL DEFAULT '',
    \\  object_id text NOT NULL DEFAULT '',
    \\  input_json jsonb NOT NULL DEFAULT '{}',
    \\  result_json jsonb NOT NULL DEFAULT '{}',
    \\  error_text text,
    \\  attempts bigint NOT NULL DEFAULT 0,
    \\  locked_until_ms bigint,
    \\  worker_id text,
    \\  created_at_ms bigint NOT NULL,
    \\  updated_at_ms bigint NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS jobs_scope_status_idx ON jobs(scope, status, created_at_ms);
    \\CREATE INDEX IF NOT EXISTS jobs_status_locked_idx ON jobs(status, locked_until_ms);
    \\CREATE TABLE IF NOT EXISTS knowledge_conflicts (
    \\  id text PRIMARY KEY,
    \\  conflict_type text NOT NULL,
    \\  object_a_type text NOT NULL,
    \\  object_a_id text NOT NULL,
    \\  object_b_type text NOT NULL,
    \\  object_b_id text NOT NULL,
    \\  scope text NOT NULL DEFAULT 'workspace',
    \\  permissions_json jsonb NOT NULL DEFAULT '[]',
    \\  status text NOT NULL DEFAULT 'open',
    \\  summary text NOT NULL,
    \\  created_at_ms bigint NOT NULL,
    \\  resolved_at_ms bigint
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS knowledge_conflicts_pair_idx ON knowledge_conflicts(conflict_type, object_a_id, object_b_id);
    \\CREATE TABLE IF NOT EXISTS connector_cursors (
    \\  connector text NOT NULL,
    \\  scope text NOT NULL,
    \\  cursor text NOT NULL DEFAULT '',
    \\  config_json jsonb NOT NULL DEFAULT '{}',
    \\  permissions_json jsonb NOT NULL DEFAULT '[]',
    \\  updated_at_ms bigint NOT NULL,
    \\  PRIMARY KEY (connector, scope)
    \\);
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (4, 'ingest_jobs_conflicts', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (5, 'spaces_policy_scopes', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (6, 'connector_cursor_permissions', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
    \\DELETE FROM vector_chunks WHERE object_type NOT IN ('memory_atom','source','artifact');
    \\DELETE FROM vector_chunks WHERE object_type = 'memory_atom' AND NOT EXISTS (SELECT 1 FROM memory_atoms WHERE memory_atoms.id = vector_chunks.object_id);
    \\DELETE FROM vector_chunks WHERE object_type = 'source' AND NOT EXISTS (SELECT 1 FROM sources WHERE sources.id = vector_chunks.object_id);
    \\DELETE FROM vector_chunks WHERE object_type = 'artifact' AND NOT EXISTS (SELECT 1 FROM artifacts WHERE artifacts.id = vector_chunks.object_id);
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (7, 'vector_backing_invariant', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (8, 'agent_actor_isolation', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (9, 'strict_actor_memory', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (10, 'cache_actor_isolation', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (11, 'native_agent_memory', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (12, 'context_pack_acl', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (13, 'context_pack_result_refs', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (14, 'memory_feed_lifecycle', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
    \\INSERT INTO schema_migrations (version, name, applied_at_ms) VALUES (15, 'agent_memory_writer_identity', (extract(epoch from clock_timestamp()) * 1000)::bigint) ON CONFLICT (version) DO NOTHING;
;

test "sqlite migration includes core primitive tables and indexes" {
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS sources") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS schema_migrations") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS spaces") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS policy_scopes") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS artifacts") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS entities") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS relations") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS context_packs") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "included_result_refs_json TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS memory_atoms") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE VIRTUAL TABLE IF NOT EXISTS memory_atoms_fts USING fts5") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS vector_chunks") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "permissions_json TEXT NOT NULL DEFAULT '[]'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS vector_outbox") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "idx_vector_outbox_status_locked") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS agent_memory_items") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_memory_key_session_actor") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "writer_actor_id TEXT NOT NULL DEFAULT ''") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "idx_agent_memory_writer") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS compat_memories") == null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS session_messages") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS session_usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS audit_events") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS memory_feed_events") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "idx_memory_feed_events_dedupe_key") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS response_cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS semantic_cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "scopes_json TEXT NOT NULL DEFAULT '[]'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "PRIMARY KEY (actor_id, cache_key)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS lifecycle_snapshots") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS jobs") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS knowledge_conflicts") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE TABLE IF NOT EXISTS connector_cursors") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "'connector_cursor_permissions'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "'vector_backing_invariant'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "'strict_actor_memory'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "'cache_actor_isolation'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "'native_agent_memory'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "'agent_memory_writer_identity'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "'context_pack_acl'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "actor_isolated INTEGER NOT NULL DEFAULT 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "checksum TEXT NOT NULL DEFAULT ''") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "object_type TEXT NOT NULL CHECK") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "'ingest_jobs_conflicts'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "'spaces_policy_scopes'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "actor_id TEXT NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "coalesce(actor_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "CREATE INDEX IF NOT EXISTS idx_session_messages_session_actor") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "PRIMARY KEY (session_id, actor_id)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "'agent_actor_isolation'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sqlite_schema, "'nullclaw_actor_isolation'") == null);
}

test "postgres migration includes fts vector and expression indexes" {
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS sources") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS schema_migrations") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS spaces") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS policy_scopes") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS artifacts") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS entities") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS relations") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS context_packs") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "included_result_refs_json jsonb") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS agent_memory_items") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "writer_actor_id text NOT NULL DEFAULT ''") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS compat_memories") == null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS session_messages") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS session_usage") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS vector_chunks") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS vector_outbox") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "vector_outbox_status_locked_idx") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS memory_feed_events") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "memory_feed_events_dedupe_key_idx") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS response_cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS semantic_cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "scopes_json jsonb NOT NULL DEFAULT '[]'::jsonb") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "PRIMARY KEY (actor_id, cache_key)") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS lifecycle_snapshots") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS jobs") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS knowledge_conflicts") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE TABLE IF NOT EXISTS connector_cursors") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "'connector_cursor_permissions'") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "'vector_backing_invariant'") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "'strict_actor_memory'") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "'cache_actor_isolation'") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "'native_agent_memory'") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "'agent_memory_writer_identity'") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "'context_pack_acl'") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "actor_isolated boolean NOT NULL DEFAULT false") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "checksum text NOT NULL DEFAULT ''") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "object_type text NOT NULL CHECK") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "'ingest_jobs_conflicts'") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "'spaces_policy_scopes'") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE EXTENSION IF NOT EXISTS vector") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "embedding vector") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "dimensions = 1536") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "vector_cosine_ops") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "USING gin(search_tsv)") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE UNIQUE INDEX IF NOT EXISTS entities_type_name_scope_idx") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE UNIQUE INDEX IF NOT EXISTS agent_memory_key_session_actor_idx") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE INDEX IF NOT EXISTS agent_memory_writer_idx") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "actor_id text NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "coalesce(actor_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "CREATE INDEX IF NOT EXISTS session_messages_session_actor_idx") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "PRIMARY KEY (session_id, actor_id)") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "'agent_actor_isolation'") != null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "'nullclaw_actor_isolation'") == null);
    try std.testing.expect(std.mem.indexOf(u8, postgres_schema, "UNIQUE(type, lower(name))") == null);
}

test "migration manifest is ordered and current" {
    try std.testing.expectEqual(@as(i64, expected_schema_version), migration_manifest[migration_manifest.len - 1].version);
    var expected: i64 = 1;
    for (migration_manifest) |migration| {
        try std.testing.expectEqual(expected, migration.version);
        try std.testing.expect(migration.name.len > 0);
        try std.testing.expect(migration.checksum.len > 0);
        expected += 1;
    }
    try std.testing.expect(expectedMigration(7) != null);
    try std.testing.expect(expectedMigration(99) == null);
}
