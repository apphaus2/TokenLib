//
//  TokenLibSettingsSection.swift
//  TokenLibUI
//
//  The settings a host app embeds in its own Form: provider, key, local
//  server, prompt logging, today's usage. Platform controls, host theme, no
//  navigation of its own. Keys never leave the field unencrypted: they go
//  straight to the server, which stores ciphertext.
//

#if canImport(SwiftUI) && canImport(Combine)
import SwiftUI
import TokenLib
import TokenLibApple

public struct TokenLibSettingsSection: View {
    @ObservedObject private var model: TokenLibModel
    private let title: String
    @State private var provider: ProviderKind = .anthropic
    @State private var key = ""
    @State private var credit = ""
    @State private var localURL = ""
    @State private var localModel = ""

    public init(model: TokenLibModel, title: String = "AI provider") {
        self.model = model
        self.title = title
    }

    public var body: some View {
        Section(header: Text(title), footer: Text(footer)) {
            Picker("Provider", selection: $provider) {
                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    Text(model.hasKey(kind) ? "\(kind.displayName) ✓" : kind.displayName).tag(kind)
                }
            }
            if provider.needsKey {
                SecureField(model.hasKey(provider) ? "API key (stored; enter to replace)" : "API key", text: $key)
                    .textContentType(.password)
                    #if os(iOS) || os(tvOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disableAutocorrection(true)
                HStack {
                    TextField(creditPrompt, text: $credit)
                        #if os(iOS) || os(tvOS)
                        .keyboardType(.decimalPad)
                        #endif
                    Button("Set") { model.setCredit(creditAmount, for: provider); credit = "" }
                        // tvOS has .borderless only from 17, and the focus engine reaches a row's buttons anyway.
                        #if !os(tvOS)
                        .buttonStyle(.borderless)
                        #endif
                        .disabled(creditAmount == nil)
                }
            } else {
                TextField("Server URL, e.g. http://192.168.1.20:11434/v1", text: $localURL)
                    #if os(iOS) || os(tvOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .disableAutocorrection(true)
                TextField("Model name, e.g. llama3", text: $localModel)
                    #if os(iOS) || os(tvOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .disableAutocorrection(true)
            }
            Button(isActive ? "Active" : "Use \(provider.displayName)") {
                if !provider.needsKey { model.setLocalServer(url: localURL, model: localModel) }
                model.activate(provider, key: key)
                key = ""
            }
            .disabled(provider.needsKey && key.isEmpty && !model.hasKey(provider))
            if model.hasKey(provider) {
                Button("Remove key", role: .destructive) { model.removeKey(for: provider) }
            }
            Toggle("Keep prompts in the usage log", isOn: Binding(get: { model.settings.logPrompts }, set: { on in model.update { $0.logPrompts = on } }))
            TokenLibUsageRow(totals: model.usageToday, label: "Today")
            if let error = model.lastError { Text(error).font(.caption).foregroundColor(.red) }
        }
        .onAppear {
            model.refresh()
            provider = model.settings.activeProvider ?? .anthropic
            localURL = model.settings.localBaseURL ?? ""
            localModel = model.settings.localModel ?? ""
        }
    }

    private var isActive: Bool { model.settings.activeProvider == provider && key.isEmpty && (!provider.needsKey || model.hasKey(provider)) }

    private var creditAmount: Double? { Double(credit.replacingOccurrences(of: ",", with: ".")).flatMap { $0 >= 0 ? $0 : nil } }

    private var creditPrompt: String {
        if let c = model.settings.credits[provider] { return String(format: "≈ $%.2f left; enter a new balance", c.remainingUSD) }
        return "Credit balance in $ (optional)"
    }

    private var footer: String {
        if let name = model.modelName(for: .character), model.isReady { return "Characters answer with \(name)." }
        return "Pick a provider and enter its API key. Keys are stored encrypted on this device. Enter the balance from the provider's billing page to see what is left; it counts this app's use only."
    }
}

/// One line of usage totals.
public struct TokenLibUsageRow: View {
    public let totals: UsageTotals
    public let label: String

    public init(totals: UsageTotals, label: String) { self.totals = totals; self.label = label }

    public var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(String(format: "%d requests · %d tokens · $%.4f", totals.requests, totals.totalTokens, totals.costUSD))
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
        }
    }
}

/// What is left, for a main screen: the provider credit the user entered counted down by this app's spend,
/// else tokens remaining under the daily cap, else today's usage (the settings line). The host calls
/// `model.refresh()` after a request.
public struct TokenLibRemainingView: View {
    @ObservedObject private var model: TokenLibModel

    public init(model: TokenLibModel) { self.model = model }

    public var body: some View {
        if let credit = model.credit {
            meter("AI credit left", String(format: "≈ $%.2f of $%.2f", credit.remainingUSD, credit.totalUSD), Double(credit.remainingMicros) / Double(max(credit.micros, 1)))
        } else if let left = model.remainingToday, let cap = model.settings.dailyTokenCap {
            meter("AI left today", "\(left.formatted()) of \(cap.formatted()) tokens", Double(left) / Double(max(cap, 1)))
        } else {
            TokenLibUsageRow(totals: model.usageToday, label: "AI today").font(.caption)
        }
    }

    private func meter(_ label: String, _ value: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(value).monospacedDigit().foregroundColor(fraction > 0 ? .secondary : .red)
            }
            ProgressView(value: min(max(fraction, 0), 1)).tint(fraction > 0 ? .accentColor : .red)
        }
        .font(.caption)
    }
}

/// Recent requests, newest first, for a usage screen.
public struct TokenLibUsageView: View {
    @ObservedObject private var model: TokenLibModel

    public init(model: TokenLibModel) { self.model = model }

    public var body: some View {
        List {
            Section {
                TokenLibUsageRow(totals: model.usageToday, label: "Today")
                TokenLibUsageRow(totals: model.server.usage(since: Date(timeIntervalSinceNow: -30 * 86400)), label: "30 days")
            }
            Section(header: Text("Recent")) {
                if model.recent.isEmpty { Text("No requests yet").foregroundColor(.secondary) }
                ForEach(model.recent, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.consumer).bold()
                            Spacer()
                            Text(row.at, style: .time).font(.caption).foregroundColor(.secondary)
                        }
                        Text("\(row.model) · \(row.profile.rawValue) · \(row.promptTokens) in, \(row.replyTokens) out · $\(String(format: "%.4f", Double(row.costMicros) / 1_000_000))")
                            .font(.caption).foregroundColor(.secondary)
                        if let prompt = row.prompt { Text(prompt).font(.caption2).lineLimit(2) }
                    }
                }
            }
            Section { Button("Clear usage", role: .destructive) { model.clearUsage() } }
        }
        .onAppear { model.refresh() }
    }
}

/// A small readiness indicator for a toolbar or a status line.
public struct TokenLibStatusBadge: View {
    @ObservedObject private var model: TokenLibModel

    public init(model: TokenLibModel) { self.model = model }

    public var body: some View {
        Label(model.isReady ? (model.activeProvider?.displayName ?? "Ready") : "No AI provider", systemImage: model.isReady ? "brain" : "brain.head.profile")
            .font(.caption)
            .foregroundColor(model.isReady ? .primary : .secondary)
    }
}
#endif
