# NullPantry Product Architecture

NullPantry is the headless, agent-native knowledge base for the Null ecosystem. It is not only the remote memory backend for NullClaw. That integration is the minimum adoption path, while the product boundary is broader:

```text
NullPantry = Confluence-like knowledge base + long-term memory + RAG + knowledge graph + context serving API
```

UI belongs in NullHub and NullDesk. NullPantry owns the storage, provenance, permissions, retrieval, lifecycle, graph, vector, and context APIs that make knowledge usable by people and agents.

## Product Contract

NullPantry answers more than "where is the document?" It should answer:

- What do we know?
- Why did we decide it?
- What changed?
- Which knowledge is stale, contradicted, deprecated, or unverified?
- Which permission-aware, citation-backed context should an agent receive before doing work?

Every feature should reduce to the same primitives instead of becoming a separate subsystem.

## Core Primitives

`Source` or `Ingredient` is the raw origin of knowledge: transcript, PDF, markdown file, ticket, issue, PR, chat thread, incident event, email, recording, document import, or agent observation. A source is provenance, not the final human-readable knowledge object.

`Artifact` or `Page` is the human-readable object: wiki page, meeting note, ADR, runbook, product spec, architecture doc, onboarding guide, incident report, research note, or project overview.

`MemoryAtom` is the small extracted fact or claim agents can use directly. It must carry source, timestamp, confidence, scope, author or speaker, evidence, status, freshness, expiry, and related entities.

`Entity` is the canonical thing knowledge gathers around: project, service, person, team, repository, API, document, decision, meeting, ticket, customer, feature, incident, or concept.

`Relation` links entities into a knowledge graph: meeting produced decision, decision supersedes decision, page documents service, incident affected service, PR fixes ticket, runbook belongs to service, feature depends on API.

`ContextPack` or `Mise` is prepared context for a person or agent. It is not just top vector chunks. It contains relevant facts, accepted decisions, constraints, forbidden assumptions, related docs/tickets/incidents/runbooks, recent changes, open questions, suggested next steps, and citations.

`PolicyScope` defines who can read, propose, write, verify, delete, forget, export, or receive a piece of knowledge. Permission-aware retrieval is a core invariant.

## First-Class Content Types

NullPantry should keep the content taxonomy small and strong:

- `page`: general wiki knowledge, notes, guides, onboarding, ideas, documentation.
- `spec`: problem, goals, non-goals, users, use cases, requirements, risks, dependencies, success metrics.
- `decision`: ADR-style decision with proposed, accepted, rejected, deprecated, and superseded states.
- `runbook` or `recipe`: repeatable operational or agent procedure, including prerequisites, steps, rollback, owners, and verification.
- `meeting_note`: structured result of a transcript source, with summary, topics, decisions, action items, open questions, risks, and mentioned entities.
- `research`: question, sources, findings, assumptions, conclusion, confidence, unresolved questions.
- `incident_report`: timeline, affected systems, symptoms, root cause, mitigation, follow-ups, linked runbooks, and lessons learned.
- `memory_item`: explicitly saved human or agent memory with content, source, confidence, owner, expiry, tags, and lifecycle status.

## Meeting Memory Model

Meeting memory is a pipeline over the primitives, not a separate product module:

1. Create a `Source` for audio/transcript/participants/date/title/permissions.
2. Derive an `Artifact` of type `meeting_note`.
3. Extract `MemoryAtom` records for decisions, action items, constraints, risks, and open questions.
4. Link `Relation` records such as meeting produced decision, decision affects project, action item creates ticket, participant owns action item.
5. Serve a `ContextPack` when an agent needs the latest context for a task.

The same pattern applies to tickets, incidents, PRs, research, and agent observations.

## Retrieval Contract

Production retrieval must be one end-to-end path:

```text
actor/token claims -> ACL filter -> keyword candidates -> vector candidates -> entity graph expansion -> fusion/rerank -> citation-safe results -> context assembly
```

Search, Ask, and Context Packs should share this path. A retrieved answer is not valid unless every source, artifact, atom, relation, vector chunk, generated summary, and citation is visible to the requesting actor.

## Lifecycle Contract

Knowledge is not append-only text. It has lifecycle:

- status: proposed, verified, accepted, rejected, stale, deprecated, superseded.
- freshness: fresh, probably fresh, needs review, stale.
- expiry and review dates for volatile knowledge such as owners, roadmaps, temporary workarounds, active incidents, and weekly priorities.
- conflict detection when newer sources contradict old memory.
- snapshot, hygiene, cache, diagnostics, feed, checkpoint, and compaction for long-running agent ecosystems.

Old decisions should be superseded, not deleted, so agents can understand why the system changed.

## Null Ecosystem Boundary

NullClaw keeps local execution and minimal local memory: `none`, in-process `memory`, local `sqlite`, and `markdown`.

NullPantry owns anything central or advanced: shared memory, cross-agent isolation/sharing, source-backed knowledge, permission-aware RAG, context packs, graph retrieval, vector indexes, Redis shared agent memory/session/usage, Postgres production storage with pgvector, Qdrant and LanceDB vector planes, ClickHouse analytics/event-history export, optional Lucid semantic projection, feed/apply/checkpoint, lifecycle, snapshots, and diagnostics.

NullBoiler can orchestrate multiple agents. NullTickets can send tickets and decisions. NullWatch can send incidents and events. NullHub and NullDesk can render the UI. NullPantry remains the headless knowledge and context service underneath.
