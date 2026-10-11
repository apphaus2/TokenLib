# @apphaus/tokenlib

The TypeScript side of [TokenLib](https://github.com/apphaus2/TokenLib): token
management for apps that use AI models, for Node, Cloudflare Workers and React
Native. The **server side** (`TokenServer`) knows the providers, holds API keys
encrypted and keeps the usage ledger; the **client side** (`TokenClient` /
`TokenSession`) opens a session for a *profile* with a budget and gets a reply.
Consumers never learn which vendor or model answered.

```ts
import { AesGcmCipher, ChatMessage, InMemoryStore, TokenClient, TokenServer } from '@apphaus/tokenlib';

const server = new TokenServer(new InMemoryStore(), new AesGcmCipher(process.env.TOKENLIB_CIPHER_KEY!));
await server.activate('anthropic', keyFromTheUser);              // stored encrypted, made active
await server.update((s) => { s.dailyTokenCap = 200_000; });

const session = new TokenClient(server).session('bush', 'character', 20_000);
const reply = await session.stream({ system: persona, messages: [ChatMessage.user('sing')] }, (delta) => speak(delta));
reply.text; reply.usage; reply.stop;                            // 'end' | 'maxTokens' | 'refusal' | 'other'
reply.model; reply.provider;                                    // what answered, for the consumer's records
```

Providers are Anthropic, OpenAI, Google Gemini and any OpenAI-compatible local
server, over plain HTTPS and server-sent events with no vendor SDKs. Profiles and
the model catalog are code; a store holds only keys (ciphertext), a few settings
and usage. The store API is async so SQL-over-the-network stores fit: implement
`TokenStore` for your database and `SecretCipher` for your secret store, or use
`AesGcmCipher` with a key the host supplies (a Worker secret, a value from a
device secure store). There are no UI pieces on this side.

Image parts (`ChatMessage.userParts`) and `ChatRequest.jsonSchema` for structured
replies work the same way as in the Swift and Kotlin packages.

```
npm test          # tests on a fake transport with canned SSE bodies
npm run typecheck
```
