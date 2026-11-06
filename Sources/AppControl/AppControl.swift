import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// The app-control client: asks "should the user update? is there maintenance?".
///
/// It never blocks and never throws: every failure returns the last cached answer or a neutral one.
///
///     let appControl = AppControl(key: "ack_…")
///     let status = await appControl.status()
///     if status.update == .required { … }
public actor AppControl {
    public static let defaultBaseURL = URL(string: "https://app-control.srvly.it")!

    /// The request timeout, in seconds.
    static let timeout: TimeInterval = 5
    /// The shortest wait between two checks of `statusUpdates()`, in seconds.
    static let minimumInterval = 30

    private let key: String
    private let baseURL: URL
    private let version: String
    private let build: String?
    private let channelOverride: Channel?
    private var resolvedChannel: Channel?
    private let locale: String?
    private let defaults: UserDefaults
    private let session: URLSession

    /// The last answer returned, kept in memory for `checkAfter` reuse.
    private var last: (status: AppStatus, query: String)?

    /// - Parameters:
    ///   - key: the environment's public key (`ack_…`), from the app's Environments settings. Not a secret.
    ///   - baseURL: the app-control server.
    ///   - version: the installed version; defaults to `CFBundleShortVersionString`.
    ///   - build: the installed build; defaults to `CFBundleVersion`.
    ///   - channel: the distribution channel; detected once with `detectChannel()` when `nil`.
    ///   - locale: the language for notes and messages (BCP 47); defaults to the user's preferred language.
    ///   - defaults: where the installation id and the last answer are stored.
    ///   - session: the URL session (inject one with a stub protocol in tests).
    public init(key: String, baseURL: URL? = nil, version: String? = nil, build: String? = nil, channel: Channel? = nil,
                locale: String? = nil, defaults: UserDefaults? = nil, session: URLSession? = nil) {
        self.key = key
        self.baseURL = baseURL ?? Self.defaultBaseURL
        let info = Bundle.main.infoDictionary
        self.version = version ?? (info?["CFBundleShortVersionString"] as? String) ?? "0"
        self.build = build ?? (info?["CFBundleVersion"] as? String)
        self.channelOverride = channel
        self.locale = Self.sanitizedLocale(locale ?? Locale.preferredLanguages.first ?? Locale.current.identifier)
        self.defaults = defaults ?? .standard
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.timeout
            configuration.timeoutIntervalForResource = Self.timeout
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: Public API

    /// The current status. Reuses the last answer while younger than its `checkAfter`, unless `force` is true.
    /// Never throws: offline it returns the cached answer (`source: .cache`) or a neutral one (`source: .default`).
    public func status(force: Bool = false) async -> AppStatus {
        applyAcceptances(await fetchStatus(force: force))
    }

    /// The status as the server (or the cache) says it, before local acceptances are applied.
    private func fetchStatus(force: Bool) async -> AppStatus {
        let items = await queryItems()
        let fingerprint = Self.fingerprint(items)
        let now = Date()

        if !force, let reusable = reusableAnswer(for: fingerprint, now: now) {
            return reusable
        }

        // Acceptances queued while offline go first, so this answer already reflects them.
        await flushAcceptances()
        let requestStart = Date()
        let cached = readCache()
        do {
            var request = URLRequest(url: try statusURL(items), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

            switch http.statusCode {
            case 304:
                guard let cached else { throw URLError(.badServerResponse) }
                var status = try Self.decode(cached.body)
                status.source = .network
                status.fetchedAt = now
                writeCache(CacheEntry(etag: http.value(forHTTPHeaderField: "ETag") ?? cached.etag, body: cached.body, fetchedAt: now, query: fingerprint))
                forgetConfirmedAcceptances(before: requestStart)
                return remember(status, fingerprint)
            case 200:
                var status = try Self.decode(data)
                status.source = .network
                status.fetchedAt = now
                writeCache(CacheEntry(etag: http.value(forHTTPHeaderField: "ETag"), body: data, fetchedAt: now, query: fingerprint))
                forgetConfirmedAcceptances(before: requestStart)
                return remember(status, fingerprint)
            default:
                throw URLError(.badServerResponse)
            }
        } catch {
            if let cached, var status = try? Self.decode(cached.body) {
                status.source = .cache
                status.fetchedAt = cached.fetchedAt
                return status
            }
            return AppStatus.neutral(fetchedAt: now)
        }
    }

    /// Yields the status at once, then checks again every `checkAfter` seconds (at least 30)
    /// and yields only when the answer changes. Stops when the consuming task is cancelled.
    ///
    /// Consume it only while the app is in the foreground, for example in SwiftUI:
    ///
    ///     .task(id: scenePhase) {
    ///         guard scenePhase == .active else { return }
    ///         for await status in appControl.statusUpdates() { self.status = status }
    ///     }
    ///
    /// The `.appControlGate(_:)` modifier does this for you.
    public nonisolated func statusUpdates() -> AsyncStream<AppStatus> {
        AsyncStream { continuation in
            let id = UUID()
            let previous = LockedValue<AppStatus?>(nil)
            // Yields only when the content changes; also called after `accept(_:)`.
            let emit: @Sendable (AppStatus) -> Void = { status in
                let changed = previous.update { last -> Bool in
                    defer { last = status }
                    return last.map { !$0.hasSameContent(as: status) } ?? true
                }
                if changed { continuation.yield(status) }
            }
            let task = Task { [self] in
                await self.addWatcher(id, emit)
                while !Task.isCancelled {
                    let status = await self.status()
                    if Task.isCancelled { break }
                    emit(status)
                    let seconds = max(status.checkAfter, Self.minimumInterval)
                    try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                }
                await self.removeWatcher(id)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.removeWatcher(id) }
            }
        }
    }

    /// Records that the user accepted `document`. Never throws.
    ///
    /// It posts to `/api/v1/public/legal/acceptances` with the installation id, platform, locale and app
    /// version. On failure the acceptance is kept on the device and sent again before the next `status()`
    /// that asks the server. Either way, from now on `status()` and `statusUpdates()` mark the document
    /// `needsAcceptance = false`, so the app doesn't ask again.
    public func accept(_ document: LegalDocument) async {
        var state = readLegalState()
        let entry = Acceptance(kind: document.kind, version: document.version, locale: locale,
                               appVersion: Self.isValidVersion(version) ? version : nil, at: Date())
        state.pending.removeAll { $0.kind == entry.kind && $0.version == entry.version }
        state.pending.append(entry)
        writeLegalState(state)
        notifyWatchers()
        await flushAcceptances()
    }

    /// The acceptances not delivered to the server yet.
    public func pendingAcceptanceCount() -> Int { readLegalState().pending.count }

    /// A random id made once and stored on this device. It is never linked to the user or the device:
    /// it only places this installation in a rollout bucket.
    public func installationId() -> String {
        let storageKey = "appcontrol.installation"
        if let existing = defaults.string(forKey: storageKey), Self.isValidInstallation(existing) { return existing }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: storageKey)
        return id
    }

    /// The distribution channel of this build:
    /// 1. compiled with `DEBUG` → `debug`;
    /// 2. an App Store receipt named `sandboxReceipt` → `testflight` (any other receipt → `store`);
    /// 3. without a receipt, StoreKit 2 `AppTransaction` (`.sandbox` → testflight, `.xcode` → debug);
    /// 4. else `store`.
    public static func detectChannel() async -> Channel {
        #if DEBUG
        return .debug
        #else
        // `appStoreReceiptURL` is deprecated since iOS 18 but still works and is immediate.
        if let url = Bundle.main.appStoreReceiptURL, FileManager.default.fileExists(atPath: url.path) {
            return url.lastPathComponent == "sandboxReceipt" ? .testflight : .store
        }
        #if canImport(StoreKit)
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, visionOS 1.0, *) {
            if case .verified(let transaction)? = try? await AppTransaction.shared {
                switch transaction.environment {
                case .sandbox: return .testflight
                case .xcode: return .debug
                default: return .store
                }
            }
        }
        #endif
        return .store
        #endif
    }

    // MARK: Request

    /// The platform this SDK is compiled for, as the API names it.
    static var platform: String {
        #if os(visionOS)
        return "visionos"
        #elseif os(iOS)
        return "ios"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #else
        return "macos"
        #endif
    }

    /// The system version, major.minor.
    static var osVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion)"
    }

    func queryItems() async -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "platform", value: Self.platform),
            URLQueryItem(name: "version", value: version),
        ]
        if let build, !build.isEmpty { items.append(URLQueryItem(name: "build", value: String(build.prefix(32)))) }
        items.append(URLQueryItem(name: "channel", value: await channel().rawValue))
        if let locale { items.append(URLQueryItem(name: "locale", value: locale)) }
        items.append(URLQueryItem(name: "installation", value: installationId()))
        items.append(URLQueryItem(name: "os", value: Self.osVersion))
        return items
    }

    private func channel() async -> Channel {
        if let channelOverride { return channelOverride }
        if let resolvedChannel { return resolvedChannel }
        let detected = await Self.detectChannel()
        resolvedChannel = detected
        return detected
    }

    private func statusURL(_ items: [URLQueryItem]) throws -> URL {
        let url = baseURL.appendingPathComponent("api/v1/public/status")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        components.queryItems = items
        // `+` is legal in a query but servers may read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let result = components.url else { throw URLError(.badURL) }
        return result
    }

    static func decode(_ data: Data) throws -> AppStatus {
        try JSONDecoder().decode(AppStatus.self, from: data)
    }

    /// The query identifies the answer: a new version or locale must not reuse an old answer.
    private static func fingerprint(_ items: [URLQueryItem]) -> String {
        items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
    }

    /// A BCP 47 tag the API accepts (`it-IT`), or `nil`.
    static func sanitizedLocale(_ raw: String) -> String? {
        let base = raw.split(separator: "@").first.map(String.init) ?? raw
        let tag = base.replacingOccurrences(of: "_", with: "-")
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first, (2...3).contains(language.count), language.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        var accepted = [String(language)]
        for part in parts.dropFirst() {
            guard (1...8).contains(part.count), part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { break }
            accepted.append(String(part))
        }
        let result = accepted.joined(separator: "-")
        return result.count <= 35 ? result : String(language)
    }

    private static func isValidInstallation(_ id: String) -> Bool {
        (8...128).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // MARK: Cache

    private struct CacheEntry: Codable {
        var etag: String?
        var body: Data
        var fetchedAt: Date
        var query: String
    }

    private var cacheKey: String { "appcontrol.status.\(key)" }

    private func readCache() -> CacheEntry? {
        guard let data = defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(CacheEntry.self, from: data)
    }

    private func writeCache(_ entry: CacheEntry) {
        if let data = try? JSONEncoder().encode(entry) { defaults.set(data, forKey: cacheKey) }
    }

    private func remember(_ status: AppStatus, _ fingerprint: String) -> AppStatus {
        last = (status, fingerprint)
        return status
    }

    /// The answer to reuse without asking the server: younger than its `checkAfter` and for the same query.
    private func reusableAnswer(for fingerprint: String, now: Date) -> AppStatus? {
        if let last, last.query == fingerprint, now.timeIntervalSince(last.status.fetchedAt) < TimeInterval(last.status.checkAfter) {
            return last.status
        }
        // After a relaunch: the stored answer, marked as cache.
        if let cached = readCache(), cached.query == fingerprint, var status = try? Self.decode(cached.body),
           now.timeIntervalSince(cached.fetchedAt) < TimeInterval(status.checkAfter) {
            status.source = .cache
            status.fetchedAt = cached.fetchedAt
            last = (status, fingerprint)
            return status
        }
        return nil
    }

    // MARK: Legal acceptances

    struct Acceptance: Codable, Equatable {
        var kind: String
        var version: Int
        var locale: String?
        var appVersion: String?
        /// When accepted (pending) or when delivered (sent).
        var at: Date
    }

    /// `pending`: not delivered yet. `sent`: delivered, kept until an answer from the server reflects them.
    struct LegalState: Codable, Equatable {
        var pending: [Acceptance] = []
        var sent: [Acceptance] = []
    }

    struct AcceptanceBody: Codable, Equatable {
        var key: String
        var installation: String
        var kind: String
        var version: Int
        var platform: String
        var locale: String?
        var appVersion: String?
    }

    private enum Delivery { case delivered, rejected, failed }

    private var legalKey: String { "appcontrol.legal.\(key)" }
    private var flushing = false
    private var watchers: [UUID: @Sendable (AppStatus) -> Void] = [:]

    func readLegalState() -> LegalState {
        guard let data = defaults.data(forKey: legalKey) else { return LegalState() }
        return (try? JSONDecoder().decode(LegalState.self, from: data)) ?? LegalState()
    }

    private func writeLegalState(_ state: LegalState) {
        if state.pending.isEmpty && state.sent.isEmpty {
            defaults.removeObject(forKey: legalKey)
        } else if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: legalKey)
        }
    }

    /// Marks the documents accepted on this device (delivered or not) as not needing acceptance.
    private func applyAcceptances(_ status: AppStatus) -> AppStatus {
        guard status.legal.contains(where: { $0.needsAcceptance == true }) else { return status }
        let state = readLegalState()
        let local = state.pending + state.sent
        guard !local.isEmpty else { return status }
        var result = status
        for index in result.legal.indices where result.legal[index].needsAcceptance == true {
            let document = result.legal[index]
            if local.contains(where: { $0.kind == document.kind && $0.version >= document.version }) {
                result.legal[index].needsAcceptance = false
            }
        }
        return result
    }

    /// Sends the pending acceptances, oldest first. Delivered ones move to `sent`; the ones the server
    /// refuses for good (unknown key, version not in force) are dropped; the others stay queued.
    private func flushAcceptances() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        var attempted: [Acceptance] = []
        while let next = readLegalState().pending.first(where: { !attempted.contains($0) }) {
            attempted.append(next)
            let outcome = await deliver(next)
            if outcome == .failed { continue }
            var state = readLegalState()
            state.pending.removeAll { $0 == next }
            if outcome == .delivered {
                var sent = next
                sent.at = Date()
                state.sent.removeAll { $0.kind == sent.kind && $0.version == sent.version }
                state.sent.append(sent)
            }
            writeLegalState(state)
        }
    }

    private func deliver(_ acceptance: Acceptance) async -> Delivery {
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/public/legal/acceptances"),
                                     cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(acceptanceBody(acceptance))
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 200..<300: return .delivered
            case 408, 429: return .failed
            case 400..<500: return .rejected
            default: return .failed
            }
        } catch {
            return .failed
        }
    }

    func acceptanceBody(_ acceptance: Acceptance) -> AcceptanceBody {
        AcceptanceBody(key: key, installation: installationId(), kind: acceptance.kind, version: acceptance.version,
                       platform: Self.platform, locale: acceptance.locale, appVersion: acceptance.appVersion)
    }

    /// A network answer whose request started after an acceptance was delivered already reflects it.
    private func forgetConfirmedAcceptances(before date: Date) {
        var state = readLegalState()
        let count = state.sent.count
        state.sent.removeAll { $0.at <= date }
        if state.sent.count != count { writeLegalState(state) }
    }

    private func addWatcher(_ id: UUID, _ watcher: @escaping @Sendable (AppStatus) -> Void) { watchers[id] = watcher }
    private func removeWatcher(_ id: UUID) { watchers[id] = nil }

    /// Gives the `statusUpdates()` streams the last answer with the local acceptances applied.
    private func notifyWatchers() {
        guard !watchers.isEmpty else { return }
        let base: AppStatus
        if let last {
            base = last.status
        } else if let cached = readCache(), var status = try? Self.decode(cached.body) {
            status.source = .cache
            status.fetchedAt = cached.fetchedAt
            base = status
        } else {
            return
        }
        let status = applyAcceptances(base)
        for watcher in watchers.values { watcher(status) }
    }

    /// The versions the API takes as `appVersion`: `1`, `2.3`, `v2.3.1`, `1.2.3.4`.
    static func isValidVersion(_ value: String) -> Bool {
        value.range(of: #"^[vV]?\d{1,9}(\.\d{1,9}){0,3}$"#, options: .regularExpression) != nil
    }
}

/// A value behind a lock, shared between a stream and its producers.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
