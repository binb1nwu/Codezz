import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../core/zcode/zcode_api.dart';

/// Messages a terminal prints into its own buffer; localised by the UI.
class TerminalTexts {
  const TerminalTexts({required this.exited, required this.failed, required this.disconnected});
  final String exited;
  final String failed;
  final String disconnected;
}

/// One remote PTY (`terminal` channel) rendered by an xterm [Terminal].
///
/// The PTY is created on the first layout, when the view knows its size;
/// input typed before that is queued. Resizes are coalesced so one request
/// is in flight at a time, as in ZCode.
class TerminalSession extends ChangeNotifier {
  TerminalSession({required ZCodeApi api, required this.cwd, required this.texts}) : _api = api {
    terminal
      ..onOutput = _input
      ..onResize = (w, h, pw, ph) => _resize(w, h);
  }

  final ZCodeApi _api;
  final String cwd;
  final TerminalTexts texts;
  final Terminal terminal = Terminal(maxLines: 5000);

  String? _id;
  String? shell;
  bool exited = false;
  bool _starting = false;
  final List<String> _pendingInput = [];
  final List<StreamSubscription> _subs = [];
  (int, int)? _size;
  (int, int)? _sentSize;
  bool _resizing = false;

  /// Ctrl from the on-screen key bar: applies to the next typed key.
  bool ctrl = false;

  void setCtrl(bool value) {
    ctrl = value;
    notifyListeners();
  }

  void _input(String data) {
    if (ctrl && data.length == 1) {
      final code = data.toUpperCase().codeUnitAt(0);
      if (code >= 0x40 && code < 0x60) data = String.fromCharCode(code & 0x1f);
      setCtrl(false);
    }
    send(data);
  }

  /// Raw input to the PTY.
  void send(String data) {
    if (exited) return;
    final id = _id;
    if (id == null) {
      _pendingInput.add(data);
      return;
    }
    unawaited(_api.terminalWrite(id, data).catchError((Object _) {}));
  }

  void _resize(int cols, int rows) {
    if (cols <= 0 || rows <= 0) return;
    _size = (cols, rows);
    if (_id == null) {
      if (!_starting && !exited) unawaited(_start(cols, rows));
      return;
    }
    unawaited(_flushResize());
  }

  Future<void> _flushResize() async {
    if (_resizing) return;
    _resizing = true;
    try {
      while (!exited && _id != null && _size != null && _size != _sentSize) {
        final size = _size!;
        _sentSize = size;
        await _api.terminalResize(_id!, size.$1, size.$2);
      }
    } catch (_) {
      // A failed resize only leaves the PTY at its previous size.
    } finally {
      _resizing = false;
    }
  }

  Future<void> _start(int cols, int rows) async {
    _starting = true;
    try {
      final res = await _api.terminalCreate(cols: cols, rows: rows, cwd: cwd);
      final id = res['id'] as String?;
      if (id == null) throw StateError('no terminal id');
      shell = res['shell'] as String?;
      if (exited) {
        // Closed while starting.
        unawaited(_api.terminalDispose(id).catchError((Object _) {}));
        return;
      }
      _id = id;
      _sentSize = (cols, rows);
      _subs
        ..add(_api.terminalData(id).listen(terminal.write))
        ..add(_api.terminalExit(id).listen((_) => _markExited(texts.exited)));
      for (final data in _pendingInput) {
        send(data);
      }
      _pendingInput.clear();
      unawaited(_flushResize());
      notifyListeners();
    } catch (e) {
      terminal.write('\r\n${texts.failed}\r\n$e\r\n');
      exited = true;
      notifyListeners();
    } finally {
      _starting = false;
    }
  }

  void _markExited(String message) {
    if (exited) return;
    exited = true;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    terminal.write('\r\n$message\r\n');
    notifyListeners();
  }

  /// The connection that carried the PTY is gone.
  void connectionLost() => _markExited(texts.disconnected);

  @override
  void dispose() {
    final id = _id;
    if (id != null && !exited) unawaited(_api.terminalDispose(id).catchError((Object _) {}));
    exited = true;
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

enum SidePaneKind { review, terminal }

class SidePaneTab {
  SidePaneTab.review()
      : id = 'review',
        kind = SidePaneKind.review,
        title = '',
        terminal = null;
  SidePaneTab.terminal(this.id, this.title, TerminalSession this.terminal) : kind = SidePaneKind.terminal;

  final String id;
  final SidePaneKind kind;

  /// Terminal tabs only: the cwd's base name, numbered when repeated.
  final String title;
  final TerminalSession? terminal;
}

/// ZCode's side pane on phones: an overlay with Review and Terminal tabs.
/// Tabs (and their PTYs) outlive the overlay being closed.
class SidePane extends ChangeNotifier {
  bool visible = false;
  final List<SidePaneTab> tabs = [];
  String? activeId;
  int _terminalSeq = 0;

  SidePaneTab? get active => tabs.where((t) => t.id == activeId).firstOrNull;
  bool get hasReview => tabs.any((t) => t.kind == SidePaneKind.review);

  void show() => _set(() => visible = true);
  void hide() => _set(() => visible = false);
  void toggle() => _set(() => visible = !visible);

  void openReview() => _set(() {
        if (!hasReview) tabs.add(SidePaneTab.review());
        activeId = 'review';
        visible = true;
      });

  void openTerminal(ZCodeApi api, String cwd, TerminalTexts texts) => _set(() {
        final base = _basename(cwd);
        final taken = tabs.where((t) => t.kind == SidePaneKind.terminal).map((t) => t.title).toSet();
        var title = base;
        for (var n = 2; taken.contains(title); n++) {
          title = '$base $n';
        }
        final tab = SidePaneTab.terminal(
            'terminal:${_terminalSeq++}', title, TerminalSession(api: api, cwd: cwd, texts: texts));
        tabs.add(tab);
        activeId = tab.id;
        visible = true;
      });

  void select(String id) => _set(() => activeId = id);

  void closeTab(String id) => _set(() {
        final i = tabs.indexWhere((t) => t.id == id);
        if (i < 0) return;
        tabs.removeAt(i).terminal?.dispose();
        if (activeId == id) activeId = tabs.isEmpty ? null : tabs[i.clamp(0, tabs.length - 1)].id;
      });

  void connectionLost() {
    for (final t in tabs) {
      t.terminal?.connectionLost();
    }
  }

  void _set(VoidCallback change) {
    change();
    notifyListeners();
  }

  static String _basename(String path) {
    final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
    return parts.isEmpty ? 'Terminal' : parts.last;
  }

  @override
  void dispose() {
    for (final t in tabs) {
      t.terminal?.dispose();
    }
    super.dispose();
  }
}
