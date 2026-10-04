import 'package:flutter/material.dart';

import '../../state/device_session.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';

const reviewSources = ['unstaged', 'staged', 'branch'];

/// Changed files of one review source in a `git.refresh` result.
List<Map<String, dynamic>> reviewChanges(Map<String, dynamic> status, String source) {
  final raw = switch (source) {
    'staged' => status['stagedChanges'],
    'branch' => (status['branchComparison'] as Map?)?['changes'],
    _ => status['unstagedChanges'],
  };
  return [for (final c in raw is List ? raw : const []) if (c is Map) Map<String, dynamic>.from(c)];
}

/// ZCode's Review tab: the workspace's Git changes by source, each file
/// expandable into its diff.
class ReviewView extends StatefulWidget {
  const ReviewView({super.key, required this.workspace});
  final WorkspaceSession workspace;

  @override
  State<ReviewView> createState() => _ReviewViewState();
}

class _ReviewViewState extends State<ReviewView> {
  String _source = 'unstaged';
  Map<String, dynamic>? _status;
  Object? _error;
  bool _loading = false;
  String? _expanded;
  final Map<String, Map<String, dynamic>?> _diffs = {};
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final api = widget.workspace.api;
    if (api == null) {
      setState(() {});
      return;
    }
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _diffs.clear();
    });
    try {
      final status = await api.gitRefresh(widget.workspace.workspace);
      if (!mounted || gen != _generation) return;
      setState(() {
        _status = status;
        _error = null;
      });
      if (_expanded != null) _loadDiff(_expanded!);
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() => _error = e);
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  String _key(String path) => '$_source|$path';

  Future<void> _loadDiff(String path) async {
    final key = _key(path);
    if (_diffs.containsKey(key)) return;
    final inline = reviewChanges(_status ?? const {}, _source).where((c) => c['path'] == path).firstOrNull?['diff'];
    if (inline is Map) {
      setState(() => _diffs[key] = Map<String, dynamic>.from(inline));
      return;
    }
    final api = widget.workspace.api;
    if (api == null) return;
    setState(() => _diffs[key] = null);
    final gen = _generation;
    Map<String, dynamic> diff;
    try {
      diff = await api.gitDiff(widget.workspace.workspace, path, _source);
    } catch (e) {
      diff = {'path': path, 'availability': 'unavailable', 'error': '$e'};
    }
    if (mounted && gen == _generation) setState(() => _diffs[key] = diff);
  }

  void _toggle(String path) {
    setState(() => _expanded = _expanded == path ? null : path);
    if (_expanded != null) _loadDiff(path);
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final summary = _status?['summary'] as Map?;
    final changes = _status == null ? const <Map<String, dynamic>>[] : reviewChanges(_status!, _source);

    Widget body;
    if (summary?['isGitAvailable'] == false) {
      body = _State(title: s.gitUnavailableTitle, description: s.gitUnavailableDescription);
    } else if (_status == null && _error != null) {
      body = _State(title: s.gitErrorTitle, description: s.gitErrorDescription('$_error'));
    } else if (_status == null) {
      body = _State(title: s.gitLoading, description: s.gitLoadingDescription, loading: true);
    } else if (summary?['isRepository'] == false) {
      body = _State(title: s.gitNotRepositoryTitle, description: s.gitNotRepositoryDescription);
    } else if (changes.isEmpty) {
      body = _State(title: s.gitEmptyTitle, description: s.gitEmptyDescription);
    } else {
      body = ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: changes.length,
        itemBuilder: (context, i) {
          final c = changes[i];
          final path = '${c['path']}';
          final open = _expanded == path;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _ChangeRow(change: c, open: open, onTap: () => _toggle(path)),
            if (open) _DiffBody(diff: _diffs[_key(path)], loading: !_diffs.containsKey(_key(path)) || _diffs[_key(path)] == null),
          ]);
        },
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        child: Row(children: [
          PopupMenuButton<String>(
            initialValue: _source,
            onSelected: (v) => setState(() {
              _source = v;
              _expanded = null;
            }),
            itemBuilder: (_) => [
              for (final id in reviewSources) PopupMenuItem(value: id, child: Text(s.gitSource(id))),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(s.gitSource(_source),
                    style: TextStyle(fontSize: ZText.sm, fontWeight: FontWeight.w500, color: z.foreground)),
                Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: z.foregroundSubtle),
              ]),
            ),
          ),
          if (summary?['branchName'] is String) ...[
            const SizedBox(width: 4),
            Flexible(
              child: Text('${summary!['branchName']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: ZText.xs, color: z.foregroundSubtle)),
            ),
          ],
          const Spacer(),
          TextButton.icon(
            onPressed: _loading ? null : _refresh,
            icon: _loading ? const ZSpinner(size: 12) : const Icon(Icons.refresh_rounded, size: 15),
            label: Text(s.gitRefresh, style: const TextStyle(fontSize: ZText.sm)),
          ),
        ]),
      ),
      Divider(height: 1, color: z.border),
      Expanded(child: body),
    ]);
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({required this.change, required this.open, required this.onTap});
  final Map<String, dynamic> change;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final path = '${change['workspaceRelativePath'] ?? change['path']}';
    final slash = path.lastIndexOf('/');
    final name = slash < 0 ? path : path.substring(slash + 1);
    final dir = slash < 0 ? '' : path.substring(0, slash);
    final added = change['added'] as num? ?? 0;
    final removed = change['removed'] as num? ?? 0;
    final deleted = change['kind'] == 'deleted';
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: open ? z.hover : null,
        child: Row(children: [
          Flexible(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                  text: name,
                  style: TextStyle(
                    color: z.foreground,
                    decoration: deleted ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (dir.isNotEmpty) TextSpan(text: '  $dir', style: TextStyle(color: z.foregroundSubtlest)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: ZText.sm),
            ),
          ),
          const SizedBox(width: 8),
          if (added > 0)
            Text('+$added', style: TextStyle(fontSize: ZText.xs, color: z.success, fontFamily: zMonoFamily)),
          if (removed > 0) ...[
            const SizedBox(width: 4),
            Text('-$removed', style: TextStyle(fontSize: ZText.xs, color: z.destructive, fontFamily: zMonoFamily)),
          ],
          const SizedBox(width: 4),
          Icon(open ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_right_rounded,
              size: 16, color: z.foregroundSubtle),
        ]),
      ),
    );
  }
}

/// A unified patch, or why there is none.
class _DiffBody extends StatelessWidget {
  const _DiffBody({required this.diff, required this.loading});
  final Map<String, dynamic>? diff;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    if (loading) {
      return const Padding(padding: EdgeInsets.all(16), child: Center(child: ZSpinner(size: 14)));
    }
    final d = diff!;
    final patch = d['patch'] as String?;
    if (patch == null || patch.isEmpty) {
      final title = switch (d['availability']) {
        'binary' => s.diffBinary,
        'truncated' => s.diffTruncated,
        _ => s.diffUnavailable,
      };
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Text(title, style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
      );
    }
    final lines = patchLines(patch);
    const mono = TextStyle(fontFamily: zMonoFamily, fontFamilyFallback: zMonoFallback, fontSize: 11.5, height: 1.5);
    return Container(
      color: z.codeBackground,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final l in lines)
            Container(
              color: switch (l[0]) {
                '+' => z.success.withValues(alpha: 0.14),
                '-' => z.destructive.withValues(alpha: 0.14),
                _ => null,
              },
              padding: const EdgeInsets.symmetric(horizontal: 12),
              constraints: const BoxConstraints(minWidth: 400),
              child: Text(
                l,
                style: mono.copyWith(color: l.startsWith('@@') ? z.foregroundSubtle : z.foreground),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Patch lines without the file headers (`diff --git`, `index`, `---`,
/// `+++`); each line keeps its `+`/`-`/space prefix. Empty lines get a
/// space so they keep their height.
List<String> patchLines(String patch) {
  final out = <String>[];
  var inHunk = false;
  for (final line in patch.split('\n')) {
    if (line.startsWith('@@')) inHunk = true;
    if (!inHunk) continue;
    if (line.startsWith(r'\ No newline')) continue;
    out.add(line.isEmpty ? ' ' : line);
  }
  while (out.isNotEmpty && out.last.trim().isEmpty) {
    out.removeLast();
  }
  return out;
}

class _State extends StatelessWidget {
  const _State({required this.title, required this.description, this.loading = false});
  final String title;
  final String description;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (loading) ...[const ZSpinner(size: 16), const SizedBox(height: 12)],
          Text(title,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w500, color: z.foreground)),
          const SizedBox(height: 6),
          Text(description,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle, height: 1.5)),
        ]),
      ),
    );
  }
}
