# TokenLib

TokenLib separates two things that usually get tangled: **managing** access to
AI models (which providers, whose keys, which model for which job, how much
was spent) and **using** them (an actor that wants a reply, a screen that
wants a summary). Both halves run in the same process; the consumer never
sees a key, a model name or a vendor.

```
  app settings ──► TokenServer ──► Provider (Anthropic | OpenAI | Gemini | DeepSeek | Kimi | Qwen | Grok | Mistral | Cohere | OpenRouter | local)
  (keys, active     │  store: keys (encrypted), settings, usage
   provider, caps)  │  policy: daily cap, profile → model, cost
                    ▼
  library/screen ◄─ TokenClient ─ TokenSession(consumer, profile, budget)
```

A project adopting the library should start with [INTEGRATION.md](INTEGRATION.md),
the how-to; this page is the reference.

## The client side

A consumer holds a `TokenClient` and opens sessions:

```swift
let client = TokenClient(broker: server)             // the app hands this over
let session = client.session(consumer: "bush", profile: .character, budget: 20_000)
session.stream(ChatRequest(system: persona, messages: [.user("sing")]),
               onText: { delta in speak(delta) },
               completion: { result in /* ChatReply: text, usage, stop */ })
```

```kotlin
val session = TokenClient(server).session("bush", Profile.CHARACTER, budget = 20_000)
session.stream(ChatRequest(persona, listOf(ChatMessage.user("sing"))), { delta -> speak(delta) }) { result -> }
```

```ts
const session = new TokenClient(server).session('bush', 'character', 20_000);
const reply = await session.stream({ system: persona, messages: [ChatMessage.user('sing')] }, (delta) => speak(delta));
```

- **Profile** names the intent, never the model: `character` (short, warm, low
  effort), `assistant` (careful, longer), `fast` (cheap and quick), `vision`.
- **Consumer** is a free name for usage rows (an actor id, a screen).
- **Budget** is the session's own token allowance. The server's daily cap
  applies on top. `remaining`, `spent` and `isExhausted` are on the session.
- A message is text, or text and image parts: `ChatMessage.user(parts:)` with
  `.text` and `.image(data:mediaType:)` (base64, no `data:` prefix). Image parts
  are allowed on every profile; the catalog's `vision` flag picks a model that can
  see them. Each image counts about 1,600 tokens in the estimate.
- `ChatRequest.jsonSchema` asks for a reply that validates against a JSON schema;
  the reply text is then the JSON document.
- The reply streams as text deltas and ends with `Usage` (prompt and reply
  tokens) and a `StopReason` (`end`, `maxTokens`, `refusal`, `other`). The
  `ChatReply` also names the `model` and `provider` that answered, for the
  consumer's records; consumers still never choose them.
- Errors: `noProvider`, `missingKey`, `budgetExhausted`, `dailyCapReached`,
  `http(status, body)`, `transport`, `cancelled`.

`TokenBroker` is the interface between the halves. `TokenServer` implements
it in-process; a remote or out-of-process broker would implement the same
interface without touching consumers.

## The server side

The app owns a `TokenServer` and builds its settings screens on it. Nothing
about providers or profiles is stored: they are code (`Catalog`, `Profile`).
The store holds only:

| table | rows |
| --- | --- |
| `keys` | provider → API key ciphertext |
| `settings` | active provider, local server URL and model, daily token cap, whether prompts are logged, the credit entered per provider |
| `usage` | one row per request: time, consumer, profile, provider, model, prompt and reply tokens, cost in micro-dollars, stop reason, optional prompt and reply text |

```swift
let server = TokenServer(store: try SQLiteStore(path: dbPath), cipher: KeychainCipher())
try server.activate(.anthropic, key: keyFromTheUser)    // stores the key encrypted, makes it active
server.isReady                                           // a provider is active and has what it needs
server.model(for: .character)                            // what would run right now
server.usageToday(), server.recentUsage(limit: 50)       // for the usage screen
server.remainingToday()                                  // tokens left under the daily cap; nil without one
try server.setCredit(50_000_000, for: .anthropic)        // the balance from the provider's billing page, in micro-dollars
server.credit()?.remainingMicros                         // that balance minus what TokenLib has charged the provider since
try server.update { $0.dailyTokenCap = 200_000 }
```

Queries for lists and options come from the server (`configuredProviders`,
`ProviderKind.allCases`, `Catalog.models(for:)`, `usage(since:consumer:)`),
so an app can draw its own UI. Most apps will not need to:

### Bootstrap, model and UI pieces

`TokenLibApple` / `tokenlib-android` build the standard server in one call, and
the observable `TokenLibModel` wraps it for screens:

```swift
let ai = TokenLibModel(appId: "us.apphaus.myapp")     // TokenLibBootstrap.standard(appId:) underneath:
                                                  // Application Support/<appId>/tokenlib.sqlite, KeychainCipher(service: appId + ".tokenlib")
ai.settings, ai.configured, ai.usageToday, ai.recent, ai.lastError   // @Published
ai.activate(.anthropic, key: text); ai.removeKey(for: .openai); ai.update { $0.dailyTokenCap = 200_000 }
ai.setLocalServer(url: "http://host:11434/v1", model: "llama3"); ai.clearUsage()
ai.isReady; ai.modelName(for: .character)         // "Claude Opus 5.5 (Anthropic)"
ai.client.session(consumer: "bush", profile: .character, budget: 20_000)
```

```kotlin
val ai = TokenLibModel(context)                     // TokenLib.standard(context): noBackupFilesDir/tokenlib.sqlite, KeystoreCipher("<package>.tokenlib")
ai.settings; ai.configured; ai.usageToday; ai.recent; ai.lastError    // Compose state
ai.activate(ProviderKind.ANTHROPIC, text); ai.removeKey(...); ai.update { it.copy(dailyTokenCap = 200_000) }
```

`TokenLibUI` (SwiftUI) and `tokenlib-compose` hold the pieces a host embeds in
its own settings and status screens. They use platform controls in the
host's theme and bring no navigation or branding:

| piece | SwiftUI | Compose |
| --- | --- | --- |
| provider picker, key entry, local server URL and model, activate / remove key, prompt logging, today's usage, active model line | `TokenLibSettingsSection(model:title:)` inside a `Form` | `TokenLibSettings(model, modifier, title)` inside a `Column` |
| today's and 30-day totals, recent requests, clear | `TokenLibUsageView(model:)` | `TokenLibUsage(model, modifier)` |
| one line of totals | `TokenLibUsageRow(totals:label:)` | `TokenLibUsageRow(label, totals)` |
| what is left, for a main screen: the credit entered counted down by this app's spend, else tokens remaining under the daily cap, else today's totals | `TokenLibRemainingView(model:)` | `TokenLibRemaining(model, modifier)` |
| readiness indicator | `TokenLibStatusBadge(model:)` | `TokenLibStatusBadge(model)` |

When a later TokenLib needs something new from the user (another provider, a
different setting), the section grows and the host app only updates the
package.

### Secrets

Keys are encrypted before they reach SQLite. The cipher is the platform's:
`KeychainCipher` (TokenLibApple) keeps an AES-GCM key in the Keychain, device
only and not backed up; `KeystoreCipher` (tokenlib-android) keeps it in the
Android Keystore; `AesGcmCipher` (`@apphaus/tokenlib` on npm) does AES-GCM over WebCrypto
with a key the host supplies, such as a Worker secret or a value from a device
secure store. `PlainCipher` exists for tests. The database itself lives in the
app's private, no-backup storage.

`TokenServer.reencryptKeys(from:)` moves every stored key from an old cipher to
the server's own, for rotating a cipher key. The standard bootstraps use it,
with `SQLiteStore.moveDatabase(from:to:)`, to carry installs from the TokenX
names (`tokenx.sqlite`, `<appId>.tokenx`) to the TokenLib ones once; see
INTEGRATION.md section 11.

### Providers

Providers are plain HTTPS with server-sent events; no vendor SDKs, so Swift,
Kotlin and TypeScript behave identically and the core is testable with a fake
transport.

| provider | endpoint | images | JSON schema | notes |
| --- | --- | --- | --- | --- |
| Anthropic | `POST /v1/messages`, `stream: true` | base64 image content blocks | `output_config.format` `{type: json_schema, schema}` | `output_config.effort` from the profile on the 5-generation models; sampling parameters are not sent there. Opus 5.5 and Sonnet 5.5 requests send `anthropic-beta: server-side-fallback-2026-07-01` and `"fallbacks": "default"` |
| OpenAI | `POST /v1/chat/completions`, `stream: true`, `stream_options.include_usage` | `image_url` data URIs | `response_format` `json_schema` | |
| Gemini | `POST /v1beta/models/{model}:streamGenerateContent?alt=sse` | `inlineData` parts | `responseMimeType: application/json` | |
| DeepSeek | `https://api.deepseek.com/chat/completions`, OpenAI-compatible | `image_url` data URIs (Flash only) | `response_format: json_object`, schema appended to the system prompt | `max_tokens`, temperature; the profile's effort sets `thinking` (`disabled` for low, `enabled` + `reasoning_effort` for high) |
| Kimi (Moonshot) | `https://api.moonshot.ai/v1/chat/completions`, OpenAI-compatible | `image_url` data URIs | `response_format` `json_schema` | `max_completion_tokens`, no temperature (fixed per model); effort sets `reasoning_effort` on K3 and `thinking` on K2 |
| Qwen (Alibaba) | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions`, the shared international Model Studio endpoint | `image_url` data URIs | `response_format: json_object`, schema appended to the system prompt | `max_tokens`, temperature; effort sets `enable_thinking` |
| Grok (xAI) | `https://api.x.ai/v1/chat/completions`, OpenAI-compatible | `image_url` data URIs | `response_format` `json_schema` | `max_tokens`, temperature; Grok 4 always reasons, the effort sets `reasoning_effort` |
| Mistral | `https://api.mistral.ai/v1/chat/completions`, OpenAI-compatible | `image_url` data URIs | `response_format` `json_schema` | `max_tokens`, temperature; effort sets `reasoning_effort` (`none` or `high`) |
| Cohere | `https://api.cohere.com/compatibility/v1/chat/completions`, Cohere's OpenAI compatibility API | `image_url` data URIs (Command A+; not documented for the compatibility API) | `response_format: {type: json_object, schema}` | `max_tokens`, temperature; `reasoning_effort` `none` or `high` on Command A+ and the reasoning models; no `stream_options`, usage is estimated when the stream carries none |
| OpenRouter | `https://openrouter.ai/api/v1/chat/completions`, OpenAI-compatible | `image_url` data URIs | `response_format` `json_schema` | `max_tokens`, no temperature (it depends on the routed model); effort sets `reasoning` `{enabled: false}` or `{effort: high}`; usage comes in the last chunk unasked |
| local | an OpenAI-compatible server (Ollama, LM Studio, vLLM) at `Settings.localBaseURL`; no key | as OpenAI | as OpenAI | model name from `Settings.localModel` |

The OpenAI-compatible vendors share one provider with a per-vendor dialect:
endpoint, token parameter, whether a temperature is sent, how usage is asked
for, how a schema is passed and how reasoning is switched. Models that think
by default bill the reasoning as output, so the low-effort profiles
(`character`, `fast`) turn thinking off wherever the vendor allows and the
high-effort ones (`assistant`, `vision`) leave it on.

### Catalog and profiles

The catalog lists three models per provider by tier (`fast`, `balanced`,
`best`) with prices for the cost column; for Anthropic these are Claude Opus 5.5
($4 / $20 per million tokens), Sonnet 5.5 ($2 / $10) and Haiku 4.5 ($1 / $5).
DeepSeek has V4 Pro (best, $1.32 / $3.96 at peak, text only) and Flash (fast,
$0.30 / $1.20, takes images); Kimi has K3 (best, $3 / $15) and K2.6 (balanced,
$0.95 / $4); Qwen has 3.8 Max (best, $2 / $6), 3.7 Plus (balanced, $0.40 / $1.60)
and 3.8 Flash (fast, $0.15 / $0.47), all multimodal. Grok has 4.7 (best, $2 / $6)
and 4.3 (fast, $1.25 / $2.50), both with images; Mistral has the `-latest`
aliases of Large (best, $0.50 / $1.50), Medium (balanced, $1.50 / $7.50) and
Small (fast, $0.15 / $0.60); Cohere has Command A+ (best, $0.30 / $1.50, images),
Command A (balanced, $2.50 / $10) and Command R7B (fast, $0.0375 / $0.15);
OpenRouter carries the Anthropic trio at OpenRouter's prices, so one OpenRouter
key gives the same opinion. A provider without a tier serves the nearest one it
has. A profile asks for a tier; the
active provider's model of that tier serves it (or the nearest tier the
provider has). Editing the catalog is a code change on purpose: it is the
opinion TokenLib ships with.

### Policy

- **Daily cap**: `Settings.dailyTokenCap` across every consumer; checked
  against today's usage plus the request's estimated prompt before sending.
- **Session budget**: per `TokenSession`, checked the same way.
- **Credit**: providers do not report balances to API keys, so the user enters the
  balance from the provider's billing page (`Settings.credits`, per provider) and each
  recorded request adds its cost to the credit's own `spentMicros`. It is an estimate
  from catalog prices, sees only this app's use of the key, and survives clearing usage.
- **Usage** is recorded once per successful request with the provider's
  reported tokens (estimated when a provider reports none). Failed requests
  cost nothing.
- **Prompt logging** is off by default; `Settings.logPrompts` keeps the last
  user message and the reply on the usage row.

## Layout

```
docs/TOKENLIB.md            this reference; docs/INTEGRATION.md the adopter's guide
Package.swift             Swift manifest (root, so SwiftPM can add the package by URL)
ios/Sources/TokenLib        catalog, chat types, transport, providers, store, SQLiteStore, server, client
ios/Sources/TokenLibApple   KeychainCipher, TokenLibBootstrap.standard(appId:), TokenLibModel (ObservableObject)
ios/Sources/TokenLibUI      TokenLibSettingsSection, TokenLibUsageView, TokenLibUsageRow, TokenLibRemainingView, TokenLibStatusBadge (SwiftUI)
ios/Sources/CSQLite       sqlite3 module map for Linux
ios/Tests/TokenLibTests     28 tests with a fake transport and an in-memory / temp SQLite store
android/tokenlib-core       Kotlin/JVM mirror (JDBC SQLite for desktop and tests), 28 tests
android/tokenlib-android    AndroidSqlDatabase, KeystoreCipher, TokenLib.standard(context)
android/tokenlib-compose    TokenLibModel (Compose state), TokenLibSettings, TokenLibUsage, TokenLibUsageRow, TokenLibRemaining, TokenLibStatusBadge
js/                       TypeScript mirror, npm `@apphaus/tokenlib`: src/*.ts file for file with ios/Sources/TokenLib, fetch transport,
                          async TokenStore, AesGcmCipher; no UI pieces; 26 vitest tests
```

| platform | package | secrets |
| --- | --- | --- |
| iOS, macOS | Swift package `TokenLib` (+ `TokenLibApple`, `TokenLibUI`) | Keychain-held AES-GCM key |
| Android, JVM | Gradle modules `tokenlib-core`, `tokenlib-android`, `tokenlib-compose` | Android Keystore AES-GCM key |
| Node, Workers, React Native | npm `@apphaus/tokenlib` (async store API, no UI pieces) | host-supplied AES-GCM key (`AesGcmCipher`) |
