import SwiftUI

@available(iOS 17.0, *)
struct SettingsScreen: View {
    @State private var model = SettingsViewModel()
    @State private var showingResetConfirmation = false
    @Environment(\.dismiss) private var dismiss

    /// Drives the live cache-usage line under the download cache limit picker. The store is
    /// `@Observable`, so reading `entries` here re-renders the view when downloads land or
    /// the cache eviction sweep deletes files.
    @State private var downloads = DownloadsStore.shared

    /// Observed so the "Save logs to file" section re-renders when the writer opens / closes
    /// the current log file.
    @State private var logWriter = LogFileWriter.shared

    /// Wraps a single URL for the Share sheet. Optional because the sheet only presents when
    /// the user taps "Share latest log" AND there's a file to share. `nil` → sheet not shown.
    @State private var shareLogURL: URL?

    /// "Are you sure?" confirmation for the destructive Clear-all-logs button.
    @State private var showingClearLogsConfirmation = false
    @State private var showingClearHistoryConfirmation = false

    private var currentCacheBytes: Int64 {
        downloads.entries.reduce(0) { $0 + $1.fileSize }
    }

    private var formattedCacheUsage: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: currentCacheBytes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Preferred quality", selection: Bindable(model).preferredQuality) {
                        ForEach(VideoQuality.allCases) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    Toggle("Autoplay next video", isOn: Bindable(model).autoplayNext)
                    Toggle("Show watch progress bars", isOn: Bindable(model).showHistoryProgressBars)
                    Toggle("Show comments", isOn: Bindable(model).showComments)
                    Toggle("Show Up Next", isOn: Bindable(model).showUpNext)
                    if model.showUpNext {
                        Stepper(value: Bindable(model).upNextInitialCount, in: 3...15) {
                            LabeledContent("Initial Up Next videos") {
                                Text("\(model.upNextInitialCount)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle("Prefetch details and comments", isOn: Bindable(model).prefetchVideoDetails)
                    Toggle("Allow audio from other apps", isOn: Bindable(model).allowAudioMixing)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Prefetching starts only after playback is ready and loads the description plus the first comments page when comments are enabled. Further comments and replies remain on demand.\n\nAllowing audio from other apps lets FreeTube play alongside music, podcasts, and other active audio. The app that owns lock-screen controls can depend on which one started first.")
                }

                Section("Search") {
                    Toggle("Restricted search mode", isOn: Bindable(model).restrictedSearchMode)
                }

                Section {
                    Toggle("Show subscription feed tab", isOn: Bindable(model).showSubscriptionFeedTab)
                    Toggle("Show Music tab", isOn: Bindable(model).showMusicTab)
                } header: {
                    Text("Feed")
                } footer: {
                    Text("Hiding the tab keeps your local subscriptions and cached feed on this device.")
                }

                Section {
                    Toggle("OLED player background", isOn: Bindable(model).oledPlayerBackground)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Uses a true black background for video information, Up Next, and comments.")
                }

                Section {
                    NavigationLink {
                        SponsorBlockSettingsScreen(model: model)
                    } label: {
                        LabeledContent("Categories and behavior") {
                            Text(model.sponsorBlockEnabled ? "On" : "Off")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("SponsorBlock")
                } footer: {
                    Text("Show or skip community-identified video segments without delaying playback.")
                }

                Section("Player controls") {
                    NavigationLink {
                        PlayerControlsSettingsScreen(model: model)
                    } label: {
                        Label("Customize controls", systemImage: "slider.horizontal.3")
                    }
                }

                Section("Data") {
                    NavigationLink {
                        ImportDataScreen()
                    } label: {
                        Label("Import Data", systemImage: "square.and.arrow.down")
                    }
                    Picker("Keep watch history", selection: Bindable(model).historyRetentionPolicy) {
                        ForEach(HistoryRetentionPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    Button(role: .destructive) {
                        showingClearHistoryConfirmation = true
                    } label: {
                        Label("Clear Watch History", systemImage: "trash")
                    }
                }

                Section {
                    Toggle("Allow cellular data", isOn: Bindable(model).allowCellularDownloads)
                    Picker("Cache limit", selection: Bindable(model).downloadCacheLimit) {
                        ForEach(DownloadCacheLimit.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    Picker("Parallel fragments", selection: Bindable(model).concurrentFragments) {
                        ForEach([1, 2, 4, 8, 16], id: \.self) { value in
                            Text(value == 1 ? "1 (sequential)" : "\(value)").tag(value)
                        }
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Currently using \(formattedCacheUsage). When the cache exceeds the limit, the oldest downloads are removed to fit.\n\nPrefetch starts a background download of the next queued video as soon as the current one plays, so tapping Next is instant. Turn off to save bandwidth.\n\nParallel fragments controls how many HLS chunks are downloaded at once — higher values are faster on good connections; values above 8 can trigger YouTube rate-limiting.")
                }

                Section {
                    LabeledContent("Version") {
                        Text(model.ytDlpVersion.isEmpty ? "Not yet loaded" : model.ytDlpVersion)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    LabeledContent("Last updated") {
                        Text(model.ytDlpLastUpdatedDisplay ?? "Never")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        model.updateYtDlpNow()
                    } label: {
                        HStack {
                            Label("Update now", systemImage: "arrow.down.circle")
                            if model.isUpdatingYtDlp {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(model.isUpdatingYtDlp)

                    if let status = model.ytDlpUpdateStatus {
                        switch status {
                        case .success(let version):
                            Label("Updated to \(version)", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                                .font(.footnote)
                        case .noChange(let version):
                            Label("Already at latest (\(version))", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        case .failure(let message):
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .font(.footnote)
                        }
                    }
                } header: {
                    Text(verbatim: "yt-dlp")
                } footer: {
                    Text("yt-dlp is the engine that resolves YouTube stream URLs. FreeTube auto-refreshes it every 7 days from the official GitHub release. Tap Update now if a video stops playing — newer versions often fix breakage caused by YouTube's API changes.")
                }

                Section {
                    Toggle("Save logs to file", isOn: Bindable(model).logToFile)
                    if model.logToFile, let url = logWriter.currentLogFileURL {
                        LabeledContent("Current log") {
                            Text(url.lastPathComponent)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Button {
                        // Prefer the active file; fall back to the latest historical one
                        // so the Share button still works right after the toggle is flipped
                        // off (writer closes the file, currentLogFileURL goes nil, but the
                        // file is still on disk and shareable).
                        shareLogURL = logWriter.currentLogFileURL ?? LogFileWriter.allLogFiles().first
                    } label: {
                        Label("Share latest log…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(LogFileWriter.allLogFiles().isEmpty)
                    if MacIntegration.isRunningOnMac {
                        Button {
                            MacIntegration.revealInFinder(LogFileWriter.logsDirectory())
                        } label: {
                            Label("Show log folder", systemImage: "folder")
                        }
                    }
                    Button(role: .destructive) {
                        showingClearLogsConfirmation = true
                    } label: {
                        Label("Clear all logs", systemImage: "trash")
                    }
                    .disabled(LogFileWriter.allLogFiles().isEmpty)
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("When enabled, every app launch creates a new log file in the app's private Application Support folder (use Share to export it). Each file starts with the app version, build, iOS version, and device model, followed by timestamped entries from FreeTube's subsystem. URLs are logged without query strings and cookie values are never written. Useful for sharing diagnostics with the developer when something breaks in TestFlight or sideload installs.")
                }

                Section {
                    Button {
                        showingResetConfirmation = true
                    } label: {
                        Label("Reset session", systemImage: "arrow.counterclockwise")
                            .foregroundStyle(.white)
                    }
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("Wipes stored cookies and the visitor token. The next playback attempt will run anonymously. Use this if playback or sign-in is stuck.")
                }

                Section {
                    Text("FreeTube is a personal/sideload-only YouTube client. It uses YouTubeKit (cookie-based, no Google API key) plus yt-dlp for downloads. YouTube can change its internal API at any time — please be patient when things break.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                } footer: {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                    Text("v\(version) (\(build)) — [freetube.io](https://freetube.io)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Settings is presented as a sheet (gear in Library / ⌘,), so it needs its own
                // way out.
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Reset session?", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
                Button("Reset", role: .destructive) {
                    Task { await SessionManager.shared.handleExpiredSession() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This signs you out and clears cached cookies.")
            }
            // System Share sheet for the log file. `ShareLink` would be cleaner, but
            // file:// URLs inside SwiftUI's `ShareLink` sometimes serialize as plain text
            // — UIActivityViewController via the existing `ActivityShareSheet` is the
            // reliable path for picking "Save to Files", AirDrop, Mail, etc.
            .sheet(isPresented: Binding(
                get: { shareLogURL != nil },
                set: { if !$0 { shareLogURL = nil } }
            )) {
                if let url = shareLogURL {
                    ActivityShareSheet(activityItems: [url])
                }
            }
            .confirmationDialog(
                "Delete all log files?",
                isPresented: $showingClearLogsConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    model.clearLogFiles()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every saved log file. If \"Save logs to file\" is on, a fresh log file will be opened for new entries.")
            }
            .confirmationDialog(
                "Clear local watch history?",
                isPresented: $showingClearHistoryConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    model.clearLocalHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes watch history stored by FreeTube on this device.")
            }
        }
    }
}
