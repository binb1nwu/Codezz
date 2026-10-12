import 'dart:async';
import 'dart:typed_data';

import '../rpc/channel_client.dart';
import 'server_info.dart';

/// Typed facade over the ZCode services exposed on `/ws`
/// (`IZCodeAgentService`, `IZCodeTaskService`, `IModelSelectionService`,
/// `IUsageStatsService`, `IGitService`, `ITerminalService`, `IFileService`,
/// `IPluginManagementService`).
///
/// Method names and parameter shapes follow `packages/services` in ZCode;
/// every service method takes its arguments as a list.
class ZCodeApi {
  ZCodeApi(this.client, {required this.clientId, required this.appVersion});

  final ChannelClient client;
  final String clientId;
  final String appVersion;

  static const agent = 'zcode-agent';
  static const task = 'zcode-task';
  static const modelSelection = 'model-selection';
  static const usageStats = 'usage-stats';
  static const git = 'git';
  static const terminal = 'terminal';
  static const file = 'file';
  static const pluginManagement = 'plugin-management';

  static const _rpcTimeout = Duration(seconds: 30);

  static final Expando<Future<Map<String, dynamic>>> _handshakes = Expando();

  Future<T> _call<T>(String channel, String method, [List<Object?> args = const []]) =>
      client.call<T>(channel, method, args, _rpcTimeout);

  // ── V4 connection handshake ──

  /// `hello` + `clientHello`, once per connection (see
  /// `agentV4ConnectionHandshake.ts`).
  Future<Map<String, dynamic>> ensureHandshake() {
    return _handshakes[client] ??= () async {
      final hello = Map<String, dynamic>.from(
          await _call<Map>(agent, 'helloConversationV4'));
      await _call<Object?>(agent, 'initializeConversationV4', [
        {
          'kind': 'clientHello',
          'protocolVersion': hello['protocolVersion'] ?? 3,
          'clientId': clientId,
          'clientKind': 'mobileApp',
          'appVersion': appVersion,
        }
      ]);
      return hello;
    }()
      ..catchError((Object _) {
        _handshakes[client] = null;
        return <String, dynamic>{};
      });
  }

  // ── conversation topic ──

  Future<Map<String, dynamic>> subscribeConversation(
    WorkspaceRef ws,
    String sessionId, {
    Map<String, Object?>? base,
  }) async {
    await ensureHandshake();
    final res = await _call<Map>(agent, 'subscribeConversationV4', [
      {
        ...ws.target,
        'sessionId': sessionId,
        if (base != null) 'base': base,
        'visibility': 'foreground',
      }
    ]);
    return Map<String, dynamic>.from(res['ack'] as Map);
  }

  Future<Map<String, dynamic>> resyncConversation(
    WorkspaceRef ws,
    String subscriptionId, {
    Map<String, Object?>? base,
    bool forceSnapshot = false,
  }) async {
    await ensureHandshake();
    final res = await _call<Map>(agent, 'resyncConversationV4', [
      {
        ...ws.target,
        'subscriptionId': subscriptionId,
        'base': base,
        if (forceSnapshot) 'forceSnapshot': true,
      }
    ]);
    return Map<String, dynamic>.from(res['ack'] as Map);
  }

  Future<void> unsubscribeConversation(WorkspaceRef ws, String subscriptionId) =>
      _call<Object?>(agent, 'unsubscribeConversationV4', [
        {...ws.target, 'subscriptionId': subscriptionId}
      ]);

  /// Older rows (`rowId < beforeRowId`), ascending.
  Future<Map<String, dynamic>> rowsRange(
    WorkspaceRef ws,
    String sessionId, {
    int? beforeRowId,
    int limit = 80,
  }) async =>
      Map<String, dynamic>.from(await _call<Map>(agent, 'conversationRowsRangeV4', [
        {
          ...ws.target,
          'sessionId': sessionId,
          if (beforeRowId != null) 'beforeRowId': beforeRowId,
          'limit': limit,
        }
      ]));

  Future<Map<String, dynamic>> fileChanges(WorkspaceRef ws, String sessionId,
          {Map<String, Object?> extra = const {}}) async =>
      Map<String, dynamic>.from(await _call<Map>(agent, 'conversationFileChangesV4', [
        {...ws.target, 'sessionId': sessionId, ...extra}
      ]));

  /// Sends a V4 command envelope and returns its `CommandAck`.
  Future<Map<String, dynamic>> sendCommand(
      WorkspaceRef ws, Map<String, Object?> envelope) async {
    await ensureHandshake();
    return Map<String, dynamic>.from(await client.call<Map>(
      agent,
      'sendConversationCommandV4',
      [
        {...ws.target, 'envelope': envelope}
      ],
      const Duration(seconds: 90),
    ));
  }

  Stream<Map<String, dynamic>> conversationFrames(WorkspaceRef ws) => client
      .listen(agent, 'onDynamicConversationFrame', ws.target)
      .where((e) => e is Map)
      .map((e) => Map<String, dynamic>.from(e as Map));

  // ── sessions-index topic ──

  Future<Map<String, dynamic>> subscribeSessionsIndex(WorkspaceRef ws,
      {Map<String, Object?>? base}) async {
    await ensureHandshake();
    final res = await _call<Map>(agent, 'subscribeSessionsIndexV4', [
      {
        ...ws.target,
        if (base != null) 'base': base,
        'visibility': 'foreground',
      }
    ]);
    return Map<String, dynamic>.from(res['ack'] as Map);
  }

  Future<Map<String, dynamic>> resyncSessionsIndex(
    WorkspaceRef ws,
    String subscriptionId, {
    Map<String, Object?>? base,
    bool forceSnapshot = false,
  }) async {
    final res = await _call<Map>(agent, 'resyncSessionsIndexV4', [
      {
        ...ws.target,
        'subscriptionId': subscriptionId,
        'base': base,
        if (forceSnapshot) 'forceSnapshot': true,
      }
    ]);
    return Map<String, dynamic>.from(res['ack'] as Map);
  }

  Future<void> unsubscribeSessionsIndex(WorkspaceRef ws, String subscriptionId) =>
      _call<Object?>(agent, 'unsubscribeSessionsIndexV4', [
        {...ws.target, 'subscriptionId': subscriptionId}
      ]);

  Stream<Map<String, dynamic>> sessionsIndexFrames(WorkspaceRef ws) => client
      .listen(agent, 'onDynamicSessionsIndexFrame', ws.target)
      .where((e) => e is Map)
      .map((e) => Map<String, dynamic>.from(e as Map));

  /// `{workspaceKey, state: available|unavailable}` agent runtime transitions.
  Stream<Map<String, dynamic>> runtimeLifecycle() => client
      .listen(agent, 'onAgentRuntimeLifecycle')
      .where((e) => e is Map)
      .map((e) => Map<String, dynamic>.from(e as Map));

  // ── tasks-index (persistent list membership) ──

  Future<List<Map<String, dynamic>>> _list(String method, WorkspaceRef ws) async {
    final res = await _call<List>(task, method, [ws.target]);
    return [for (final e in res) if (e is Map) Map<String, dynamic>.from(e)];
  }

  Future<List<Map<String, dynamic>>> listTasks(WorkspaceRef ws) => _list('listTasks', ws);
  Future<List<Map<String, dynamic>>> listPinnedTasks(WorkspaceRef ws) =>
      _list('listPinnedTasks', ws);
  Future<List<Map<String, dynamic>>> listArchivedTasks(WorkspaceRef ws) =>
      _list('listArchivedTasks', ws);

  Future<List<String>> listDeletedTaskIds(WorkspaceRef ws) async {
    final res = await _call<List>(task, 'listDeletedTaskIds', [ws.target]);
    return [for (final e in res) '$e'];
  }

  Future<void> setTaskPinned(WorkspaceRef ws, String taskId, bool pinned) =>
      _call<Object?>(task, 'setTaskPinned', [
        {...ws.target, 'taskId': taskId, 'pinned': pinned}
      ]);

  Future<void> archiveTask(WorkspaceRef ws, String taskId) =>
      _call<Object?>(task, 'archiveTask', [
        {...ws.target, 'taskId': taskId}
      ]);

  Future<void> unarchiveTask(WorkspaceRef ws, String taskId) =>
      _call<Object?>(task, 'unarchiveTask', [
        {...ws.target, 'taskId': taskId}
      ]);

  Future<void> deleteTask(WorkspaceRef ws, String taskId) =>
      _call<Object?>(task, 'deleteTask', [
        {...ws.target, 'taskId': taskId}
      ]);

  Future<void> setTaskUnread(WorkspaceRef ws, String taskId, bool unread) =>
      _call<Object?>(task, 'setTaskUnread', [
        {...ws.target, 'taskId': taskId, 'unread': unread}
      ]);

  /// `workspace_task_list_changed`, `workspace_slash_commands_update`, …
  Stream<Map<String, dynamic>> workspaceEvents(WorkspaceRef ws) => client
      .listen(task, 'onDynamicWorkspaceEvent', ws.target)
      .where((e) => e is Map)
      .map((e) => Map<String, dynamic>.from(e as Map));

  // ── models ──

  Future<Map<String, dynamic>> modelSelectionView() async =>
      Map<String, dynamic>.from(await _call<Map>(modelSelection, 'getView'));

  Stream<Object?> modelSelectionChanges() => client.listen(modelSelection, 'onDidChange');

  // ── attachments (chunked upload into a session) ──

  Map<String, Object?> _upload(WorkspaceRef ws, String sessionId, String uploadId) =>
      {...ws.target, 'sessionId': sessionId, 'uploadId': uploadId};

  /// `{state: staging, nextChunkIndex}`, or `{state: committed, ref}` when
  /// the desktop already has the same content.
  Future<Map<String, dynamic>> attachmentBegin(WorkspaceRef ws, String sessionId, String uploadId,
          {required String fileName,
          required String mime,
          required int totalBytes,
          required int totalChunks,
          required String checksum}) async =>
      Map<String, dynamic>.from(await _call<Map>(agent, 'attachmentBeginV4', [
        {
          ..._upload(ws, sessionId, uploadId),
          'fileName': fileName,
          'mime': mime,
          'totalBytes': totalBytes,
          'totalChunks': totalChunks,
          'checksum': checksum,
        }
      ]));

  /// `{uploadId, nextChunkIndex}`.
  Future<Map<String, dynamic>> attachmentChunk(
          WorkspaceRef ws, String sessionId, String uploadId, int chunkIndex, String dataBase64) async =>
      Map<String, dynamic>.from(await _call<Map>(agent, 'attachmentChunkV4', [
        {..._upload(ws, sessionId, uploadId), 'chunkIndex': chunkIndex, 'dataBase64': dataBase64}
      ]));

  /// `{ref}`.
  Future<Map<String, dynamic>> attachmentCommit(WorkspaceRef ws, String sessionId, String uploadId) async =>
      Map<String, dynamic>.from(
          await _call<Map>(agent, 'attachmentCommitV4', [_upload(ws, sessionId, uploadId)]));

  Future<void> attachmentAbort(WorkspaceRef ws, String sessionId, String uploadId) =>
      _call<Object?>(agent, 'attachmentAbortV4', [_upload(ws, sessionId, uploadId)]);

  // ── composer "add context" sources ──

  /// `[{name, path, relativePath, type: file|directory}]`.
  /// `{content, isBinary, truncated}`: up to [length] bytes of a text file
  /// (ZCode's code viewer reads 256 KB).
  Future<Map<String, dynamic>> readTextFile(String path, {int offset = 0, int length = 262144}) async =>
      Map<String, dynamic>.from(
          await _call<Map>(file, 'readTextFile', [
        {'path': path, 'offset': offset, 'length': length}
      ]));

  /// `{mediaType, dataBase64}` of an image.
  Future<Map<String, dynamic>> readMediaPreview(String path) async =>
      Map<String, dynamic>.from(await _call<Map>(file, 'readMediaPreview', [
        {'path': path}
      ]));

  /// `{type: file|directory, size?}`.
  Future<Map<String, dynamic>> statFile(String path) async =>
      Map<String, dynamic>.from(await _call<Map>(file, 'stat', [
        {'path': path}
      ]));

  /// Raw bytes of `[offset, offset + length)`; empty at the end of the file.
  Future<Uint8List> readFileRange(String path, int offset, int length) async {
    final res = await _call<Object?>(file, 'readFileRange', [
      {'path': path, 'offset': offset, 'length': length}
    ]);
    return switch (res) {
      Uint8List b => b,
      List l => Uint8List.fromList(l.cast<int>()),
      _ => Uint8List(0),
    };
  }

  Future<List<Map<String, dynamic>>> listWorkspaceFiles(WorkspaceRef ws) async {
    final res = await _call<List>(file, 'listWorkspaceFiles', [
      {'rootPath': ws.path}
    ]);
    return [for (final e in res) if (e is Map) Map<String, dynamic>.from(e)];
  }

  /// `{plugins: [{pluginId, name, displayName?, enabled, marketplace,
  /// skillQualifiedNames, mcpServerNames, conflictingPluginIds, …}]}`.
  Future<Map<String, dynamic>> pluginReferenceCatalog(WorkspaceRef ws, {String? sessionId}) async =>
      Map<String, dynamic>.from(await _call<Map>(pluginManagement, 'getPluginReferenceCatalog', [
        {
          'workspacePath': ws.path,
          if (ws.identity?.trim().isNotEmpty ?? false) 'workspaceIdentity': ws.identity,
          if (sessionId != null) 'sessionId': sessionId,
        }
      ]));

  // ── git (side pane review) ──

  /// `{summary, identity, unstagedChanges, stagedChanges, branchComparison}`.
  Future<Map<String, dynamic>> gitRefresh(WorkspaceRef ws) async =>
      Map<String, dynamic>.from(await _call<Map>(git, 'refresh', [
        {'workspacePath': ws.path, 'includeIdentity': true, 'includeBranchComparison': true}
      ]));

  /// `{path, availability: patch|binary|truncated|unavailable, patch,
  /// beforeContent, afterContent}` of one file in [sourceId]
  /// (`unstaged` / `staged` / `branch`).
  Future<Map<String, dynamic>> gitDiff(WorkspaceRef ws, String path, String sourceId) async =>
      Map<String, dynamic>.from(await _call<Map>(git, 'getDiff', [
        {'workspacePath': ws.path, 'path': path, 'sourceId': sourceId}
      ]));

  // ── terminal (one PTY per side-pane tab) ──

  /// `{id, shell, …}` of a new PTY.
  Future<Map<String, dynamic>> terminalCreate({required int cols, required int rows, required String cwd}) async =>
      Map<String, dynamic>.from(await _call<Map>(terminal, 'create', [
        {'cols': cols, 'rows': rows, 'cwd': cwd}
      ]));

  Future<void> terminalWrite(String id, String data) => _call<Object?>(terminal, 'write', [
        {'id': id, 'data': data}
      ]);

  Future<void> terminalResize(String id, int cols, int rows) => _call<Object?>(terminal, 'resize', [
        {'id': id, 'cols': cols, 'rows': rows}
      ]);

  Future<void> terminalDispose(String id) => _call<Object?>(terminal, 'dispose', [
        {'id': id}
      ]);

  Stream<String> terminalData(String id) =>
      client.listen(terminal, 'onDynamicData', id).where((e) => e is String).cast<String>();

  /// Fires once with the exit code.
  Stream<int?> terminalExit(String id) =>
      client.listen(terminal, 'onDynamicExit', id).map((e) => e is num ? e.toInt() : null);

  // ── coding-plan quota ──

  /// Entitlement snapshot (quota limits) of a coding-plan provider, as the
  /// composer's usage card requests it. There is no change event.
  Future<Map<String, dynamic>> entitlementSnapshot(
          String providerId, Map<String, Object?> accountAccess) async =>
      Map<String, dynamic>.from(await client.call<Map>(
        usageStats,
        'getEntitlementSnapshot',
        [
          {
            'includeSubscription': true,
            'preferredProviderId': providerId,
            'accountAccess': accountAccess,
            'allowDisabledPreferredProvider': true,
            'requirePreferredProvider': true,
            'allowEnvApiKey': false,
          }
        ],
        const Duration(seconds: 20),
      ));
}
