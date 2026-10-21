//
//  AppleProvider.swift
//  TokenLibApple
//
//  Apple's on-device foundation model (Apple Intelligence) as a TokenLib
//  provider: the Foundation Models framework answers in-process, with no key
//  and no network. The framework ships with iOS 26, macOS 26 and visionOS 26;
//  on older SDKs this file compiles to nothing and the kind is not offered.
//

import Foundation
import TokenLib

#if canImport(FoundationModels) && (os(iOS) || os(macOS) || os(visionOS))
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public final class AppleProvider: NativeProvider {
    public let kind: ProviderKind = .apple
    private let model: SystemLanguageModel

    public init(model: SystemLanguageModel = .default) { self.model = model }

    public var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    public var unavailableReason: String? {
        switch model.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This device cannot run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready; try again later."
        case .unavailable: return "Apple Intelligence is not available."
        }
    }

    public func stream(_ chat: ChatRequest, call: ProviderCall, onEvent: @escaping (ChatEvent) -> Void, completion: @escaping (Result<Void, TokenLibError>) -> Void) -> Cancellable {
        let task = Task {
            do {
                let (session, prompt, options) = Self.session(for: chat, call: call, model: model)
                var sent = ""
                for try await snapshot in session.streamResponse(to: prompt, options: options) {
                    try Task.checkCancellation()
                    // Snapshots carry the whole reply so far; TokenLib streams deltas.
                    let whole = snapshot.content
                    if whole.hasPrefix(sent) { onEvent(.text(String(whole.dropFirst(sent.count)))) } else { onEvent(.text(whole)) }
                    sent = whole
                }
                // The framework reports no token counts; the server estimates both sides.
                onEvent(.done(usage: Usage(), stop: .end))
                completion(.success(()))
            } catch is CancellationError {
                completion(.failure(.cancelled))
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .guardrailViolation, .refusal:
                    // A refusal is a stop reason, not an error, as with the HTTP providers.
                    onEvent(.done(usage: Usage(), stop: .refusal))
                    completion(.success(()))
                case .assetsUnavailable:
                    completion(.failure(.unavailable(.apple)))
                default:
                    completion(.failure(.transport(error.localizedDescription)))
                }
            } catch {
                completion(.failure(.transport("\(error)")))
            }
        }
        return TaskCancellable(task: task)
    }

    /// The session for a request: the system prompt (and the JSON schema, as text) as instructions, earlier turns as
    /// the transcript, the last user message as the prompt. Image parts are dropped: the on-device model is text only.
    static func session(for chat: ChatRequest, call: ProviderCall, model: SystemLanguageModel) -> (LanguageModelSession, String, GenerationOptions) {
        var instructions = chat.system ?? ""
        if let schema = chat.jsonSchema, let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) {
            instructions += (instructions.isEmpty ? "" : "\n\n") + "Reply with a single JSON document, and nothing else, that matches this JSON schema:\n" + text
        }
        var entries: [Transcript.Entry] = []
        if !instructions.isEmpty { entries.append(.instructions(Transcript.Instructions(segments: [.text(Transcript.TextSegment(content: instructions))], toolDefinitions: []))) }
        var messages = chat.messages
        let prompt = messages.last?.role == .user ? messages.removeLast().text : ""
        for message in messages where !message.text.isEmpty {
            let segments: [Transcript.Segment] = [.text(Transcript.TextSegment(content: message.text))]
            switch message.role {
            case .user: entries.append(.prompt(Transcript.Prompt(segments: segments)))
            case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: segments)))
            }
        }
        let session = LanguageModelSession(model: model, transcript: Transcript(entries: entries))
        let temperature = chat.temperature ?? call.profile.temperature
        let options = GenerationOptions(temperature: temperature, maximumResponseTokens: chat.maxTokens ?? call.profile.maxTokens)
        return (session, prompt, options)
    }
}

private struct TaskCancellable: Cancellable {
    let task: Task<Void, Never>
    func cancel() { task.cancel() }
}
#endif
