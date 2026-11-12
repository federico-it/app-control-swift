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
    /// This SDK's version, sent as `sdk=swift/<sdkVersion>`.
    public static let sdkVersion = "0.4.0"

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
    /// Where the installation label is kept, readable without `await`.
    private let labelStore: LabelStore

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
        self.labelStore = LabelStore(defaults: self.defaults, key: "appcontrol.installationLabel.\(key)")
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
        let items = await queryItems()
        let fingerprint = Self.fingerprint(items)
        let now = Date()

        if !force, let reusable = reusableAnswer(for: fingerprint, now: now) {
            return reusable
        }

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
                storeInstallationLabel(from: cached.body)
                return remember(status, fingerprint)
            case 200:
                var status = try Self.decode(data)
                status.source = .network
                status.fetchedAt = now
                writeCache(CacheEntry(etag: http.value(forHTTPHeaderField: "ETag"), body: data, fetchedAt: now, query: fingerprint))
                storeInstallationLabel(from: data)
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

    /// Asks the server at once (never reusing an earlier answer, so each launch and each return to the
    /// foreground sees the latest status), then checks again every `checkAfter` seconds (at least 30)
    /// and yields only when the answer changes. Offline, the first value is the cached answer.
    /// Stops when the consuming task is cancelled.
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
            let task = Task { [self] in
                var previous: AppStatus?
                var first = true
                while !Task.isCancelled {
                    // The first check skips the reuse window: the app was just opened or brought back.
                    let status = await self.status(force: first)
                    first = false
                    if Task.isCancelled { break }
                    // Yields only when the content changes.
                    if previous.map({ !$0.hasSameContent(as: status) }) ?? true { continuation.yield(status) }
                    previous = status
                    let seconds = max(status.checkAfter, Self.minimumInterval)
                    try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The short label of this installation, e.g. `a1b2c3d4` (8 hex characters), or `nil` before the
    /// first answer from the server.
    ///
    /// It is the same label the app's Stats → Recent installations shows: reveal it ("ID a1b2c3d4")
    /// after 5 taps on the version row in Settings, so the developer can find this device.
    /// It is stored on the device and updated from each answer of the server, so reading it never
    /// waits for the network and works offline; it's `nonisolated`, so no `await` is needed:
    ///
    ///     Text("ID \(appControl.installationLabel ?? "–")")
    public nonisolated var installationLabel: String? { labelStore.value }

    /// A random id made once and stored on this device. It is never linked to the user or the device:
    /// it places this installation in a rollout bucket and, hashed per app, counts it in the stats.
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

    /// The hardware model identifier (`iPhone16,1`, `Mac14,2`), computed once; `nil` when unknown.
    /// Only the model is sent: no name, serial number or other device data.
    static let deviceModel: String? = {
        let raw = rawDeviceModel().trimmingCharacters(in: .whitespacesAndNewlines)
        let model = String(raw.prefix(64))
        return model.isEmpty ? nil : model
    }()

    private static func rawDeviceModel() -> String {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !model.isEmpty {
            return model
        }
        #endif
        #if os(macOS) || targetEnvironment(macCatalyst)
        return sysctlString("hw.model") ?? machine()
        #else
        // An iPad app on a Mac with Apple silicon reports an iPad model in `machine`; `hw.model` is the Mac.
        if ProcessInfo.processInfo.isiOSAppOnMac, let model = sysctlString("hw.model") {
            return model
        }
        return machine()
        #endif
    }

    /// `utsname.machine`: the hardware identifier on a device (`iPhone16,1`).
    private static func machine() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "" }
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        return value.isEmpty ? nil : value
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
        if let model = Self.deviceModel { items.append(URLQueryItem(name: "model", value: model)) }
        items.append(URLQueryItem(name: "sdk", value: "swift/\(Self.sdkVersion)"))
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

    // MARK: Installation label

    private struct LabelBody: Decodable { var installation: String? }

    /// Keeps the `installation` label of a server answer. A missing or malformed one leaves the stored label.
    private func storeInstallationLabel(from body: Data) {
        guard let label = (try? JSONDecoder().decode(LabelBody.self, from: body))?.installation,
              Self.isValidLabel(label) else { return }
        labelStore.value = label
    }

    static func isValidLabel(_ label: String) -> Bool {
        (1...64).contains(label.count) && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// The stored installation label. `UserDefaults` is thread-safe, so reading it outside the actor is fine.
final class LabelStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    var value: String? {
        get { defaults.string(forKey: key) }
        set { if defaults.string(forKey: key) != newValue { defaults.set(newValue, forKey: key) } }
    }
}

