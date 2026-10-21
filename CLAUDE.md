# TokenLib

Token management for apps that use AI models, in the same process as the
app. The **server side** (`TokenServer`) knows the providers, holds API keys
encrypted in SQLite, keeps the usage ledger and picks a model per profile.
The **client side** (`TokenClient` / `TokenSession`) is what a library holds:
a session for a profile with a budget that streams replies. Consumers never
learn which vendor or model answered.

TokenLib is a standalone library: it must not know about JsonMind, JsonScene or
QRX. Adapters live with the consumers (JsonMind's TokenLib adapter).
`docs/TOKENLIB.md` is the reference; `docs/INTEGRATION.md` is the guide for
projects that adopt the library.

## Layout

```
Package.swift               products TokenLib, TokenLibApple, TokenLibUI; CSQLite system library (pkg-config sqlite3 on Linux only)
ios/Sources/TokenLib          Catalog (ProviderKind anthropic/openai/gemini/deepseek/kimi/qwen/grok/mistral/cohere/openrouter/apple/local,
                            ModelTier, ModelInfo, Profile
                            character/assistant/fast/vision), Chat types (ChatPart text/image, ChatMessage.parts,
                            ChatRequest.jsonSchema, ChatReply.model/provider), Transport (URLSession + SSE parser),
                            Provider protocol, Providers/{Anthropic,OpenAI,Gemini}Provider (OpenAIProvider serves every
                            OpenAI-compatible kind through a per-kind Dialect table), NativeProvider (in-process providers,
                            filled per platform), Store (SecretCipher, KeyRepository, Settings incl. the `enabled` master
                            switch, UsageRecord/UsageTotals, TokenStore, InMemoryStore), SQLiteStore (sqlite3 C API),
                            TokenServer, TokenClient/TokenSession
ios/Sources/TokenLibApple     KeychainCipher (CryptoKit AES-GCM, key in Keychain), AppleProvider (Foundation Models, iOS 26+),
                            TokenLibBootstrap.standard(appId:) / registerPlatformProviders(on:), TokenLibModel (ObservableObject)
ios/Sources/TokenLibUI        SwiftUI pieces: TokenLibSettingsSection, TokenLibUsageView, TokenLibUsageRow, TokenLibRemainingView, TokenLibStatusBadge
ios/Tests/TokenLibTests       30 tests with FakeTransport and canned SSE bodies
android/tokenlib-core         Kotlin/JVM mirror; MiniJson (no serialization dependency); JdbcSqlDatabase for tests; 30 tests
android/tokenlib-android      AndroidSqlDatabase, KeystoreCipher, TokenLib.standard(context)
android/tokenlib-compose      TokenLibModel (Compose state), TokenLibSettings, TokenLibUsage, TokenLibUsageRow, TokenLibRemaining, TokenLibStatusBadge
js/                         TypeScript mirror, npm package `@apphaus/tokenlib` (Node / Workers / React Native): src/*.ts file for file
                            with ios/Sources/TokenLib, fetch + ReadableStream transport, async TokenStore, InMemoryStore,
                            AesGcmCipher (WebCrypto, host-supplied key); no UI pieces; test/*.test.ts, 28 vitest tests
```

## Build and test

```
swift test                                   # Linux (libsqlite3-dev) or macOS
cd android && ./gradlew build                # JVM tests plus the Android and Compose AARs
cd js && npm ci && npm run typecheck && npm test
```

## Design decisions (agreed with the owner)

- No vendor SDKs: Anthropic Messages API, OpenAI chat completions and Gemini
  `streamGenerateContent` over plain HTTPS and server-sent events. Every other vendor is
  OpenAI-compatible and shares OpenAIProvider through a per-kind `Dialect` (endpoint, token
  parameter, temperature, stream usage, JSON mode, reasoning switch), kept identical on all three
  sides: DeepSeek (api.deepseek.com), Kimi (api.moonshot.ai), Qwen (dashscope-intl.aliyuncs.com
  compatible mode, the shared international endpoint), Grok (api.x.ai), Mistral (api.mistral.ai),
  Cohere (api.cohere.com/compatibility/v1) and OpenRouter (openrouter.ai/api/v1).
  `max_completion_tokens` for OpenAI and Kimi, `max_tokens` elsewhere; no temperature for OpenAI,
  Kimi or OpenRouter; `stream_options.include_usage` except for Cohere (undocumented there) and
  OpenRouter (always sends usage). The profile's effort drives each vendor's reasoning: DeepSeek
  `thinking`, Kimi `reasoning_effort` on K3 / `thinking` on K2, Qwen `enable_thinking`, Grok and
  Mistral `reasoning_effort` (Mistral `none`/`high`), Cohere `reasoning_effort` `none`/`high` on the
  A+ and reasoning models only, OpenRouter `reasoning` `{enabled: false}` / `{effort}`; low turns
  thinking off wherever it can be. JSON schema: `json_schema` where enforced (OpenAI, Kimi, Grok,
  Mistral, OpenRouter, local); `json_object` with the schema appended to the system prompt for
  DeepSeek and Qwen; Cohere's `{type: json_object, schema}`. OpenRouter's catalog is the Anthropic
  trio through one OpenRouter key.
- Apple Intelligence (`ProviderKind.apple`) is the one provider that is not HTTP: `AppleProvider` in
  TokenLibApple drives the Foundation Models framework in-process through the `NativeProvider` seam on
  `TokenServer.nativeProviders`, which the bootstrap fills only where the framework exists (iOS 26, macOS 26,
  visionOS 26). The kind exists in Kotlin and TypeScript so the catalogs stay in step, but nothing fills the
  seam there, so `availableProviders` never offers it. No key, no cost, no token counts (usage is estimated),
  text only, schema asked for in the prompt.
- `Settings.enabled` is the master switch the settings UI shows first; off, `isReady` is false and `stream`
  fails with `disabled` before touching a provider. Everything else in settings stays put.
- Providers, the model catalog and profiles are opinionated code, not database rows.
  The database holds only keys (ciphertext), a few settings and usage.
- Anthropic requests on 5-generation models send `output_config.effort` and no sampling
  parameters; Opus 5.5 and Sonnet 5.5 requests also send `anthropic-beta: server-side-fallback-2026-07-01`
  with `"fallbacks": "default"`. OpenAI streams with `stream_options.include_usage`.
- Image parts are allowed on every profile; the catalog's `vision` flag picks the model. Wire mapping:
  Anthropic base64 image blocks, OpenAI `image_url` data URIs, Gemini `inlineData`; the estimate adds
  about 1,600 tokens per image. `jsonSchema` maps to Anthropic `output_config.format`, OpenAI
  `response_format` and Gemini `responseMimeType: application/json`.
- Repository pattern over SQLite; the app is free to query for its own UI, but the
  UI packages exist so most apps embed `TokenLibSettingsSection` / `TokenLibSettings` and pick up
  new requirements by updating the package. UI pieces use platform controls in the host's
  theme, with no navigation or branding.
- Speech-to-text is not TokenLib's concern; it stays in the app.
- Keep Swift, Kotlin and TypeScript in step, with tests on all three sides. The TS store API is
  async and the TS package has no UI pieces; publishing `@apphaus/tokenlib` to npm is a separate step.

## Keep the integration guide current

`docs/INTEGRATION.md` is what adopting projects follow, so it must never lag
the code. Any change that touches what a host or consumer sees updates the
guide in the same commit: a public type, initializer, method or property on
`TokenServer`, `TokenClient`, `TokenSession`, `ChatRequest`, `ChatMessage`,
`ChatReply`, `Settings` or the UI pieces; a new or removed provider, profile
or error case; a change to how a package is added, bootstrapped or tested;
a new platform. Keep its snippets runnable against the current API on all
three platforms, keep the numbered sections and the closing checklist, and
add a section rather than a footnote when a feature changes how a project
integrates. When in doubt whether a change belongs there: if an adopter would
have to read the source to learn it, it belongs in the guide.

## Gotchas

- Anything under `#if canImport(SwiftUI)` or `canImport(Combine)` is skipped on Linux, so
  TokenLibApple's model and all of TokenLibUI are only compiled in Xcode. Check their API use
  against Store.swift and TokenServer.swift by hand, and parse-check with `swiftc -parse`.
- The SSE parsers flush the last event in `finish()` by feeding an empty line; fixtures
  need not end with a blank line.
- Budget and daily-cap tests use exact thresholds (budget 36, cap 36); keep the fake
  usage numbers in step when changing accounting.
- The Android build needs a JDK 17 or newer (AGP 8.11; the core still targets 17 bytecode) and an
  Android SDK with platform 35 or newer, found through `ANDROID_HOME` or a gitignored
  `android/local.properties` with `sdk.dir=/path/to/sdk` (Android Studio's is `~/Library/Android/sdk`).
  `./gradlew :tokenlib-core:test` runs the 30 JVM tests without any SDK. Don't add JDK toolchain or
  SDK plumbing to the build files here; consumers adapt their subtree copy to their machines. `js`
  needs Node 20 or newer for vitest 4 and a global `crypto` (on Node 18,
  `NODE_OPTIONS=--experimental-global-webcrypto` and an older vitest work). `swift build` on macOS compiles TokenLibApple and TokenLibUI too, so it is the
  compile check for AppleProvider and the SwiftUI pieces.
- Work lands on `master` directly; feature branches are deleted once merged.
- The library was TokenX until October 2026. `TokenLibBootstrap.legacyDatabase` /
  `legacyKeySuffix` (Swift) and `TokenLib.LEGACY_DATABASE` / `LEGACY_KEY_SUFFIX` (Android) keep
  the old `tokenx` names on purpose so existing installs migrate; never rename them in a
  find-and-replace. Section 11 of the integration guide documents the upgrade.
