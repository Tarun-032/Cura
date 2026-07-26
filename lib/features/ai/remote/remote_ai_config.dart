/// Configuration for the optional cloud model the user brings their own API key
/// for. Generic on purpose: any OpenAI-compatible `/chat/completions` endpoint
/// works, so one code path serves every provider. Plain data; persistence lives
/// in `RemoteAiStore`.
class RemoteAiConfig {
  const RemoteAiConfig({
    required this.providerId,
    required this.baseUrl,
    required this.apiKey,
    required this.modelId,
  });

  /// Which preset this came from ([RemoteProvider.id]) — `openrouter` or
  /// `custom`. Drives the provider label shown in the UI and the default base
  /// URL when the user hasn't overridden it.
  final String providerId;

  /// API root, e.g. `https://openrouter.ai/api/v1`. The client appends
  /// `/chat/completions`. Trailing slashes are tolerated (trimmed on use).
  final String baseUrl;

  /// The user's secret bearer token. Empty until they paste one.
  final String apiKey;

  /// The provider's model identifier, e.g. `openai/gpt-4o-mini` or
  /// `meta-llama/llama-3.1-8b-instruct`.
  final String modelId;

  /// True once the config is usable (a key and a model are set). The UI won't
  /// let the user enable the cloud engine before this.
  bool get isComplete => apiKey.trim().isNotEmpty && modelId.trim().isNotEmpty;

  /// Human label for the provider ("OpenRouter" / "Custom"), for the consent
  /// line and the model selector.
  String get providerLabel => providerById(providerId).label;

  /// Short label for the model selector — the model id is the identity users
  /// recognise; the provider gives it context.
  String get displayName => modelId.trim().isEmpty ? providerLabel : modelId;

  RemoteAiConfig copyWith({
    String? providerId,
    String? baseUrl,
    String? apiKey,
    String? modelId,
  }) {
    return RemoteAiConfig(
      providerId: providerId ?? this.providerId,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      modelId: modelId ?? this.modelId,
    );
  }

  /// A blank config seeded from the default provider (OpenRouter) so the base
  /// URL is pre-filled and the user only has to paste a key and a model id.
  factory RemoteAiConfig.initial() {
    final p = kRemoteProviders.first;
    return RemoteAiConfig(
      providerId: p.id,
      baseUrl: p.baseUrl,
      apiKey: '',
      modelId: '',
    );
  }
}

/// A selectable provider preset. `custom` carries an empty base URL so the user
/// supplies their own (any OpenAI-compatible host).
class RemoteProvider {
  const RemoteProvider({
    required this.id,
    required this.label,
    required this.baseUrl,
    this.hint,
  });

  final String id;
  final String label;
  final String baseUrl;

  /// Optional placeholder shown under the model field, e.g. an example id.
  final String? hint;

  bool get isCustom => id == 'custom';
}

/// Provider presets. OpenRouter is the default: many models, including free
/// ones, behind a single key. Custom covers everyone else.
const List<RemoteProvider> kRemoteProviders = [
  RemoteProvider(
    id: 'openrouter',
    label: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    hint: 'e.g. meta-llama/llama-3.1-8b-instruct',
  ),
  RemoteProvider(
    id: 'openai',
    label: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    hint: 'e.g. gpt-4o-mini',
  ),
  RemoteProvider(
    id: 'groq',
    label: 'Groq',
    baseUrl: 'https://api.groq.com/openai/v1',
    hint: 'e.g. llama-3.1-8b-instant',
  ),
  RemoteProvider(
    id: 'nvidia',
    label: 'NVIDIA NIM',
    baseUrl: 'https://integrate.api.nvidia.com/v1',
    hint: 'e.g. meta/llama-3.1-8b-instruct',
  ),
  RemoteProvider(
    id: 'custom',
    label: 'Custom',
    baseUrl: '',
    hint: 'Any OpenAI-compatible base URL',
  ),
];

/// Looks up a preset by id, falling back to the default (OpenRouter) for an
/// unknown/legacy id so the UI never lands on a null provider.
RemoteProvider providerById(String? id) {
  for (final p in kRemoteProviders) {
    if (p.id == id) return p;
  }
  return kRemoteProviders.first;
}
