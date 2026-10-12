/// Groups conversation rows into product turns the way ZCode's timeline
/// does: user input bubbles, a collapsible "Worked for …" section with the
/// assistant's intermediate work, and the final answer.
class TurnGroup {
  TurnGroup(this.key);

  final String key;
  Map<String, dynamic>? header;
  final List<Map<String, dynamic>> boundaries = []; // lightBoundary markers
  final List<Map<String, dynamic>> inputs = [];
  final List<Map<String, dynamic>> work = [];
  Map<String, dynamic>? answer;
  final List<Map<String, dynamic>> tail = []; // turnTailBoundary markers

  /// Identity of every row, used to reuse widgets for unchanged turns.
  final List<Map<String, dynamic>> allRows = [];

  bool get running => header?['state'] == 'running';
  bool get failed => header?['state'] == 'failed';
  bool get interrupted => header?['state'] == 'completedInterrupted';

  /// When the turn started (epoch ms), if the desktop said.
  int? get startedAt => (header?['startedAt'] as num?)?.toInt();

  int? get durationMs {
    final h = header;
    if (h == null) return null;
    final active = (h['activeMs'] as num?)?.toInt();
    if (active != null) return active;
    final start = (h['startedAt'] as num?)?.toInt();
    final end = (h['endedAt'] as num?)?.toInt();
    if (start != null && end != null) return end - start;
    return null;
  }

  bool sameRowsAs(TurnGroup other) {
    if (other.allRows.length != allRows.length) return false;
    for (var i = 0; i < allRows.length; i++) {
      if (!identical(other.allRows[i], allRows[i])) return false;
    }
    return true;
  }
}

bool _isVisibleWork(Map<String, dynamic> row) {
  switch (row['kind']) {
    case 'reasoning':
      return (row['text'] as String? ?? '').trim().isNotEmpty || row['state'] == 'streaming';
    case 'assistantText':
      return (row['text'] as String? ?? '').isNotEmpty || row['state'] == 'streaming';
    case 'toolCall':
    case 'subagent':
    case 'artifact':
    case 'hookInvocation':
    case 'timelineMarker':
      return true;
  }
  return false;
}

List<TurnGroup> buildTurns(List<Map<String, dynamic>> rows) {
  final turns = <TurnGroup>[];
  TurnGroup? current;
  for (final row in rows) {
    final key = (row['productTurnId'] ?? row['turnId'] ?? '${row['rowId']}') as String;
    if (current == null || current.key != key) {
      current = TurnGroup(key);
      turns.add(current);
    }
    current.allRows.add(row);
    switch (row['kind']) {
      case 'turnHeader':
        current.header = row;
      case 'userInput':
        current.inputs.add(row);
      case 'timelineMarker':
        final lane = row['lane'] as String? ?? _defaultLane(row);
        if (lane == 'lightBoundary') {
          current.boundaries.add(row);
        } else if (lane == 'turnTailBoundary') {
          current.tail.add(row);
        } else {
          current.work.add(row);
        }
      default:
        if (_isVisibleWork(row)) current.work.add(row);
    }
  }
  for (final turn in turns) {
    // The answer is the last assistant text with no later tool activity.
    for (var i = turn.work.length - 1; i >= 0; i--) {
      final kind = turn.work[i]['kind'];
      if (kind == 'assistantText') {
        turn.answer = turn.work.removeAt(i);
        break;
      }
      if (kind == 'toolCall' || kind == 'subagent') break;
    }
  }
  return turns;
}

String _defaultLane(Map<String, dynamic> row) {
  final type = (row['marker'] as Map?)?['type'];
  return switch (type) {
    'modelChange' => 'lightBoundary',
    'goalVerify' || 'forkNotice' => 'turnTailBoundary',
    _ => 'assistantWork',
  };
}

/// One-line summary of a tool call input (command, path, pattern, …).
String toolSummary(Map<String, dynamic> row) {
  final input = row['input'];
  if (input is Map) {
    for (final key in const [
      'command',
      'file_path',
      'filePath',
      'path',
      'pattern',
      'url',
      'query',
      'description',
      'prompt',
      'subject',
    ]) {
      final v = input[key];
      if (v is String && v.trim().isNotEmpty) return v.trim().split('\n').first;
    }
    final questions = input['questions'];
    if (questions is List && questions.isNotEmpty && questions.first is Map) {
      return '${(questions.first as Map)['question'] ?? ''}';
    }
    final todos = input['todos'];
    if (todos is List) return '${todos.length} todos';
  }
  final text = (row['inputText'] as String? ?? '').trim();
  return text.length > 120 ? '${text.substring(0, 120)}…' : text;
}
