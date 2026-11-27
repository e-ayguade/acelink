import SwiftUI

final class SyncForm: ObservableObject {
    @Published var url: String
    @Published var token: String
    @Published var copied = false

    init(sync: ChannelSync) {
        url = sync.url
        token = sync.savedToken
    }
}

/// Toolbar popover: where the channel list is downloaded from, and the access code.
struct SyncPanel: View {
    @ObservedObject var sync: ChannelSync
    @ObservedObject var store = ChannelStore.shared
    @StateObject private var form: SyncForm

    init(sync: ChannelSync) {
        self.sync = sync
        _form = StateObject(wrappedValue: SyncForm(sync: sync))
    }

    private var formChanged: Bool {
        form.url.trimmingCharacters(in: .whitespacesAndNewlines) != sync.url ||
            form.token.trimmingCharacters(in: .whitespacesAndNewlines) != sync.savedToken
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync Channels Online").font(.headline)

            Text("Download your channels from a JSON file you keep online, e.g. in a " +
                "private GitHub repository. While sync is on, add and edit channels and " +
                "links in that file. Icons stay on this Mac.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("File address").font(.caption).foregroundColor(.secondary)
                TextField("https://github.com/you/channels/blob/main/channels.json", text: $form.url)
                    .textFieldStyle(.roundedBorder)
                Text("Access code").font(.caption).foregroundColor(.secondary)
                SecureField("GitHub token (github_pat_…)", text: $form.token)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                if sync.isEnabled {
                    Button("Turn Off Sync") {
                        sync.turnOff()
                        form.url = ""
                        form.token = ""
                    }
                }
                Spacer()
                if sync.isEnabled, !formChanged {
                    Button("Sync Now", action: sync.syncNow)
                        .disabled(sync.state == .syncing)
                } else {
                    Button(sync.isEnabled ? "Save and Sync" : "Turn On Sync") {
                        sync.configure(url: form.url, token: form.token)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if sync.isEnabled { statusLine }

            Divider()

            DisclosureGroup("How to set it up on GitHub (free)") {
                Text("""
                1. Create a **private** repository on github.com and add a file \
                `channels.json` (Add file → Create new file). Use “Copy My Channels as JSON” \
                below to start from what you have.
                2. Create an access code: Settings → Developer settings → Fine-grained tokens → \
                Generate. Repository access: only that repository. Permissions: \
                Contents → Read-only.
                3. Paste the file's address and the token above.

                Edit the file on github.com (pencil icon). The app picks up changes every \
                15 minutes, when you open this window, or with Sync Now.
                """)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
            .font(.callout)

            DisclosureGroup("File format") {
                Text("""
                [
                  {
                    "name": "Sports",
                    "links": [
                      "acestream://…",
                      { "name": "HD", "url": "acestream://…" }
                    ]
                  }
                ]
                """)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .font(.callout)

            Button(form.copied ? "Copied" : "Copy My Channels as JSON") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    ChannelSync.exportJSON(store.channels), forType: .string
                )
                form.copied = true
            }
            .disabled(store.channels.isEmpty)
        }
        .padding(16)
        .frame(width: 440)
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 6) {
            switch sync.state {
            case .off:
                EmptyView()
            case .syncing:
                ProgressView().controlSize(.small)
                Text("Syncing…")
            case let .synced(date):
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Synced \(date.formatted(date: .omitted, time: .shortened)) · " +
                    "\(store.channels.count) channels")
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }
}
