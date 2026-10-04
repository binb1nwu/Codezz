/// Describes a ZCode desktop: `/api/server-info` of a ZCode Web server
/// (`ServerRemoteInfo`), or the relay `bootstrap-response`.
class ServerInfo {
  const ServerInfo({
    required this.serverId,
    this.name,
    this.version,
    this.workspaces = const [],
  });

  factory ServerInfo.fromJson(Map<String, dynamic> json) => ServerInfo(
        serverId: '${json['serverId'] ?? ''}',
        name: json['name'] as String?,
        version: json['version'] as String?,
        workspaces: WorkspaceRef.listFrom(json['workspaces']),
      );

  /// `bootstrap-response.result` of the remote-control relay:
  /// `{desktopAppVersion, workspaces: [{workspacePath, workspaceIdentity?,
  /// label, kind, connectionState?}], tasks, windowControlSessionId}`.
  factory ServerInfo.fromBootstrap(Map<String, dynamic> result,
          {required String serverId, String? name}) =>
      ServerInfo(
        serverId: serverId,
        name: name,
        version: result['desktopAppVersion'] as String?,
        workspaces: WorkspaceRef.listFrom(result['workspaces']),
      );

  ServerInfo withWorkspaces(List<WorkspaceRef> workspaces) =>
      ServerInfo(serverId: serverId, name: name, version: version, workspaces: workspaces);

  final String serverId;
  final String? name;
  final String? version;
  final List<WorkspaceRef> workspaces;

  /// Best human readable device name.
  String get displayName => (name?.trim().isNotEmpty ?? false) ? name!.trim() : serverId;
}

class WorkspaceRef {
  const WorkspaceRef({
    required this.path,
    required this.label,
    this.identity,
    this.kind,
    this.remoteSessionId,
    this.connectionState,
  });

  static List<WorkspaceRef> listFrom(Object? raw) => [
        for (final w in (raw is List ? raw : const []))
          if (w is Map && (w['workspacePath'] ?? w['path']) is String)
            WorkspaceRef.fromJson(Map<String, dynamic>.from(w)),
      ];

  factory WorkspaceRef.fromJson(Map<String, dynamic> w) {
    final path = (w['workspacePath'] ?? w['path']) as String;
    return WorkspaceRef(
      path: path,
      label: (w['label'] as String?) ?? _basename(path),
      identity: w['workspaceIdentity'] as String?,
      kind: w['kind'] as String?,
      remoteSessionId: w['remoteSessionId'] as String?,
      connectionState: w['connectionState'] as String?,
    );
  }

  final String path;
  final String label;
  final String? identity;

  /// `local` or `remote` (SSH / WSL workspaces) when known.
  final String? kind;

  /// Remote only: the desktop's live session with the remote host.
  final String? remoteSessionId;

  /// Remote only: `connected`, `connecting`, `disconnected`, …
  final String? connectionState;

  /// False for a remote (SSH / WSL) workspace whose host link is down: the
  /// desktop refuses to open a bridge for it until it is reconnected. Same
  /// test as ZCode's remote web client.
  bool get connected =>
      !isRemote ||
      (connectionState != 'disconnected' && (remoteSessionId?.isNotEmpty ?? false));

  bool get isRemote => kind == 'remote';

  /// `workspaceKey` in ZCode: identity for remote workspaces, else the path.
  String get key => (identity?.trim().isNotEmpty ?? false) ? identity!.trim() : path;

  /// `ZCodeAgentWorkspaceTarget` parameters.
  Map<String, Object?> get target => {
        'workspacePath': path,
        if (identity?.trim().isNotEmpty ?? false) 'workspaceIdentity': identity,
      };

  @override
  bool operator ==(Object other) => other is WorkspaceRef && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

String _basename(String path) {
  final parts = path.split(RegExp(r'[\/]')).where((p) => p.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}
