const std = @import("std");

pub const Operation = enum {
    analyticsStatus,
    appendFeed,
    appendFeedEvent,
    appendNativeFeed,
    appendNativeFeedEvent,
    applyFeedEvent,
    applyNativeFeedEvent,
    ask,
    bootstrapPromptDelete,
    bootstrapPromptExists,
    bootstrapPromptGet,
    bootstrapPromptPost,
    bootstrapPromptPut,
    bootstrapPromptsFingerprint,
    bootstrapPromptsImportDirectory,
    bootstrapPromptsList,
    bootstrapPromptsReset,
    capabilities,
    clearAgentAutoSavedMessages,
    clearAgentSessionMessages,
    clearEmbeddingCache,
    clearResponseCache,
    clearSemanticCache,
    compactAgentSession,
    compactFeed,
    compactNativeFeed,
    compactSessionHistory,
    connectorGetCursor,
    connectorIngest,
    connectorUpsertCursor,
    countAgentMemory,
    createArtifact,
    createContextPack,
    createHygieneReport,
    createJob,
    createMemoryAtom,
    createRelation,
    createSnapshot,
    createSource,
    createSpace,
    deleteAgentMemory,
    deleteAgentSession,
    deleteAgentSessionUsage,
    deleteArtifact,
    deleteContextPack,
    deleteEntity,
    deleteMemoryAtom,
    deleteMemoryByKey,
    deletePolicyScope,
    deleteRelation,
    deleteRolloutPolicy,
    deleteSource,
    deleteSpace,
    deleteVectorChunk,
    diagnostics,
    embed,
    embeddingCacheStats,
    evaluateRolloutPolicy,
    exportAnalytics,
    exportFeedCheckpoint,
    exportJsonlDataset,
    exportJsonlSnapshot,
    exportMarkdown,
    exportMarkdownDirectory,
    exportNativeFeedCheckpoint,
    exportSnapshot,
    extractMemory,
    feedStatus,
    forget,
    forgetMemoryByKey,
    getAgentMemory,
    getAgentSessionHistory,
    getArtifact,
    getContextPack,
    getEntity,
    getJob,
    getMemoryAtom,
    getPolicyScope,
    getRelation,
    getResponseCache,
    getRolloutPolicy,
    getSource,
    getSpace,
    graphNeighbors,
    graphPath,
    graphQuery,
    graphSchema,
    health,
    hydrateJsonlDataset,
    hydrateJsonlSnapshot,
    hydrateSnapshot,
    hydrateSnapshotAlias,
    importJsonlDataset,
    importJsonlSnapshot,
    importMarkdown,
    importMarkdownDirectory,
    importNullClawBrainDb,
    importSnapshot,
    ingest,
    lifecycleStats,
    listAgentMemory,
    listAgentSessions,
    listArtifactTypes,
    listArtifacts,
    listConflicts,
    listConnectors,
    listContextPacks,
    listEngines,
    listEntities,
    listFeed,
    listFeedEvents,
    listJobs,
    listMemoryAtoms,
    listNativeFeed,
    listNativeFeedEvents,
    listPolicyScopes,
    listProviders,
    listRelations,
    listRolloutPolicies,
    listSources,
    listSpaces,
    loadAgentSessionMessages,
    loadAgentSessionUsage,
    lucidProjectionStatus,
    markStale,
    memoryCount,
    memoryContextBlock,
    memoryCurated,
    memoryDelete,
    memoryDrainOutbox,
    memoryExportJsonl,
    memoryForget,
    memoryGet,
    memoryHygiene,
    memoryHygieneReport,
    memoryList,
    memoryPrefetch,
    memoryProviderConfigSchema,
    memoryProviderGet,
    memoryProviderTools,
    memoryProvidersList,
    memoryRecallSignals,
    memoryReindex,
    memorySearch,
    memorySessionSearch,
    memoryStats,
    memoryStore,
    memoryToolCall,
    memoryToolsList,
    memoryUpdate,
    migrateLifecycleStorage,
    nativeFeedStatus,
    nullClawAgentApiApplyFeedEvent,
    nullClawAgentApiClearAutoSaved,
    nullClawAgentApiClearSessionMessages,
    nullClawAgentApiCompactSession,
    nullClawAgentApiCountMemories,
    nullClawAgentApiDeleteMemory,
    nullClawAgentApiDeleteSession,
    nullClawAgentApiDeleteSessionUsage,
    nullClawAgentApiExportCheckpoint,
    nullClawAgentApiFeed,
    nullClawAgentApiFeedCompact,
    nullClawAgentApiFeedEvents,
    nullClawAgentApiFeedStatus,
    nullClawAgentApiGetMemory,
    nullClawAgentApiHealth,
    nullClawAgentApiListHistory,
    nullClawAgentApiListMemories,
    nullClawAgentApiListSessions,
    nullClawAgentApiLoadSessionMessages,
    nullClawAgentApiLoadSessionUsage,
    nullClawAgentApiMemoryDrainOutbox,
    nullClawAgentApiMemoryReindex,
    nullClawAgentApiMemoryStats,
    nullClawAgentApiPostMemory,
    nullClawAgentApiPutMemory,
    nullClawAgentApiRestoreCheckpoint,
    nullClawAgentApiSaveSessionMessage,
    nullClawAgentApiSaveSessionUsage,
    nullClawAgentApiSearchMemories,
    nullClawAgentApiShowHistory,
    nullClawAgentApiTerminateSession,
    nullClawApiClearAutoSaved,
    nullClawApiClearSessionMessages,
    nullClawApiCompactSession,
    nullClawApiCountMemories,
    nullClawApiDeleteMemory,
    nullClawApiDeleteSessionUsage,
    nullClawApiGetMemory,
    nullClawApiGetSessionHistory,
    nullClawApiListHistory,
    nullClawApiListMemories,
    nullClawApiListSessions,
    nullClawApiLoadSessionMessages,
    nullClawApiLoadSessionUsage,
    nullClawApiMemoryParity,
    nullClawApiPostMemory,
    nullClawApiPutMemory,
    nullClawApiSaveSessionMessage,
    nullClawApiSaveSessionUsage,
    nullClawApiSearchMemories,
    nullClawApiShowHistory,
    nullClawApiTerminateSession,
    nullClawMemoryParity,
    openApiDocument,
    openApiDocumentAlias,
    patchArtifact,
    patchContextPack,
    patchEntity,
    patchMemoryAtom,
    patchPolicyScope,
    patchRelation,
    patchRolloutPolicy,
    patchSource,
    patchSpace,
    postAgentMemoryByKey,
    postArtifact,
    postContextPack,
    postEmbeddingCacheStats,
    postEntity,
    postMemoryAtom,
    postMemoryDeleteByKey,
    postMemoryForgetByKey,
    postMemoryStoreByKey,
    postMemoryUpdateByKey,
    postResponseCacheStats,
    postRolloutPolicy,
    postSemanticCacheStats,
    postSource,
    putAgentMemory,
    putAgentMemoryByKey,
    putArtifact,
    putContextPack,
    putEntity,
    putMemoryAtom,
    putMemoryStoreByKey,
    putMemoryUpdateByKey,
    putRelation,
    putResponseCache,
    putRolloutPolicy,
    putSemanticCache,
    putSource,
    qmdExportAgentSessions,
    qmdPruneAgentSessionExports,
    queryAnalytics,
    rebuildLucidProjection,
    rebuildVectorIndex,
    reconcileVectorIndex,
    remember,
    resolveEntity,
    responseCacheStats,
    restoreFeedCheckpoint,
    restoreNativeFeedCheckpoint,
    retrievalPlan,
    retrievalSearch,
    rollout,
    runHygiene,
    runJob,
    runVectorOutbox,
    runWorkers,
    saveAgentSessionMessage,
    saveAgentSessionUsage,
    scanConflicts,
    sdkManifest,
    search,
    searchAgentMemory,
    searchSemanticCache,
    semanticCacheStats,
    summarize,
    supersede,
    terminateAgentSession,
    upsertPolicyScope,
    upsertRolloutPolicy,
    upsertVectorChunk,
    vectorOutboxStatus,
    vectorSearch,
    vectorStatus,
    verify,
};

pub fn operationId(operation: Operation) []const u8 {
    return @tagName(operation);
}

pub const OpenApiContract = enum {
    ok,
    agent_memory_count,
    agent_memory_delete,
    agent_memory_entry,
    agent_memory_list,
    agent_memory_search,
    agent_memory_store,
    artifact_create,
    context_pack_create,
    memory_atom_create,
    search,
    source_create,
    summarize,
};

pub fn operationOpenApiContract(operation: Operation) OpenApiContract {
    return switch (operation) {
        .listAgentMemory => .agent_memory_list,
        .getAgentMemory => .agent_memory_entry,
        .putAgentMemory, .putAgentMemoryByKey, .postAgentMemoryByKey => .agent_memory_store,
        .searchAgentMemory => .agent_memory_search,
        .countAgentMemory => .agent_memory_count,
        .deleteAgentMemory => .agent_memory_delete,
        .createSource => .source_create,
        .createArtifact => .artifact_create,
        .createMemoryAtom => .memory_atom_create,
        .search => .search,
        .createContextPack => .context_pack_create,
        .summarize => .summarize,
        else => .ok,
    };
}

pub const HttpMethod = enum {
    get,
    post,
    put,
    patch,
    delete,

    pub fn fromName(name: []const u8) ?HttpMethod {
        if (std.ascii.eqlIgnoreCase(name, "GET")) return .get;
        if (std.ascii.eqlIgnoreCase(name, "POST")) return .post;
        if (std.ascii.eqlIgnoreCase(name, "PUT")) return .put;
        if (std.ascii.eqlIgnoreCase(name, "PATCH")) return .patch;
        if (std.ascii.eqlIgnoreCase(name, "DELETE")) return .delete;
        return null;
    }

    pub fn wireName(self: HttpMethod) []const u8 {
        return switch (self) {
            .get => "GET",
            .post => "POST",
            .put => "PUT",
            .patch => "PATCH",
            .delete => "DELETE",
        };
    }

    pub fn openApiName(self: HttpMethod) []const u8 {
        return switch (self) {
            .get => "get",
            .post => "post",
            .put => "put",
            .patch => "patch",
            .delete => "delete",
        };
    }
};

pub const http_methods = [_]HttpMethod{ .get, .post, .put, .patch, .delete };

pub const RouteDescriptor = struct {
    path: []const u8,
    get: ?Operation = null,
    post: ?Operation = null,
    put: ?Operation = null,
    patch: ?Operation = null,
    delete: ?Operation = null,

    pub fn operationFor(self: RouteDescriptor, method: HttpMethod) ?Operation {
        return switch (method) {
            .get => self.get,
            .post => self.post,
            .put => self.put,
            .patch => self.patch,
            .delete => self.delete,
        };
    }

    pub fn operationForMethod(self: RouteDescriptor, method: []const u8) ?Operation {
        return self.operationFor(HttpMethod.fromName(method) orelse return null);
    }

    fn hasAnyOperation(self: RouteDescriptor) bool {
        for (http_methods) |method| {
            if (self.operationFor(method) != null) return true;
        }
        return false;
    }
};

pub const RouteMatch = union(enum) {
    operation: Operation,
    method_not_allowed,
    not_found,
};

/// Canonical route surface; dispatch, OpenAPI, and SDK manifest all consume this catalog.
pub const routes = [_]RouteDescriptor{
    .{ .path = "/health", .get = .health },
    .{ .path = "/openapi", .get = .openApiDocumentAlias },
    .{ .path = "/openapi.json", .get = .openApiDocument },
    .{ .path = "/capabilities", .get = .capabilities },
    .{ .path = "/engines", .get = .listEngines },
    .{ .path = "/memory/parity", .get = .nullClawMemoryParity },
    .{ .path = "/memory/tools", .get = .memoryToolsList },
    .{ .path = "/memory/providers", .get = .memoryProvidersList },
    .{ .path = "/memory/providers/{name}", .get = .memoryProviderGet },
    .{ .path = "/memory/providers/{name}/tools", .get = .memoryProviderTools },
    .{ .path = "/memory/providers/{name}/config-schema", .get = .memoryProviderConfigSchema },
    .{ .path = "/memory/tools/call", .post = .memoryToolCall },
    .{ .path = "/memory/context-block", .post = .memoryContextBlock },
    .{ .path = "/memory/prefetch", .post = .memoryPrefetch },
    .{ .path = "/memory/curated", .post = .memoryCurated },
    .{ .path = "/memory/session-search", .post = .memorySessionSearch },
    .{ .path = "/agent/memory/parity", .get = .nullClawApiMemoryParity },
    .{ .path = "/providers", .get = .listProviders },
    .{ .path = "/connectors", .get = .listConnectors },
    .{ .path = "/connectors/{name}/cursor", .get = .connectorGetCursor, .post = .connectorUpsertCursor },
    .{ .path = "/connectors/{name}/ingest", .post = .connectorIngest },
    .{ .path = "/connectors/qmd/export-sessions", .post = .qmdExportAgentSessions },
    .{ .path = "/connectors/qmd/prune-sessions", .post = .qmdPruneAgentSessionExports },
    .{ .path = "/markdown/import", .post = .importMarkdown },
    .{ .path = "/markdown/import-directory", .post = .importMarkdownDirectory },
    .{ .path = "/markdown/export", .post = .exportMarkdown },
    .{ .path = "/markdown/export-directory", .post = .exportMarkdownDirectory },
    .{ .path = "/bootstrap/prompts", .get = .bootstrapPromptsList },
    .{ .path = "/bootstrap/prompts/fingerprint", .get = .bootstrapPromptsFingerprint },
    .{ .path = "/bootstrap/prompts/import-directory", .post = .bootstrapPromptsImportDirectory },
    .{ .path = "/bootstrap/prompts/reset", .post = .bootstrapPromptsReset },
    .{ .path = "/bootstrap/prompts/{filename}/exists", .get = .bootstrapPromptExists },
    .{ .path = "/bootstrap/prompts/{filename}", .get = .bootstrapPromptGet, .put = .bootstrapPromptPut, .post = .bootstrapPromptPost, .delete = .bootstrapPromptDelete },
    .{ .path = "/artifact-types", .get = .listArtifactTypes },
    .{ .path = "/sdk/manifest", .get = .sdkManifest },
    .{ .path = "/spaces", .get = .listSpaces, .post = .createSpace },
    .{ .path = "/spaces/{id}", .get = .getSpace, .patch = .patchSpace, .delete = .deleteSpace },
    .{ .path = "/policy-scopes", .get = .listPolicyScopes, .post = .upsertPolicyScope },
    .{ .path = "/policy-scopes/{scope}", .get = .getPolicyScope, .patch = .patchPolicyScope, .delete = .deletePolicyScope },
    .{ .path = "/rollout-policies", .get = .listRolloutPolicies, .post = .upsertRolloutPolicy },
    .{ .path = "/rollout-policies/{name}", .get = .getRolloutPolicy, .put = .putRolloutPolicy, .post = .postRolloutPolicy, .patch = .patchRolloutPolicy, .delete = .deleteRolloutPolicy },
    .{ .path = "/rollout-policies/{name}/evaluate", .post = .evaluateRolloutPolicy },
    .{ .path = "/agent-memory", .get = .listAgentMemory, .post = .putAgentMemory },
    .{ .path = "/agent-memory/{key}", .get = .getAgentMemory, .put = .putAgentMemoryByKey, .post = .postAgentMemoryByKey, .delete = .deleteAgentMemory },
    .{ .path = "/agent-memory/search", .post = .searchAgentMemory },
    .{ .path = "/agent-memory/count", .get = .countAgentMemory },
    .{ .path = "/agent-sessions", .get = .listAgentSessions },
    .{ .path = "/agent-sessions/{id}", .get = .getAgentSessionHistory, .delete = .deleteAgentSession },
    .{ .path = "/agent-sessions/{id}/terminate", .post = .terminateAgentSession },
    .{ .path = "/agent-sessions/{id}/compact", .post = .compactAgentSession },
    .{ .path = "/agent-sessions/{id}/messages", .get = .loadAgentSessionMessages, .post = .saveAgentSessionMessage, .delete = .clearAgentSessionMessages },
    .{ .path = "/agent-sessions/{id}/usage", .get = .loadAgentSessionUsage, .put = .saveAgentSessionUsage, .delete = .deleteAgentSessionUsage },
    .{ .path = "/agent-sessions/auto-saved", .delete = .clearAgentAutoSavedMessages },
    .{ .path = "/agent/health", .get = .nullClawAgentApiHealth },
    .{ .path = "/agent/memories", .get = .nullClawAgentApiListMemories },
    .{ .path = "/agent/memories/{key}", .get = .nullClawAgentApiGetMemory, .put = .nullClawAgentApiPutMemory, .post = .nullClawAgentApiPostMemory, .delete = .nullClawAgentApiDeleteMemory },
    .{ .path = "/agent/memories/search", .post = .nullClawAgentApiSearchMemories },
    .{ .path = "/agent/memories/count", .get = .nullClawAgentApiCountMemories },
    .{ .path = "/agent/sessions", .get = .nullClawAgentApiListSessions },
    .{ .path = "/agent/sessions/{id}", .delete = .nullClawAgentApiDeleteSession },
    .{ .path = "/agent/sessions/{id}/terminate", .post = .nullClawAgentApiTerminateSession },
    .{ .path = "/agent/sessions/{id}/compact", .post = .nullClawAgentApiCompactSession },
    .{ .path = "/agent/sessions/{id}/messages", .get = .nullClawAgentApiLoadSessionMessages, .post = .nullClawAgentApiSaveSessionMessage, .delete = .nullClawAgentApiClearSessionMessages },
    .{ .path = "/agent/sessions/{id}/usage", .get = .nullClawAgentApiLoadSessionUsage, .put = .nullClawAgentApiSaveSessionUsage, .delete = .nullClawAgentApiDeleteSessionUsage },
    .{ .path = "/agent/sessions/auto-saved", .delete = .nullClawAgentApiClearAutoSaved },
    .{ .path = "/agent/history", .get = .nullClawAgentApiListHistory },
    .{ .path = "/agent/history/{id}", .get = .nullClawAgentApiShowHistory },
    .{ .path = "/agent/memory/feed", .get = .nullClawAgentApiFeed },
    .{ .path = "/agent/memory/events", .get = .nullClawAgentApiFeedEvents },
    .{ .path = "/agent/memory/status", .get = .nullClawAgentApiFeedStatus },
    .{ .path = "/agent/memory/stats", .get = .nullClawAgentApiMemoryStats },
    .{ .path = "/agent/memory/reindex", .post = .nullClawAgentApiMemoryReindex },
    .{ .path = "/agent/memory/drain-outbox", .post = .nullClawAgentApiMemoryDrainOutbox },
    .{ .path = "/agent/memory/compact", .post = .nullClawAgentApiFeedCompact },
    .{ .path = "/agent/memory/checkpoint", .get = .nullClawAgentApiExportCheckpoint, .post = .nullClawAgentApiRestoreCheckpoint },
    .{ .path = "/agent/memory/apply", .post = .nullClawAgentApiApplyFeedEvent },
    .{ .path = "/memories", .get = .nullClawApiListMemories },
    .{ .path = "/memories/{key}", .get = .nullClawApiGetMemory, .put = .nullClawApiPutMemory, .post = .nullClawApiPostMemory, .delete = .nullClawApiDeleteMemory },
    .{ .path = "/memories/search", .post = .nullClawApiSearchMemories },
    .{ .path = "/memories/count", .get = .nullClawApiCountMemories },
    .{ .path = "/sessions", .get = .nullClawApiListSessions },
    .{ .path = "/sessions/{id}", .get = .nullClawApiGetSessionHistory, .delete = .nullClawApiTerminateSession },
    .{ .path = "/sessions/{id}/compact", .post = .nullClawApiCompactSession },
    .{ .path = "/sessions/{id}/messages", .get = .nullClawApiLoadSessionMessages, .post = .nullClawApiSaveSessionMessage, .delete = .nullClawApiClearSessionMessages },
    .{ .path = "/sessions/{id}/usage", .get = .nullClawApiLoadSessionUsage, .put = .nullClawApiSaveSessionUsage, .delete = .nullClawApiDeleteSessionUsage },
    .{ .path = "/sessions/auto-saved", .delete = .nullClawApiClearAutoSaved },
    .{ .path = "/history", .get = .nullClawApiListHistory },
    .{ .path = "/history/{id}", .get = .nullClawApiShowHistory },
    .{ .path = "/sources", .get = .listSources, .post = .createSource },
    .{ .path = "/sources/{id}", .get = .getSource, .put = .putSource, .post = .postSource, .patch = .patchSource, .delete = .deleteSource },
    .{ .path = "/artifacts", .get = .listArtifacts, .post = .createArtifact },
    .{ .path = "/artifacts/{id}", .get = .getArtifact, .put = .putArtifact, .post = .postArtifact, .patch = .patchArtifact, .delete = .deleteArtifact },
    .{ .path = "/memory-atoms", .get = .listMemoryAtoms, .post = .createMemoryAtom },
    .{ .path = "/memory-atoms/{id}", .get = .getMemoryAtom, .put = .putMemoryAtom, .post = .postMemoryAtom, .patch = .patchMemoryAtom, .delete = .deleteMemoryAtom },
    .{ .path = "/entities/resolve", .post = .resolveEntity },
    .{ .path = "/entities", .get = .listEntities },
    .{ .path = "/entities/{id}", .get = .getEntity, .put = .putEntity, .post = .postEntity, .patch = .patchEntity, .delete = .deleteEntity },
    .{ .path = "/relations", .get = .listRelations, .post = .createRelation },
    .{ .path = "/relations/{id}", .get = .getRelation, .put = .putRelation, .patch = .patchRelation, .delete = .deleteRelation },
    .{ .path = "/graph/schema", .get = .graphSchema },
    .{ .path = "/graph/query", .post = .graphQuery },
    .{ .path = "/graph/neighbors", .post = .graphNeighbors },
    .{ .path = "/graph/path", .post = .graphPath },
    .{ .path = "/ingest", .post = .ingest },
    .{ .path = "/extract-memory", .post = .extractMemory },
    .{ .path = "/search", .post = .search },
    .{ .path = "/ask", .post = .ask },
    .{ .path = "/context-packs", .get = .listContextPacks, .post = .createContextPack },
    .{ .path = "/context-packs/{id}", .get = .getContextPack, .put = .putContextPack, .post = .postContextPack, .patch = .patchContextPack, .delete = .deleteContextPack },
    .{ .path = "/remember", .post = .remember },
    .{ .path = "/forget", .post = .forget },
    .{ .path = "/verify", .post = .verify },
    .{ .path = "/mark-stale", .post = .markStale },
    .{ .path = "/supersede", .post = .supersede },
    .{ .path = "/jobs", .get = .listJobs, .post = .createJob },
    .{ .path = "/jobs/{id}", .get = .getJob },
    .{ .path = "/jobs/{id}/run", .post = .runJob },
    .{ .path = "/workers/run", .post = .runWorkers },
    .{ .path = "/feed", .get = .listNativeFeed, .post = .appendNativeFeed },
    .{ .path = "/feed/events", .get = .listNativeFeedEvents, .post = .appendNativeFeedEvent },
    .{ .path = "/feed/status", .get = .nativeFeedStatus },
    .{ .path = "/feed/compact", .post = .compactNativeFeed },
    .{ .path = "/feed/checkpoint", .get = .exportNativeFeedCheckpoint, .post = .restoreNativeFeedCheckpoint },
    .{ .path = "/feed/apply", .post = .applyNativeFeedEvent },
    .{ .path = "/memory/feed", .get = .listFeed, .post = .appendFeed },
    .{ .path = "/memory/events", .get = .listFeedEvents, .post = .appendFeedEvent },
    .{ .path = "/memory/status", .get = .feedStatus },
    .{ .path = "/memory/stats", .get = .memoryStats },
    .{ .path = "/memory/recall-signals", .get = .memoryRecallSignals },
    .{ .path = "/memory/count", .get = .memoryCount },
    .{ .path = "/memory/list", .get = .memoryList },
    .{ .path = "/memory/search", .post = .memorySearch },
    .{ .path = "/memory/get/{key}", .get = .memoryGet },
    .{ .path = "/memory/store", .post = .memoryStore },
    .{ .path = "/memory/store/{key}", .put = .putMemoryStoreByKey, .post = .postMemoryStoreByKey },
    .{ .path = "/memory/update", .post = .memoryUpdate },
    .{ .path = "/memory/update/{key}", .put = .putMemoryUpdateByKey, .post = .postMemoryUpdateByKey },
    .{ .path = "/memory/delete", .post = .memoryDelete },
    .{ .path = "/memory/delete/{key}", .delete = .deleteMemoryByKey, .post = .postMemoryDeleteByKey },
    .{ .path = "/memory/forget", .post = .memoryForget },
    .{ .path = "/memory/forget/{key}", .delete = .forgetMemoryByKey, .post = .postMemoryForgetByKey },
    .{ .path = "/memory/export-jsonl", .post = .memoryExportJsonl },
    .{ .path = "/memory/hygiene", .post = .memoryHygiene },
    .{ .path = "/memory/hygiene-report", .post = .memoryHygieneReport },
    .{ .path = "/memory/reindex", .post = .memoryReindex },
    .{ .path = "/memory/drain-outbox", .post = .memoryDrainOutbox },
    .{ .path = "/memory/compact", .post = .compactFeed },
    .{ .path = "/memory/checkpoint", .get = .exportFeedCheckpoint, .post = .restoreFeedCheckpoint },
    .{ .path = "/memory/apply", .post = .applyFeedEvent },
    .{ .path = "/vector/status", .get = .vectorStatus },
    .{ .path = "/vector/embed", .post = .embed },
    .{ .path = "/vector/upsert", .post = .upsertVectorChunk },
    .{ .path = "/vector/search", .post = .vectorSearch },
    .{ .path = "/vector/delete", .post = .deleteVectorChunk },
    .{ .path = "/vector/rebuild", .post = .rebuildVectorIndex },
    .{ .path = "/vector/reconcile", .post = .reconcileVectorIndex },
    .{ .path = "/vector/outbox", .get = .vectorOutboxStatus },
    .{ .path = "/vector/outbox/run", .post = .runVectorOutbox },
    .{ .path = "/retrieval/plan", .post = .retrievalPlan },
    .{ .path = "/retrieval/search", .post = .retrievalSearch },
    .{ .path = "/conflicts", .get = .listConflicts },
    .{ .path = "/conflicts/scan", .post = .scanConflicts },
    .{ .path = "/lifecycle/diagnostics", .get = .diagnostics },
    .{ .path = "/lifecycle/stats", .get = .lifecycleStats },
    .{ .path = "/lifecycle/migrate", .post = .migrateLifecycleStorage },
    .{ .path = "/lifecycle/import-brain-db", .post = .importNullClawBrainDb },
    .{ .path = "/lifecycle/export-jsonl", .post = .exportJsonlDataset },
    .{ .path = "/lifecycle/import-jsonl", .post = .importJsonlDataset },
    .{ .path = "/lifecycle/hydrate-jsonl", .post = .hydrateJsonlDataset },
    .{ .path = "/lifecycle/snapshot", .post = .createSnapshot },
    .{ .path = "/lifecycle/snapshot/export", .post = .exportSnapshot },
    .{ .path = "/lifecycle/snapshot/export-jsonl", .post = .exportJsonlSnapshot },
    .{ .path = "/lifecycle/snapshot/import-jsonl", .post = .importJsonlSnapshot },
    .{ .path = "/lifecycle/snapshot/hydrate-jsonl", .post = .hydrateJsonlSnapshot },
    .{ .path = "/lifecycle/snapshot/import", .post = .importSnapshot },
    .{ .path = "/lifecycle/snapshot/hydrate", .post = .hydrateSnapshot },
    .{ .path = "/lifecycle/hydrate", .post = .hydrateSnapshotAlias },
    .{ .path = "/lifecycle/lucid/status", .get = .lucidProjectionStatus },
    .{ .path = "/lifecycle/lucid/rebuild", .post = .rebuildLucidProjection },
    .{ .path = "/lifecycle/analytics/status", .get = .analyticsStatus },
    .{ .path = "/lifecycle/analytics/query", .post = .queryAnalytics },
    .{ .path = "/lifecycle/analytics/export", .post = .exportAnalytics },
    .{ .path = "/lifecycle/cache/put", .post = .putResponseCache },
    .{ .path = "/lifecycle/cache/get", .post = .getResponseCache },
    .{ .path = "/lifecycle/cache/stats", .get = .responseCacheStats, .post = .postResponseCacheStats },
    .{ .path = "/lifecycle/cache/clear", .post = .clearResponseCache },
    .{ .path = "/lifecycle/semantic-cache/put", .post = .putSemanticCache },
    .{ .path = "/lifecycle/semantic-cache/search", .post = .searchSemanticCache },
    .{ .path = "/lifecycle/semantic-cache/stats", .get = .semanticCacheStats, .post = .postSemanticCacheStats },
    .{ .path = "/lifecycle/semantic-cache/clear", .post = .clearSemanticCache },
    .{ .path = "/lifecycle/embedding-cache/stats", .get = .embeddingCacheStats, .post = .postEmbeddingCacheStats },
    .{ .path = "/lifecycle/embedding-cache/clear", .post = .clearEmbeddingCache },
    .{ .path = "/lifecycle/hygiene-report", .post = .createHygieneReport },
    .{ .path = "/lifecycle/hygiene", .post = .runHygiene },
    .{ .path = "/lifecycle/summarize", .post = .summarize },
    .{ .path = "/lifecycle/compact-session", .post = .compactSessionHistory },
    .{ .path = "/lifecycle/rollout", .post = .rollout },
};

pub const OpenApiPath = RouteDescriptor;
pub const openapi_paths = routes;

pub fn matchRequest(method: []const u8, target_path: []const u8) RouteMatch {
    const path = stripV1Prefix(target_path) orelse target_path;
    var path_known = false;
    var best_route: ?RouteDescriptor = null;
    var best_score: usize = 0;
    for (routes) |route| {
        if (!templateMatches(route.path, path)) continue;
        path_known = true;
        const score = templateSpecificity(route.path);
        if (best_route == null or score > best_score) {
            best_route = route;
            best_score = score;
        }
    }
    if (best_route) |route| {
        if (route.operationForMethod(method)) |operation| return .{ .operation = operation };
    }
    return if (path_known) .method_not_allowed else .not_found;
}

fn stripV1Prefix(path: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, path, "/v1")) return "/";
    if (std.mem.startsWith(u8, path, "/v1/")) return path[3..];
    return null;
}

fn templateMatches(template: []const u8, path: []const u8) bool {
    var template_it = std.mem.splitScalar(u8, template, '/');
    var path_it = std.mem.splitScalar(u8, path, '/');
    while (true) {
        const template_segment = nextNonEmpty(&template_it);
        const path_segment = nextNonEmpty(&path_it);
        if (template_segment == null or path_segment == null) return template_segment == null and path_segment == null;
        const expected = template_segment.?;
        const actual = path_segment.?;
        if (isParameter(expected)) {
            if (actual.len == 0) return false;
            continue;
        }
        if (!std.mem.eql(u8, expected, actual)) return false;
    }
}

fn nextNonEmpty(iter: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (iter.next()) |part| {
        if (part.len != 0) return part;
    }
    return null;
}

fn isParameter(segment: []const u8) bool {
    return segment.len >= 2 and segment[0] == '{' and segment[segment.len - 1] == '}';
}

fn templateSpecificity(template: []const u8) usize {
    var score: usize = 0;
    var it = std.mem.splitScalar(u8, template, '/');
    while (nextNonEmpty(&it)) |segment| {
        if (isParameter(segment)) {
            score += 1;
        } else {
            score += 16 + segment.len;
        }
    }
    return score;
}

fn duplicateOperationId(operation: Operation, route_index: usize, method_index: usize) bool {
    for (routes[route_index..], route_index..) |route, i| {
        const start_method = if (i == route_index) method_index + 1 else 0;
        for (http_methods[start_method..]) |method| {
            const candidate = route.operationFor(method);
            if (candidate != null and operation == candidate.?) return true;
        }
    }
    return false;
}

test "API route catalog has unique paths and operation ids" {
    for (routes, 0..) |route, i| {
        try std.testing.expect(route.path.len > 0);
        try std.testing.expect(route.path[0] == '/');
        try std.testing.expect(route.hasAnyOperation());
        for (routes[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, route.path, other.path));
        }
        for (http_methods, 0..) |method, method_index| {
            const operation = route.operationFor(method);
            if (operation) |id| {
                try std.testing.expect(!duplicateOperationId(id, i, method_index));
            }
        }
    }
}

test "API route catalog matches templated v1 requests" {
    try std.testing.expectEqual(Operation.getSpace, switch (matchRequest("GET", "/v1/spaces/space-a")) {
        .operation => |id| id,
        else => return error.TestExpectedEqual,
    });
    try std.testing.expectEqual(Operation.searchAgentMemory, switch (matchRequest("POST", "/v1/agent-memory/search")) {
        .operation => |id| id,
        else => return error.TestExpectedEqual,
    });
    try std.testing.expectEqual(Operation.countAgentMemory, switch (matchRequest("GET", "/v1/agent-memory/count")) {
        .operation => |id| id,
        else => return error.TestExpectedEqual,
    });
    try std.testing.expectEqual(Operation.bootstrapPromptGet, switch (matchRequest("GET", "/v1/bootstrap/prompts/AGENTS.md")) {
        .operation => |id| id,
        else => return error.TestExpectedEqual,
    });
    try std.testing.expectEqual(Operation.bootstrapPromptExists, switch (matchRequest("GET", "/v1/bootstrap/prompts/AGENTS.md/exists")) {
        .operation => |id| id,
        else => return error.TestExpectedEqual,
    });
    try std.testing.expectEqual(Operation.saveAgentSessionMessage, switch (matchRequest("POST", "/v1/agent-sessions/session-a/messages")) {
        .operation => |id| id,
        else => return error.TestExpectedEqual,
    });
    try std.testing.expectEqual(Operation.putSource, switch (matchRequest("PUT", "/v1/sources/source-a")) {
        .operation => |id| id,
        else => return error.TestExpectedEqual,
    });
    try std.testing.expectEqual(Operation.postArtifact, switch (matchRequest("POST", "/v1/artifacts/artifact-a")) {
        .operation => |id| id,
        else => return error.TestExpectedEqual,
    });
    try std.testing.expectEqual(Operation.hydrateJsonlSnapshot, switch (matchRequest("POST", "/v1/lifecycle/snapshot/hydrate-jsonl")) {
        .operation => |id| id,
        else => return error.TestExpectedEqual,
    });
    try std.testing.expectEqual(RouteMatch.method_not_allowed, matchRequest("POST", "/v1/health"));
    try std.testing.expectEqual(RouteMatch.not_found, matchRequest("GET", "/v1/does-not-exist"));
}

fn exampleV1PathForTemplate(allocator: std.mem.Allocator, template: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "/v1");

    var index: usize = 0;
    while (index < template.len) {
        if (template[index] == '{') {
            const close_relative = std.mem.indexOfScalar(u8, template[index..], '}') orelse return error.InvalidRouteTemplate;
            try out.appendSlice(allocator, "sample");
            index += close_relative + 1;
            continue;
        }
        try out.append(allocator, template[index]);
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "API route catalog dispatches every declared operation" {
    for (routes) |route| {
        const path = try exampleV1PathForTemplate(std.testing.allocator, route.path);
        defer std.testing.allocator.free(path);

        for (http_methods) |method| {
            const expected = route.operationFor(method) orelse continue;
            try std.testing.expectEqual(expected, switch (matchRequest(method.wireName(), path)) {
                .operation => |operation| operation,
                else => return error.TestExpectedEqual,
            });
        }
    }
}
