import Foundation
import os

/// One channel in the online JSON file:
/// `{"name": "Sports", "links": ["acestream://…", {"name": "HD", "url": "acestream://…"}]}`
struct RemoteChannel: Decodable, Equatable {
    var name: String
    var links: [RemoteLink]

    private enum CodingKeys: String, CodingKey { case name, links }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        links = try container.decodeIfPresent([RemoteLink].self, forKey: .links) ?? []
    }
}

/// A link is either a plain string or an object with a `url` and an optional `name`.
struct RemoteLink: Decodable, Equatable {
    var name: String?
    var url: String

    private enum CodingKeys: String, CodingKey { case name, url }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            url = value
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }
}

/// Downloads the channel list from a URL the user owns (e.g. a JSON file in a private
/// GitHub repo) with an access token, and replaces the local channels with it.
/// While sync is on, the online file is the source of truth: channels and links are
/// edited there, and only icons (and link order after an availability check) stay local.
final class ChannelSync: ObservableObject {
    static let shared = ChannelSync()

    enum State: Equatable {
        case off
        case syncing
        case synced(Date)
        case failed(String)
    }

    @Published private(set) var state: State = .off
    @Published private(set) var url: String = ""

    var isEnabled: Bool { !url.isEmpty }

    /// How often to check for changes while the app runs.
    static let interval: TimeInterval = 15 * 60

    private var token: String = ""
    private var timer: Timer?
    private var task: URLSessionDataTask?

    private static var settingsURL: URL {
        ChannelStore.baseDir.appendingPathComponent("sync.json")
    }

    private struct Settings: Codable {
        var url: String
        var token: String
    }

    init() {
        if let data = try? Data(contentsOf: Self.settingsURL),
           let settings = try? JSONDecoder().decode(Settings.self, from: data) {
            url = settings.url
            token = settings.token
        }
    }

    /// The saved access code, for showing it (masked) in the settings form.
    var savedToken: String { token }

    // MARK: - Settings

    /// Saves the address and access code and syncs right away.
    func configure(url newURL: String, token newToken: String) {
        url = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        saveSettings()
        start()
    }

    /// Turns sync off. The channels downloaded so far are kept and become editable again.
    func turnOff() {
        task?.cancel()
        timer?.invalidate()
        timer = nil
        url = ""
        token = ""
        try? FileManager.default.removeItem(at: Self.settingsURL)
        state = .off
    }

    /// Syncs now and then every `interval`. Does nothing when sync is off.
    func start() {
        timer?.invalidate()
        guard isEnabled else { return }
        syncNow()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.syncNow()
        }
    }

    private func saveSettings() {
        do {
            try FileManager.default.createDirectory(
                at: ChannelStore.baseDir, withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Settings(url: url, token: token))
            try data.write(to: Self.settingsURL, options: .atomic)
            // Only this user can read the access code.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: Self.settingsURL.path
            )
        } catch {
            os_log("Cannot save sync settings: %{public}@", error.localizedDescription)
        }
    }

    // MARK: - Download

    func syncNow() {
        guard isEnabled else { return }
        guard let request = Self.request(url: url, token: token) else {
            state = .failed("That address is not a valid URL.")
            return
        }
        task?.cancel()
        state = .syncing
        os_log("Syncing channels from %{public}@", request.url?.host ?? "?")

        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result = Self.parse(data: data, response: response, error: error)
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case let .success(remote):
                    self.apply(remote)
                    self.state = .synced(Date())
                case let .failure(message):
                    if message == nil { return } // Cancelled by a newer sync.
                    self.state = .failed(message ?? "")
                }
            }
        }
        task?.resume()
    }

    private enum Outcome {
        case success([RemoteChannel])
        /// nil = cancelled.
        case failure(String?)
    }

    private struct Wrapped: Decodable {
        var channels: [RemoteChannel]
    }

    private static func parse(data: Data?, response: URLResponse?, error: Error?) -> Outcome {
        if let error = error as? URLError, error.code == .cancelled { return .failure(nil) }
        if let error = error { return .failure("Cannot connect: \(error.localizedDescription)") }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200 ..< 300: break
        case 401: return .failure("Wrong access code (401).")
        case 403: return .failure("The access code can't read this file, or it expired (403).")
        case 404: return .failure("File not found (404). Check the address and that the " +
                "access code can read this repository.")
        default: return .failure("The server answered \(code).")
        }
        guard let data = data else { return .failure("The server sent nothing.") }
        let decoder = JSONDecoder()
        do {
            if let wrapped = try? decoder.decode(Wrapped.self, from: data) {
                return .success(wrapped.channels)
            }
            return .success(try decoder.decode([RemoteChannel].self, from: data))
        } catch {
            return .failure("The file is not valid channel JSON: \(describe(error))")
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case let .dataCorrupted(context):
            return context.underlyingError?.localizedDescription ?? context.debugDescription
        case let .keyNotFound(key, context):
            return "missing \"\(key.stringValue)\" at \(path(context))"
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            return "\(context.debugDescription) at \(path(context))"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let parts = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }
        return parts.isEmpty ? "the top level" : parts.joined()
    }

    /// Builds the request. github.com and raw.githubusercontent.com file addresses are
    /// turned into GitHub API requests, which work for private repositories with a token.
    static func request(url string: String, token: String) -> URLRequest? {
        guard var url = URL(string: string), let host = url.host, url.scheme?.hasPrefix("http") == true
        else { return nil }

        var github = host == "api.github.com"
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "github.com", parts.count >= 5, parts[2] == "blob" || parts[2] == "raw" {
            // github.com/{owner}/{repo}/blob/{branch}/{path…}
            url = githubAPI(owner: parts[0], repo: parts[1], ref: parts[3], path: parts[4...]) ?? url
            github = true
        } else if host == "raw.githubusercontent.com", parts.count >= 4 {
            // raw.githubusercontent.com/{owner}/{repo}/{branch}/{path…}
            url = githubAPI(owner: parts[0], repo: parts[1], ref: parts[2], path: parts[3...]) ?? url
            github = true
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(github ? "application/vnd.github.raw+json" : "application/json",
                         forHTTPHeaderField: "Accept")
        if github { request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version") }
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private static func githubAPI(owner: String, repo: String, ref: String,
                                  path: ArraySlice<String>) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repo)/contents/" + path.joined(separator: "/")
        components.queryItems = [URLQueryItem(name: "ref", value: ref)]
        return components.url
    }

    // MARK: - Merge

    private func apply(_ remote: [RemoteChannel]) {
        let store = ChannelStore.shared
        let merged = Self.merge(remote: remote, into: store.channels)
        if merged != store.channels {
            store.channels = merged
        }
    }

    /// Builds the channel list from the online file, reusing local channels (matched by
    /// name) and links (matched by URL) so icons and availability results survive a sync.
    static func merge(remote: [RemoteChannel], into local: [Channel]) -> [Channel] {
        var unusedChannels = local
        return remote.map { remoteChannel in
            let name = remoteChannel.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var channel: Channel
            if let index = unusedChannels.firstIndex(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                channel = unusedChannels.remove(at: index)
            } else {
                channel = Channel(name: name)
            }
            channel.name = name

            var unusedLinks = channel.links
            let links: [StreamLink] = remoteChannel.links.enumerated().map { offset, remoteLink in
                let url = remoteLink.url.trimmingCharacters(in: .whitespacesAndNewlines)
                let remoteName = remoteLink.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                var link: StreamLink
                if let index = unusedLinks.firstIndex(where: { $0.url == url }) {
                    link = unusedLinks.remove(at: index)
                } else {
                    link = StreamLink(name: "", url: url)
                }
                if let remoteName = remoteName, !remoteName.isEmpty {
                    link.name = remoteName
                } else if link.name.isEmpty {
                    link.name = "Link \(offset + 1)"
                }
                return link
            }

            // Same links as before: keep the local order (e.g. after Check Availability
            // sorted working links to the top). Otherwise use the file's order.
            let oldIDs = channel.links.map(\.id)
            if unusedLinks.isEmpty, Set(links.map(\.id)) == Set(oldIDs), links.count == oldIDs.count {
                channel.links = links.sorted {
                    (oldIDs.firstIndex(of: $0.id) ?? 0) < (oldIDs.firstIndex(of: $1.id) ?? 0)
                }
            } else {
                channel.links = links
            }
            return channel
        }
    }

    // MARK: - Export

    /// The current channels in the file format, to paste into the online file the first time.
    static func exportJSON(_ channels: [Channel]) -> String {
        let list: [[String: Any]] = channels.map { channel in
            [
                "name": channel.name,
                "links": channel.links.map { ["name": $0.name, "url": $0.url] }
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: list, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
