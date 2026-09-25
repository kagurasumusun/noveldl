import SwiftUI

/// Settings — presets editor, cookies, fetch fallback, reading defaults.
struct SettingsView: View {
    @EnvironmentObject private var core: CoreClient

    @AppStorage("downloadIntervalMs") private var intervalMs = 5000
    @AppStorage("browserFetchCommand") private var browserCommand = ""
    @AppStorage("readerTheme") private var readerTheme = BookTheme.paper.rawValue
    @AppStorage("readerFontSize") private var readerFontSize = 19.0
    @AppStorage("readerLineSpacing") private var readerLineSpacing = 6.0

    @State private var presets: [String] = []
    @State private var cookieDomain = ""
    @State private var cookieValue = ""
    @State private var statusText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Parser Presets") {
                    Text("Site extraction rules live in YAML — new sites need no app release.")
                        .font(AppFont.ui(12))
                        .foregroundStyle(.secondary)
                    ForEach(presets, id: \.self) { domain in
                        NavigationLink {
                            PresetEditorView(domain: domain)
                        } label: {
                            HStack {
                                Text(domain)
                                    .font(AppFont.ui(14, design: .monospaced))
                                Spacer()
                            }
                        }
                    }
                }

                Section("Fetching") {
                    Stepper(value: $intervalMs, in: 1000...30000, step: 500) {
                        LabeledContent("Min interval") {
                            Text("\(intervalMs / 1000)s \(intervalMs % 1000)")
                        }
                    }
                    .onChange(of: intervalMs) {
                        core.setDownloadInterval(ms: UInt32(intervalMs))
                    }
                    TextField("Browser fetch command (challenge fallback)", text: $browserCommand)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: browserCommand) {
                            core.setBrowserFetch(command: browserCommand.isEmpty ? nil : browserCommand)
                        }
                }

                Section("Cookies") {
                    TextField("domain (example.com)", text: $cookieDomain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("name=value; name2=value2", text: $cookieValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Store Cookie") {
                        let d = cookieDomain.trimmingCharacters(in: .whitespaces)
                        let v = cookieValue.trimmingCharacters(in: .whitespaces)
                        guard !d.isEmpty, !v.isEmpty else { return }
                        core.setDomainCookie(domain: d, cookie: v)
                        statusText = "Stored cookies for \(d)"
                    }
                }

                Section("Reading Defaults") {
                    Picker("Theme", selection: $readerTheme) {
                        ForEach(BookTheme.allCases) { theme in
                            Text(theme.label).tag(theme.rawValue)
                        }
                    }
                    Stepper(value: $readerFontSize, in: 14...28) {
                        LabeledContent("Text size") { Text("\(Int(readerFontSize))") }
                    }
                    Stepper(value: $readerLineSpacing, in: 0...16) {
                        LabeledContent("Line spacing") { Text("\(Int(readerLineSpacing))") }
                    }
                }

                if let statusText {
                    Section {
                        Text(statusText)
                            .font(AppFont.ui(12))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    LabeledContent("Version", value: "Bookmarks 2.0 (C core)")
                } footer: {
                    Text("Powered by novel_core — YAML-driven multi-site downloader.")
                }
            }
            .navigationTitle("Settings")
            .task {
                presets = (try? await core.listPresets()) ?? []
            }
        }
    }
}

/// YAML preset editor — site support without shipping code.
struct PresetEditorView: View {
    let domain: String
    @EnvironmentObject private var core: CoreClient
    @State private var yaml = ""
    @State private var statusText: String?

    var body: some View {
        Form {
            Section("YAML — \(domain)") {
                TextEditor(text: $yaml)
                    .font(AppFont.ui(12, design: .monospaced))
                    .frame(minHeight: 320)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section {
                Button("Save") {
                    Task {
                        try? await core.savePreset(domain: domain, yaml: yaml)
                        statusText = "Saved."
                    }
                }
                Button("Remove user overlay", role: .destructive) {
                    Task {
                        try? await core.deletePreset(domain: domain)
                        statusText = "Overlay removed — builtin restored."
                    }
                }
            }
            if let statusText {
                Section { Text(statusText).font(AppFont.ui(12)).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(domain)
        .task {
            yaml = (try? await core.loadPreset(domain: domain)) ?? ""
        }
    }
}
