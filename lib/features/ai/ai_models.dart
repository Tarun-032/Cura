/// A downloadable on-device model the user can pick. Kept as plain data so new
/// models drop in without code changes (the swappable catalog).
class AiModel {
  const AiModel({
    required this.id,
    required this.displayName,
    required this.url,
    required this.fileName,
    required this.sizeLabel,
    required this.template,
    required this.contextSize,
    this.maxOutputTokens = 768,
    this.canThink = false,
    this.thinkingMaxTokens = 1024,
  });

  /// Stable id used in the catalog and persisted as the active selection.
  final String id;

  /// Human label for the download UI.
  final String displayName;

  /// Direct, ungated download URL (HuggingFace, no login/token).
  final String url;

  /// File name the model is stored under / checked for installation by.
  final String fileName;

  /// e.g. "986 MB" — shown in the download sheet.
  final String sizeLabel;

  /// llama.cpp chat template id (e.g. `chatml` for Qwen). Drives how the
  /// system/user turns are wrapped before the GGUF sees them.
  final String template;

  /// Context window (tokens) to open the model with. Kept modest to stay light
  /// on phone RAM; the model files support far more.
  final int contextSize;

  /// Ceiling on generated tokens per answer; short replies still stop at the
  /// model's end-of-turn token. The service clamps it further to the context
  /// window's remaining room.
  final int maxOutputTokens;

  /// Whether this model has a hidden `<think>…</think>` mode. When true, Ask
  /// shows the "Think harder" toggle; the on/off choice itself is the user
  /// preference in `AiModelManager.thinkHarder()`.
  final bool canThink;

  /// Token budget with "Think harder" on: larger than [maxOutputTokens] because
  /// the reasoning chain and the answer must both fit.
  final int thinkingMaxTokens;
}

/// Available models: open (no login, no token) Q4_K_M GGUFs by `bartowski`.
/// Q4_K_M holds accuracy better than plain Q4_0, at the cost of ARM's Q4_0
/// repacking fast path.
const List<AiModel> kAiModelCatalog = [
  // LFM2.5 (Liquid AI), the default: small, fast, strong instruction-following.
  // ChatML markers; the bundled llama.cpp has native LFM2 support.
  AiModel(
    id: 'lfm2_5_1_2b_gguf',
    displayName: 'LFM2.5 (1.2B)',
    url:
        'https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf',
    fileName: 'LFM2.5-1.2B-Instruct-Q4_K_M.gguf',
    sizeLabel: '731 MB',
    template: 'chatml',
    contextSize: 2048,
  ),
  // Qwen3 1.7B: the quality pick, largest and slowest. A reasoning model
  // (`canThink`), run with /no_think unless "Think harder" is on.
  AiModel(
    id: 'qwen3_1_7b_gguf',
    displayName: 'Qwen3 (1.7B)',
    url:
        'https://huggingface.co/bartowski/Qwen_Qwen3-1.7B-GGUF/resolve/main/Qwen_Qwen3-1.7B-Q4_K_M.gguf',
    fileName: 'Qwen_Qwen3-1.7B-Q4_K_M.gguf',
    sizeLabel: '1.28 GB',
    template: 'chatml',
    contextSize: 2048,
    canThink: true,
  ),
  AiModel(
    id: 'qwen2_5_0_5b_gguf',
    displayName: 'Qwen 2.5 (0.5B, lighter)',
    url:
        'https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf',
    fileName: 'Qwen2.5-0.5B-Instruct-Q4_K_M.gguf',
    sizeLabel: '398 MB',
    template: 'chatml',
    contextSize: 2048,
  ),
];

/// Default model — LFM2.5, the fast + accurate pick. If it OOMs on a very
/// low-RAM phone, switch to the 0.5B. All run fully on-device.
final AiModel kDefaultModel = kAiModelCatalog.first;

/// Looks up a catalog entry by id (used to restore the active selection).
AiModel? aiModelById(String? id) {
  for (final m in kAiModelCatalog) {
    if (m.id == id) return m;
  }
  return null;
}

/// Looks up a catalog entry by file name, since the downloader knows files.
AiModel? aiModelByFileName(String? fileName) {
  for (final m in kAiModelCatalog) {
    if (m.fileName == fileName) return m;
  }
  return null;
}
