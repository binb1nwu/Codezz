/// Models available on a device, from `model-selection.getView()`.
class ModelCatalog {
  const ModelCatalog({this.providers = const [], this.preferred});

  factory ModelCatalog.fromView(Map<String, dynamic> view) {
    final providers = <ModelProvider>[];
    for (final p in (view['providers'] as List? ?? const [])) {
      if (p is! Map) continue;
      final models = <ModelOption>[];
      for (final m in (p['models'] as List? ?? const [])) {
        if (m is! Map) continue;
        final config = m['config'] as Map? ?? const {};
        if (config['enabled'] == false) continue;
        final specs = config['optionSpecs'] as Map? ?? const {};
        final levels = (specs['reasoningLevel'] as Map?)?['values'] as List? ?? const [];
        final props = config['properties'] as Map? ?? const {};
        models.add(ModelOption(
          providerId: '${p['providerId']}',
          modelId: '${m['modelId']}',
          displayName: (config['displayName'] ?? props['displayName'] ?? m['modelId']).toString(),
          reasoningLevels: [for (final l in levels) '$l'],
          supportsImage: (props['inputFormat'] as Map?)?['supportsImage'] == true,
        ));
      }
      if (models.isEmpty) continue;
      providers.add(ModelProvider(
        providerId: '${p['providerId']}',
        name: '${p['providerName'] ?? p['providerId']}',
        models: models,
      ));
    }
    final pref = view['preferredSelection'];
    return ModelCatalog(
      providers: providers,
      preferred: pref is Map ? ModelSelection.fromJson(pref) : null,
    );
  }

  final List<ModelProvider> providers;
  final ModelSelection? preferred;

  bool get isEmpty => providers.isEmpty;

  ModelOption? find(String providerId, String modelId) {
    for (final p in providers) {
      if (p.providerId != providerId) continue;
      for (final m in p.models) {
        if (m.modelId == modelId) return m;
      }
    }
    return null;
  }
}

class ModelProvider {
  const ModelProvider({required this.providerId, required this.name, required this.models});
  final String providerId;
  final String name;
  final List<ModelOption> models;
}

class ModelOption {
  const ModelOption({
    required this.providerId,
    required this.modelId,
    required this.displayName,
    this.reasoningLevels = const [],
    this.supportsImage = false,
  });

  final String providerId;
  final String modelId;
  final String displayName;
  final List<String> reasoningLevels;
  final bool supportsImage;
}

/// `ModelSelection` (`{providerId, modelId, options: {reasoningLevel}}`).
class ModelSelection {
  const ModelSelection(this.providerId, this.modelId, [this.reasoningLevel]);

  factory ModelSelection.fromJson(Map json) => ModelSelection(
        '${json['providerId']}',
        '${json['modelId']}',
        (json['options'] as Map?)?['reasoningLevel'] as String?,
      );

  final String providerId;
  final String modelId;
  final String? reasoningLevel;

  Map<String, Object?> toJson() => {
        'providerId': providerId,
        'modelId': modelId,
        if (reasoningLevel?.isNotEmpty ?? false) 'options': {'reasoningLevel': reasoningLevel},
      };

  ModelSelection withReasoning(String? level) => ModelSelection(providerId, modelId, level);
}
