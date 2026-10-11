/**
 * The opinionated part: which providers exist, which models each one offers,
 * what they cost, and the profiles an app asks for. Nothing here is stored;
 * the database only holds keys, a few settings and usage.
 *
 * Port of TokenLib `Catalog.swift`.
 */

export const PROVIDER_KINDS = ['anthropic', 'openai', 'gemini', 'deepseek', 'kimi', 'qwen', 'grok', 'mistral', 'cohere', 'openrouter', 'local'] as const;
export type ProviderKind = (typeof PROVIDER_KINDS)[number];

export function providerDisplayName(kind: ProviderKind): string {
  switch (kind) {
    case 'anthropic':
      return 'Anthropic';
    case 'openai':
      return 'OpenAI';
    case 'gemini':
      return 'Google Gemini';
    case 'deepseek':
      return 'DeepSeek';
    case 'kimi':
      return 'Kimi (Moonshot)';
    case 'qwen':
      return 'Qwen (Alibaba)';
    case 'grok':
      return 'Grok (xAI)';
    case 'mistral':
      return 'Mistral';
    case 'cohere':
      return 'Cohere';
    case 'openrouter':
      return 'OpenRouter';
    case 'local':
      return 'Local server';
  }
}

/** An OpenAI-compatible server on the local network needs no key. */
export function providerNeedsKey(kind: ProviderKind): boolean {
  return kind !== 'local';
}

export function isProviderKind(v: unknown): v is ProviderKind {
  return typeof v === 'string' && (PROVIDER_KINDS as readonly string[]).includes(v);
}

/** How capable (and expensive) a model is; profiles ask for a tier, the catalog picks the model. */
export type ModelTier = 'fast' | 'balanced' | 'best';

export interface ModelInfo {
  provider: ProviderKind;
  id: string;
  name: string;
  tier: ModelTier;
  /** USD per million tokens. */
  inputPerMillion: number;
  outputPerMillion: number;
  contextTokens: number;
  vision: boolean;
}

/** Cost in micro-dollars for a usage, so the ledger can add integers. */
export function costMicros(model: ModelInfo, promptTokens: number, replyTokens: number): number {
  return Math.round(promptTokens * model.inputPerMillion + replyTokens * model.outputPerMillion);
}

/**
 * What an app asks for. A profile names an intent, not a model; the catalog and the
 * active provider decide what runs.
 */
export const PROFILES = ['character', 'assistant', 'fast', 'vision'] as const;
export type Profile = (typeof PROFILES)[number];

export function isProfile(v: unknown): v is Profile {
  return typeof v === 'string' && (PROFILES as readonly string[]).includes(v);
}

export const ProfileInfo = {
  tier(profile: Profile): ModelTier {
    return profile === 'fast' ? 'fast' : 'best';
  },
  /** Thinking effort hint for providers that support it (Anthropic's `output_config.effort`). */
  effort(profile: Profile): string | undefined {
    switch (profile) {
      case 'character':
      case 'fast':
        return 'low';
      case 'assistant':
      case 'vision':
        return 'high';
    }
  },
  maxTokens(profile: Profile): number {
    switch (profile) {
      case 'character':
        return 400;
      case 'fast':
        return 1024;
      case 'assistant':
      case 'vision':
        return 4096;
    }
  },
  temperature(profile: Profile): number | undefined {
    switch (profile) {
      case 'character':
        return 0.9;
      case 'fast':
        return 0.2;
      default:
        return undefined;
    }
  },
  needsVision(profile: Profile): boolean {
    return profile === 'vision';
  },
};

const m = (
  provider: ProviderKind,
  id: string,
  name: string,
  tier: ModelTier,
  inputPerMillion: number,
  outputPerMillion: number,
  contextTokens: number,
  vision = true,
): ModelInfo => ({ provider, id, name, tier, inputPerMillion, outputPerMillion, contextTokens, vision });

export const Catalog = {
  /** Anthropic: ids and prices from the 2026 model table (Claude Opus 5.5 / Sonnet 5.5 / Haiku 4.5). */
  anthropic: [
    m('anthropic', 'claude-opus-5-5', 'Claude Opus 5.5', 'best', 4, 20, 1_000_000),
    m('anthropic', 'claude-sonnet-5-5', 'Claude Sonnet 5.5', 'balanced', 2, 10, 1_000_000),
    m('anthropic', 'claude-haiku-4-5', 'Claude Haiku 4.5', 'fast', 1, 5, 200_000),
  ] as ModelInfo[],
  openai: [
    m('openai', 'gpt-5', 'GPT-5', 'best', 1.25, 10, 400_000),
    m('openai', 'gpt-5-mini', 'GPT-5 mini', 'balanced', 0.25, 2, 400_000),
    m('openai', 'gpt-5-nano', 'GPT-5 nano', 'fast', 0.05, 0.4, 400_000),
  ] as ModelInfo[],
  gemini: [
    m('gemini', 'gemini-2.5-pro', 'Gemini 2.5 Pro', 'best', 1.25, 10, 1_000_000),
    m('gemini', 'gemini-2.5-flash', 'Gemini 2.5 Flash', 'balanced', 0.3, 2.5, 1_000_000),
    m('gemini', 'gemini-2.5-flash-lite', 'Gemini 2.5 Flash-Lite', 'fast', 0.1, 0.4, 1_000_000),
  ] as ModelInfo[],
  /** DeepSeek: V4 Pro and Flash at peak rates; only Flash takes images. */
  deepseek: [
    m('deepseek', 'deepseek-v4-pro', 'DeepSeek V4 Pro', 'best', 1.32, 3.96, 1_000_000, false),
    m('deepseek', 'deepseek-flash', 'DeepSeek Flash', 'fast', 0.3, 1.2, 1_000_000),
  ] as ModelInfo[],
  /** Kimi (Moonshot): K3 and K2.6; both take images. */
  kimi: [
    m('kimi', 'kimi-k3', 'Kimi K3', 'best', 3, 15, 1_000_000),
    m('kimi', 'kimi-k2.6', 'Kimi K2.6', 'balanced', 0.95, 4, 256_000),
  ] as ModelInfo[],
  /** Qwen (Alibaba Cloud Model Studio, international): the 3.8 / 3.7 line, all multimodal, base-tier prices. */
  qwen: [
    m('qwen', 'qwen3.8-max', 'Qwen 3.8 Max', 'best', 2, 6, 1_000_000),
    m('qwen', 'qwen3.7-plus', 'Qwen 3.7 Plus', 'balanced', 0.4, 1.6, 1_000_000),
    m('qwen', 'qwen3.8-flash', 'Qwen 3.8 Flash', 'fast', 0.15, 0.47, 1_000_000),
  ] as ModelInfo[],
  /** xAI: Grok 4.7 and the cheaper Grok 4.3, prices for prompts under 200k tokens; both take images. */
  grok: [
    m('grok', 'grok-4.7', 'Grok 4.7', 'best', 2, 6, 500_000),
    m('grok', 'grok-4.3', 'Grok 4.3', 'fast', 1.25, 2.5, 1_000_000),
  ] as ModelInfo[],
  /** Mistral: the `-latest` aliases of Large 4, Medium 3.5 and Small 4, all multimodal. */
  mistral: [
    m('mistral', 'mistral-large-latest', 'Mistral Large', 'best', 0.5, 1.5, 512_000),
    m('mistral', 'mistral-medium-latest', 'Mistral Medium', 'balanced', 1.5, 7.5, 256_000),
    m('mistral', 'mistral-small-latest', 'Mistral Small', 'fast', 0.15, 0.6, 256_000),
  ] as ModelInfo[],
  /** Cohere: Command A+ (images, reasoning), Command A and Command R7B. */
  cohere: [
    m('cohere', 'command-a-plus-05-2026', 'Command A+', 'best', 0.3, 1.5, 128_000),
    m('cohere', 'command-a-03-2025', 'Command A', 'balanced', 2.5, 10, 256_000, false),
    m('cohere', 'command-r7b-12-2024', 'Command R7B', 'fast', 0.0375, 0.15, 128_000, false),
  ] as ModelInfo[],
  /** OpenRouter: the same opinion as the Anthropic catalog, through one OpenRouter key; prices as OpenRouter lists them. */
  openrouter: [
    m('openrouter', 'anthropic/claude-opus-5.5', 'Claude Opus 5.5 via OpenRouter', 'best', 4, 20, 1_000_000),
    m('openrouter', 'anthropic/claude-sonnet-5.5', 'Claude Sonnet 5.5 via OpenRouter', 'balanced', 2, 10, 1_000_000),
    m('openrouter', 'anthropic/claude-haiku-4.5', 'Claude Haiku 4.5 via OpenRouter', 'fast', 1, 5, 200_000),
  ] as ModelInfo[],
  /** A local server serves whatever model is loaded; the id is the settings' `localModel`. */
  local: [m('local', 'local', 'Local model', 'balanced', 0, 0, 32_000, false)] as ModelInfo[],

  models(provider: ProviderKind): ModelInfo[] {
    return Catalog[provider];
  },
  all(): ModelInfo[] {
    return PROVIDER_KINDS.flatMap((p) => Catalog.models(p));
  },
  model(id: string): ModelInfo | undefined {
    return Catalog.all().find((x) => x.id === id);
  },
  /** The model a provider runs for a profile: the profile's tier, or the nearest one the provider has. */
  modelFor(profile: Profile, provider: ProviderKind): ModelInfo {
    const models = Catalog.models(provider);
    const tier = ProfileInfo.tier(profile);
    const order: ModelTier[] =
      tier === 'fast' ? ['fast', 'balanced', 'best'] : tier === 'balanced' ? ['balanced', 'best', 'fast'] : ['best', 'balanced', 'fast'];
    const needsVision = ProfileInfo.needsVision(profile);
    for (const t of order) {
      const found = models.find((x) => x.tier === t && (!needsVision || x.vision));
      if (found) return found;
    }
    return models[0]!;
  },
};
