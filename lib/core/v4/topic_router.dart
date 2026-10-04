import 'dart:async';

import 'package:flutter/foundation.dart';

import '../zcode/server_info.dart';
import '../zcode/zcode_api.dart';
import 'wire_assembler.dart';

/// A consumer of one V4 topic (`conversation/<id>`, `sessions-index/<ws>`).
abstract class TopicConsumer {
  String get topic;

  /// A logical frame for the consumer's current subscription.
  void onFrame(Map<String, dynamic> frame, String deliveryKind);

  /// Physical assembly failed; the consumer must resync.
  void onFault(String reason);
}

class _Route {
  _Route(this.consumer);
  final TopicConsumer consumer;
  String? subscriptionId;
  int pendingSubscribes = 0;
  final List<WireEvent> staged = [];
}

/// Routes the workspace-wide frame streams (`onDynamicConversationFrame`,
/// `onDynamicSessionsIndexFrame`) to topic consumers.
///
/// The initial snapshot notification can arrive *before* the subscribe ACK,
/// so frames for a topic with a subscribe in flight are staged and released
/// once the ACK names the owning subscription (ZCode's
/// `ackActivationBarrier`).
class TopicRouter {
  TopicRouter(this.workspace);

  final WorkspaceRef workspace;
  final TopicWireAssembler _assembler = TopicWireAssembler();
  final Map<String, _Route> _routes = {};
  final List<StreamSubscription> _upstream = [];
  static const _maxStaged = 4096;

  /// Called for every new connection; frame streams are per connection.
  void attach(ZCodeApi api) {
    detach();
    _upstream
      ..add(api.conversationFrames(workspace).listen(_accept))
      ..add(api.sessionsIndexFrames(workspace).listen(_accept));
  }

  void detach() {
    for (final s in _upstream) {
      s.cancel();
    }
    _upstream.clear();
    _assembler.clear();
    for (final r in _routes.values) {
      r.subscriptionId = null;
      r.pendingSubscribes = 0;
      r.staged.clear();
    }
  }

  void register(TopicConsumer consumer) {
    _routes[consumer.topic] = _Route(consumer);
  }

  void unregister(TopicConsumer consumer) {
    final route = _routes[consumer.topic];
    if (route?.consumer == consumer) {
      _routes.remove(consumer.topic);
      if (route!.subscriptionId != null) {
        _assembler.discard(consumer.topic, route.subscriptionId!);
      }
    }
  }

  /// Wrap a subscribe/resubscribe RPC: frames that arrive before its ACK are
  /// staged and delivered after [bind].
  void beginSubscribe(TopicConsumer consumer) {
    final route = _routes[consumer.topic];
    if (route == null) return;
    route.pendingSubscribes++;
  }

  void bind(TopicConsumer consumer, String subscriptionId) {
    final route = _routes[consumer.topic];
    if (route == null || route.consumer != consumer) return;
    final previous = route.subscriptionId;
    if (previous != null && previous != subscriptionId) {
      _assembler.discard(consumer.topic, previous);
    }
    route.subscriptionId = subscriptionId;
    route.pendingSubscribes = (route.pendingSubscribes - 1).clamp(0, 1 << 30);
    final staged = List.of(route.staged);
    route.staged.clear();
    for (final event in staged) {
      if (event.subscriptionId == subscriptionId) _deliver(route, event);
    }
  }

  void cancelSubscribe(TopicConsumer consumer) {
    final route = _routes[consumer.topic];
    if (route == null) return;
    route.pendingSubscribes = (route.pendingSubscribes - 1).clamp(0, 1 << 30);
    if (route.pendingSubscribes == 0) route.staged.clear();
  }

  @visibleForTesting
  void debugAccept(Map<String, dynamic> wire) => _accept(wire);

  void _accept(Map<String, dynamic> wire) {
    for (final event in _assembler.accept(wire)) {
      final route = _routes[event.topic];
      if (route == null) continue;
      if (event.subscriptionId == route.subscriptionId) {
        _deliver(route, event);
      } else if (route.pendingSubscribes > 0 && route.staged.length < _maxStaged) {
        route.staged.add(event);
      }
    }
  }

  void _deliver(_Route route, WireEvent event) {
    switch (event) {
      case WireFrame():
        route.consumer.onFrame(event.frame, event.deliveryKind);
      case WireFault():
        route.consumer.onFault(event.reason);
    }
  }

  void dispose() {
    detach();
    _routes.clear();
  }
}
