import Foundation

/// The distribution channel of this build. Releases are published per channel.
public enum Channel: String, Codable, Sendable, Equatable, CaseIterable {
    case store
    case testflight
    case debug
}

/// What the app should do about its version.
public enum Update: String, Codable, Sendable, Equatable, CaseIterable {
    /// Up to date (also the answer for any unknown value).
    case none
    /// A newer version is available: show a dismissible banner.
    case available
    /// The installed version is below the minimum: block the app with an update button.
    case required

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Update(rawValue: raw) ?? .none
    }
}

/// Where an `AppStatus` comes from.
public enum Source: String, Codable, Sendable, Equatable {
    /// A fresh answer from the server (including a 304 revalidation).
    case network
    /// The last stored answer, used because the server could not be reached.
    case cache
    /// The neutral answer: no network and nothing cached.
    case `default`
}

/// A published release.
public struct Release: Codable, Sendable, Equatable {
    public var version: String
    public var build: String?
    /// Release notes in the requested locale.
    public var notes: String?
    /// Where the user updates (App Store, TestFlight, a web page).
    public var storeURL: URL?
    public var publishedAt: Date?

    public init(version: String, build: String? = nil, notes: String? = nil, storeURL: URL? = nil, publishedAt: Date? = nil) {
        self.version = version
        self.build = build
        self.notes = notes
        self.storeURL = storeURL
        self.publishedAt = publishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version, build, notes, storeURL = "storeUrl", publishedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        build = c.lenientString(.build)
        notes = c.lenientString(.notes)
        storeURL = c.lenientString(.storeURL).flatMap(URL.init(string:))
        publishedAt = c.lenientDate(.publishedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(build, forKey: .build)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(storeURL?.absoluteString, forKey: .storeURL)
        try c.encodeIfPresent(publishedAt.map(ISODate.format), forKey: .publishedAt)
    }
}

/// A maintenance window.
public struct Maintenance: Codable, Sendable, Equatable {
    public var startsAt: Date
    /// `nil`: until ended by hand.
    public var endsAt: Date?
    /// The message in the requested locale.
    public var message: String?
    /// `true`: block the UI; `false`: show a banner.
    public var blocking: Bool

    public init(startsAt: Date, endsAt: Date? = nil, message: String? = nil, blocking: Bool = true) {
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.message = message
        self.blocking = blocking
    }

    private enum CodingKeys: String, CodingKey { case startsAt, endsAt, message, blocking }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let start = c.lenientDate(.startsAt) else {
            throw DecodingError.dataCorruptedError(forKey: .startsAt, in: c, debugDescription: "Invalid startsAt")
        }
        startsAt = start
        endsAt = c.lenientDate(.endsAt)
        message = c.lenientString(.message)
        blocking = (try? c.decode(Bool.self, forKey: .blocking)) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ISODate.format(startsAt), forKey: .startsAt)
        try c.encodeIfPresent(endsAt.map(ISODate.format), forKey: .endsAt)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encode(blocking, forKey: .blocking)
    }
}

/// The answer of `GET /api/v1/public/status`, plus where it comes from.
public struct AppStatus: Codable, Sendable, Equatable {
    public var update: Update
    /// The newest release this installation may update to.
    public var latest: Release?
    /// The lowest supported version.
    public var minimum: String?
    /// The active maintenance window.
    public var maintenance: Maintenance?
    /// The next window starting within 7 days.
    public var upcomingMaintenance: Maintenance?
    /// Seconds to wait before asking again.
    public var checkAfter: Int
    public var source: Source
    /// When this answer was last confirmed by the server (or made, for the default one).
    public var fetchedAt: Date

    public init(update: Update = .none, latest: Release? = nil, minimum: String? = nil, maintenance: Maintenance? = nil,
                upcomingMaintenance: Maintenance? = nil, checkAfter: Int = 300, source: Source = .network, fetchedAt: Date = Date()) {
        self.update = update
        self.latest = latest
        self.minimum = minimum
        self.maintenance = maintenance
        self.upcomingMaintenance = upcomingMaintenance
        self.checkAfter = checkAfter
        self.source = source
        self.fetchedAt = fetchedAt
    }

    /// The neutral answer: no update, no maintenance.
    public static func neutral(fetchedAt: Date = Date()) -> AppStatus {
        AppStatus(checkAfter: AppStatus.defaultCheckAfter, source: .default, fetchedAt: fetchedAt)
    }

    static let defaultCheckAfter = 300

    /// True when both answers say the same thing (ignoring `source` and `fetchedAt`).
    public func hasSameContent(as other: AppStatus) -> Bool {
        update == other.update && latest == other.latest && minimum == other.minimum && maintenance == other.maintenance
            && upcomingMaintenance == other.upcomingMaintenance && checkAfter == other.checkAfter
    }

    private enum CodingKeys: String, CodingKey {
        case update, latest, minimum, maintenance, upcomingMaintenance, checkAfter, source, fetchedAt
    }

    private struct MinimumObject: Decodable { var version: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        update = (try? c.decode(Update.self, forKey: .update)) ?? .none
        latest = (try? c.decodeIfPresent(Release.self, forKey: .latest)) ?? nil
        // The API sends `{ "version": "…" }`; the stored form is a plain string. Accept both.
        if let object = try? c.decodeIfPresent(MinimumObject.self, forKey: .minimum) {
            minimum = object.version
        } else {
            minimum = c.lenientString(.minimum)
        }
        maintenance = (try? c.decodeIfPresent(Maintenance.self, forKey: .maintenance)) ?? nil
        upcomingMaintenance = (try? c.decodeIfPresent(Maintenance.self, forKey: .upcomingMaintenance)) ?? nil
        let seconds = (try? c.decodeIfPresent(Int.self, forKey: .checkAfter)) ?? nil
        checkAfter = seconds.map { max($0, 0) } ?? AppStatus.defaultCheckAfter
        source = ((try? c.decodeIfPresent(Source.self, forKey: .source)) ?? nil) ?? .network
        fetchedAt = c.lenientDate(.fetchedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(update, forKey: .update)
        try c.encodeIfPresent(latest, forKey: .latest)
        try c.encodeIfPresent(minimum, forKey: .minimum)
        try c.encodeIfPresent(maintenance, forKey: .maintenance)
        try c.encodeIfPresent(upcomingMaintenance, forKey: .upcomingMaintenance)
        try c.encode(checkAfter, forKey: .checkAfter)
        try c.encode(source, forKey: .source)
        try c.encode(ISODate.format(fetchedAt), forKey: .fetchedAt)
    }
}

// MARK: - Tolerant decoding helpers

enum ISODate {
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension KeyedDecodingContainer {
    /// A string, or `nil` when missing, null or of another type.
    func lenientString(_ key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    /// An ISO 8601 date (or a number of seconds since 1970), or `nil`.
    func lenientDate(_ key: Key) -> Date? {
        if let string = lenientString(key) { return ISODate.parse(string) }
        if let seconds = (try? decodeIfPresent(Double.self, forKey: key)) ?? nil { return Date(timeIntervalSince1970: seconds) }
        return nil
    }
}
