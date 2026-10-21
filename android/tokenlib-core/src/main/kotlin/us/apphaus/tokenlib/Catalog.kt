/*
 * Catalog.kt
 * TokenLib
 *
 * The opinionated part: which providers exist, which models each one
 * offers, what they cost, and the profiles an app asks for. Nothing here is
 * stored; the database only holds keys, a few settings and usage.
 */
package us.apphaus.tokenlib

enum class ProviderKind(val id: String, val displayName: String, val needsKey: Boolean = true) {
    ANTHROPIC("anthropic", "Anthropic"),
    OPENAI("openai", "OpenAI"),
    GEMINI("gemini", "Google Gemini"),
    /** DeepSeek's OpenAI-compatible API (api.deepseek.com). */
    DEEPSEEK("deepseek", "DeepSeek"),
    /** Moonshot's Kimi platform, OpenAI-compatible (api.moonshot.ai). */
    KIMI("kimi", "Kimi (Moonshot)"),
    /** Alibaba Cloud Model Studio's Qwen models, OpenAI-compatible (dashscope-intl.aliyuncs.com). */
    QWEN("qwen", "Qwen (Alibaba)"),
    /** xAI's Grok, OpenAI-compatible (api.x.ai). */
    GROK("grok", "Grok (xAI)"),
    /** Mistral's La Plateforme, OpenAI-compatible (api.mistral.ai). */
    MISTRAL("mistral", "Mistral"),
    /** Cohere's Command models through its OpenAI compatibility API (api.cohere.com/compatibility). */
    COHERE("cohere", "Cohere"),
    /** OpenRouter: many vendors' models behind one key, OpenAI-compatible (openrouter.ai). */
    OPENROUTER("openrouter", "OpenRouter"),
    /**
     * Apple's on-device foundation model (Apple Intelligence), answered in-process on iOS 26, macOS 26 and
     * visionOS 26; no key, no network. Served by a [NativeProvider] the platform registers, so it is only offered
     * where it runs: never on the JVM or Android, where the id exists so the three platforms stay in step.
     */
    APPLE("apple", "Apple Intelligence", needsKey = false),
    /** An OpenAI-compatible server on the local network (Ollama, LM Studio, vLLM); no key needed. */
    LOCAL("local", "Local server", needsKey = false);

    /** Answered in-process by the platform (no HTTP): the server needs a registered [NativeProvider] for it. */
    val isNative: Boolean get() = this == APPLE

    companion object { fun of(id: String?): ProviderKind? = entries.firstOrNull { it.id == id } }
}

/** How capable (and expensive) a model is; profiles ask for a tier, the catalog picks the model. */
enum class ModelTier { FAST, BALANCED, BEST }

data class ModelInfo(
    val provider: ProviderKind,
    val id: String,
    val name: String,
    val tier: ModelTier,
    /** USD per million tokens. */
    val inputPerMillion: Double,
    val outputPerMillion: Double,
    val contextTokens: Int,
    val vision: Boolean = true,
) {
    /** Cost in micro-dollars for a usage, so the ledger can add integers. */
    fun costMicros(promptTokens: Int, replyTokens: Int): Long = Math.round(promptTokens * inputPerMillion + replyTokens * outputPerMillion)
}

/** What an app asks for. A profile names an intent, not a model; the catalog and the active provider decide what runs. */
enum class Profile(val id: String) {
    /** A character talking to a person: short replies, low effort, warm. */
    CHARACTER("character"),
    /** General assistance: longer, careful answers. */
    ASSISTANT("assistant"),
    /** Cheap and quick: classification, extraction, short rewrites. */
    FAST("fast"),
    /** Requests that include images. */
    VISION("vision");

    val tier: ModelTier get() = if (this == FAST) ModelTier.FAST else ModelTier.BEST

    /** Thinking effort hint for providers that support it (Anthropic's `output_config.effort`). */
    val effort: String? get() = when (this) { CHARACTER, FAST -> "low"; ASSISTANT, VISION -> "high" }

    val maxTokens: Int get() = when (this) { CHARACTER -> 400; FAST -> 1024; ASSISTANT, VISION -> 4096 }

    val temperature: Double? get() = when (this) { CHARACTER -> 0.9; FAST -> 0.2; ASSISTANT, VISION -> null }

    val needsVision: Boolean get() = this == VISION

    companion object { fun of(id: String?): Profile? = entries.firstOrNull { it.id == id } }
}

object Catalog {
    /** Anthropic: ids and prices from the 2026 model table (Claude Opus 5.5 / Sonnet 5.5 / Haiku 4.5). */
    val anthropic = listOf(
        ModelInfo(ProviderKind.ANTHROPIC, "claude-opus-5-5", "Claude Opus 5.5", ModelTier.BEST, 4.0, 20.0, 1_000_000),
        ModelInfo(ProviderKind.ANTHROPIC, "claude-sonnet-5-5", "Claude Sonnet 5.5", ModelTier.BALANCED, 2.0, 10.0, 1_000_000),
        ModelInfo(ProviderKind.ANTHROPIC, "claude-haiku-4-5", "Claude Haiku 4.5", ModelTier.FAST, 1.0, 5.0, 200_000),
    )
    val openai = listOf(
        ModelInfo(ProviderKind.OPENAI, "gpt-5", "GPT-5", ModelTier.BEST, 1.25, 10.0, 400_000),
        ModelInfo(ProviderKind.OPENAI, "gpt-5-mini", "GPT-5 mini", ModelTier.BALANCED, 0.25, 2.0, 400_000),
        ModelInfo(ProviderKind.OPENAI, "gpt-5-nano", "GPT-5 nano", ModelTier.FAST, 0.05, 0.4, 400_000),
    )
    val gemini = listOf(
        ModelInfo(ProviderKind.GEMINI, "gemini-2.5-pro", "Gemini 2.5 Pro", ModelTier.BEST, 1.25, 10.0, 1_000_000),
        ModelInfo(ProviderKind.GEMINI, "gemini-2.5-flash", "Gemini 2.5 Flash", ModelTier.BALANCED, 0.3, 2.5, 1_000_000),
        ModelInfo(ProviderKind.GEMINI, "gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite", ModelTier.FAST, 0.1, 0.4, 1_000_000),
    )
    /** DeepSeek: V4 Pro and Flash at peak rates; only Flash takes images. */
    val deepseek = listOf(
        ModelInfo(ProviderKind.DEEPSEEK, "deepseek-v4-pro", "DeepSeek V4 Pro", ModelTier.BEST, 1.32, 3.96, 1_000_000, vision = false),
        ModelInfo(ProviderKind.DEEPSEEK, "deepseek-flash", "DeepSeek Flash", ModelTier.FAST, 0.30, 1.20, 1_000_000),
    )
    /** Kimi (Moonshot): K3 and K2.6; both take images. */
    val kimi = listOf(
        ModelInfo(ProviderKind.KIMI, "kimi-k3", "Kimi K3", ModelTier.BEST, 3.0, 15.0, 1_000_000),
        ModelInfo(ProviderKind.KIMI, "kimi-k2.6", "Kimi K2.6", ModelTier.BALANCED, 0.95, 4.0, 256_000),
    )
    /** Qwen (Alibaba Cloud Model Studio, international): the 3.8 / 3.7 line, all multimodal, base-tier prices. */
    val qwen = listOf(
        ModelInfo(ProviderKind.QWEN, "qwen3.8-max", "Qwen 3.8 Max", ModelTier.BEST, 2.0, 6.0, 1_000_000),
        ModelInfo(ProviderKind.QWEN, "qwen3.7-plus", "Qwen 3.7 Plus", ModelTier.BALANCED, 0.4, 1.6, 1_000_000),
        ModelInfo(ProviderKind.QWEN, "qwen3.8-flash", "Qwen 3.8 Flash", ModelTier.FAST, 0.15, 0.47, 1_000_000),
    )
    /** xAI: Grok 4.7 and the cheaper Grok 4.3, prices for prompts under 200k tokens; both take images. */
    val grok = listOf(
        ModelInfo(ProviderKind.GROK, "grok-4.7", "Grok 4.7", ModelTier.BEST, 2.0, 6.0, 500_000),
        ModelInfo(ProviderKind.GROK, "grok-4.3", "Grok 4.3", ModelTier.FAST, 1.25, 2.5, 1_000_000),
    )
    /** Mistral: the `-latest` aliases of Large 4, Medium 3.5 and Small 4, all multimodal. */
    val mistral = listOf(
        ModelInfo(ProviderKind.MISTRAL, "mistral-large-latest", "Mistral Large", ModelTier.BEST, 0.5, 1.5, 512_000),
        ModelInfo(ProviderKind.MISTRAL, "mistral-medium-latest", "Mistral Medium", ModelTier.BALANCED, 1.5, 7.5, 256_000),
        ModelInfo(ProviderKind.MISTRAL, "mistral-small-latest", "Mistral Small", ModelTier.FAST, 0.15, 0.6, 256_000),
    )
    /** Cohere: Command A+ (images, reasoning), Command A and Command R7B. */
    val cohere = listOf(
        ModelInfo(ProviderKind.COHERE, "command-a-plus-05-2026", "Command A+", ModelTier.BEST, 0.3, 1.5, 128_000),
        ModelInfo(ProviderKind.COHERE, "command-a-03-2025", "Command A", ModelTier.BALANCED, 2.5, 10.0, 256_000, vision = false),
        ModelInfo(ProviderKind.COHERE, "command-r7b-12-2024", "Command R7B", ModelTier.FAST, 0.0375, 0.15, 128_000, vision = false),
    )
    /** OpenRouter: the same opinion as the Anthropic catalog, through one OpenRouter key; prices as OpenRouter lists them. */
    val openrouter = listOf(
        ModelInfo(ProviderKind.OPENROUTER, "anthropic/claude-opus-5.5", "Claude Opus 5.5 via OpenRouter", ModelTier.BEST, 4.0, 20.0, 1_000_000),
        ModelInfo(ProviderKind.OPENROUTER, "anthropic/claude-sonnet-5.5", "Claude Sonnet 5.5 via OpenRouter", ModelTier.BALANCED, 2.0, 10.0, 1_000_000),
        ModelInfo(ProviderKind.OPENROUTER, "anthropic/claude-haiku-4.5", "Claude Haiku 4.5 via OpenRouter", ModelTier.FAST, 1.0, 5.0, 200_000),
    )
    /** Apple's on-device model: one small text-only model, free, about a 4k-token window. */
    val apple = listOf(ModelInfo(ProviderKind.APPLE, "apple-on-device", "Apple on-device model", ModelTier.FAST, 0.0, 0.0, 4_096, vision = false))
    /** A local server serves whatever model is loaded; the id is the settings' `localModel`. */
    val local = listOf(ModelInfo(ProviderKind.LOCAL, "local", "Local model", ModelTier.BALANCED, 0.0, 0.0, 32_000, vision = false))

    fun models(provider: ProviderKind): List<ModelInfo> = when (provider) {
        ProviderKind.ANTHROPIC -> anthropic; ProviderKind.OPENAI -> openai; ProviderKind.GEMINI -> gemini
        ProviderKind.DEEPSEEK -> deepseek; ProviderKind.KIMI -> kimi; ProviderKind.QWEN -> qwen
        ProviderKind.GROK -> grok; ProviderKind.MISTRAL -> mistral; ProviderKind.COHERE -> cohere; ProviderKind.OPENROUTER -> openrouter
        ProviderKind.APPLE -> apple
        ProviderKind.LOCAL -> local
    }

    val all: List<ModelInfo> get() = ProviderKind.entries.flatMap { models(it) }

    fun model(id: String): ModelInfo? = all.firstOrNull { it.id == id }

    /** The model a provider runs for a profile: the profile's tier, or the nearest one the provider has. */
    fun model(profile: Profile, provider: ProviderKind): ModelInfo {
        val models = models(provider)
        val order = when (profile.tier) {
            ModelTier.FAST -> listOf(ModelTier.FAST, ModelTier.BALANCED, ModelTier.BEST)
            ModelTier.BALANCED -> listOf(ModelTier.BALANCED, ModelTier.BEST, ModelTier.FAST)
            ModelTier.BEST -> listOf(ModelTier.BEST, ModelTier.BALANCED, ModelTier.FAST)
        }
        for (tier in order) models.firstOrNull { it.tier == tier && (!profile.needsVision || it.vision) }?.let { return it }
        return models[0]
    }
}
