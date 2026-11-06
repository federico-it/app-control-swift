import XCTest
@testable import AppControl

/// Answers every request of the test session with the current handler, and records the requests.
final class StubProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: Handler?
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var handler: Handler? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    static var requests: [URLRequest] { lock.withLock { _requests } }

    static func reset() {
        lock.withLock {
            _handler = nil
            _requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._requests.append(request) }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        do {
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class AppControlTests: XCTestCase {
    static let key = "ack_" + String(repeating: "a1", count: 32)

    static let body = """
    {
      "update": "available",
      "latest": { "version": "2.4.0", "build": "312", "notes": "Faster sync", "storeUrl": "https://apps.apple.com/app/id1", "publishedAt": "2026-10-01T09:00:00.000Z" },
      "minimum": { "version": "2.2.0" },
      "maintenance": null,
      "upcomingMaintenance": { "startsAt": "2026-11-10T22:00:00Z", "endsAt": null, "message": "Database upgrade", "blocking": true },
      "legal": [],
      "checkAfter": 300
    }
    """

    var defaults: UserDefaults!
    var suiteName: String!
    var session: URLSession!

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        suiteName = "appcontrol.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        StubProtocol.reset()
        super.tearDown()
    }

    func makeClient(channel: Channel? = .testflight, locale: String? = "it-IT") -> AppControl {
        AppControl(key: Self.key, baseURL: URL(string: "https://example.test/base")!, version: "2.3.1", build: "300",
                   channel: channel, locale: locale, defaults: UserDefaults(suiteName: suiteName), session: session)
    }

    static func ok(_ body: String = body, etag: String? = "W/\"abc\"") -> StubProtocol.Handler {
        { _ in (200, etag.map { ["ETag": $0] } ?? [:], Data(body.utf8)) }
    }

    func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Query

    func testQueryBuilding() async throws {
        StubProtocol.handler = Self.ok()
        let client = makeClient()
        _ = await client.status()

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/base/api/v1/public/status")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
        let q = query(request)
        XCTAssertEqual(q["key"], Self.key)
        XCTAssertEqual(q["platform"], "macos")
        XCTAssertEqual(q["version"], "2.3.1")
        XCTAssertEqual(q["build"], "300")
        XCTAssertEqual(q["channel"], "testflight")
        XCTAssertEqual(q["locale"], "it-IT")
        XCTAssertNotNil(q["os"]?.range(of: #"^\d+\.\d+$"#, options: .regularExpression))
        let installation = await client.installationId()
        XCTAssertEqual(q["installation"], installation)
        XCTAssertNotNil(installation.range(of: "^[A-Za-z0-9_-]{8,128}$", options: .regularExpression))
    }

    func testInstallationIdIsStableAndStored() async {
        let first = await makeClient().installationId()
        let second = await makeClient().installationId()
        XCTAssertEqual(first, second)
        XCTAssertEqual(defaults.string(forKey: "appcontrol.installation"), first)
    }

    func testDefaultChannelIsDetected() async throws {
        StubProtocol.handler = Self.ok()
        _ = await makeClient(channel: nil).status()
        let q = query(try XCTUnwrap(StubProtocol.requests.first))
        // Tests build with DEBUG.
        XCTAssertEqual(q["channel"], "debug")
    }

    func testLocaleSanitizing() {
        XCTAssertEqual(AppControl.sanitizedLocale("it_IT"), "it-IT")
        XCTAssertEqual(AppControl.sanitizedLocale("en_US@rg=itzzzz"), "en-US")
        XCTAssertEqual(AppControl.sanitizedLocale("zh-Hant-TW"), "zh-Hant-TW")
        XCTAssertNil(AppControl.sanitizedLocale(""))
        XCTAssertNil(AppControl.sanitizedLocale("1x"))
    }

    // MARK: Decoding

    func testDecoding() async throws {
        StubProtocol.handler = Self.ok()
        let status = await makeClient().status()

        XCTAssertEqual(status.source, .network)
        XCTAssertEqual(status.update, .available)
        XCTAssertEqual(status.latest?.version, "2.4.0")
        XCTAssertEqual(status.latest?.build, "312")
        XCTAssertEqual(status.latest?.notes, "Faster sync")
        XCTAssertEqual(status.latest?.storeURL, URL(string: "https://apps.apple.com/app/id1"))
        XCTAssertEqual(status.latest?.publishedAt, ISODate.parse("2026-10-01T09:00:00Z"))
        XCTAssertEqual(status.minimum, "2.2.0")
        XCTAssertNil(status.maintenance)
        XCTAssertEqual(status.upcomingMaintenance?.message, "Database upgrade")
        XCTAssertEqual(status.upcomingMaintenance?.blocking, true)
        XCTAssertNil(status.upcomingMaintenance?.endsAt)
        XCTAssertEqual(status.checkAfter, 300)
    }

    func testTolerantDecoding() throws {
        let json = """
        {
          "update": "something-new",
          "latest": { "version": "3.0", "build": 12, "storeUrl": null, "extra": true },
          "minimum": null,
          "maintenance": { "startsAt": "not a date", "blocking": true },
          "upcomingMaintenance": { "startsAt": "2026-11-10T22:00:00Z", "message": null, "blocking": false },
          "newField": { "nested": [1, 2, 3] }
        }
        """
        let status = try AppControl.decode(Data(json.utf8))
        XCTAssertEqual(status.update, .none)
        XCTAssertEqual(status.latest?.version, "3.0")
        XCTAssertNil(status.latest?.build)
        XCTAssertNil(status.latest?.storeURL)
        XCTAssertNil(status.minimum)
        XCTAssertNil(status.maintenance)
        XCTAssertEqual(status.upcomingMaintenance?.blocking, false)
        XCTAssertEqual(status.checkAfter, 300)
    }

    func testStatusRoundTripsThroughCodable() throws {
        StubProtocol.handler = nil
        let original = try AppControl.decode(Data(Self.body.utf8))
        let copy = try JSONDecoder().decode(AppStatus.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(copy.minimum, "2.2.0")
        XCTAssertTrue(copy.hasSameContent(as: original))
    }

    // MARK: Cache, 304, offline

    func testETagRevalidationReturnsCachedBodyAsNetwork() async throws {
        StubProtocol.handler = Self.ok()
        let client = makeClient()
        let first = await client.status()

        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "W/\"abc\"")
            return (304, ["ETag": "W/\"abc\""], Data())
        }
        let second = await client.status(force: true)
        XCTAssertEqual(StubProtocol.requests.count, 2)
        XCTAssertEqual(second.source, .network)
        XCTAssertTrue(second.hasSameContent(as: first))
        XCTAssertGreaterThanOrEqual(second.fetchedAt, first.fetchedAt)
    }

    func testCacheSurvivesANewClient() async throws {
        StubProtocol.handler = Self.ok()
        _ = await makeClient().status()

        StubProtocol.handler = { _ in (304, [:], Data()) }
        let status = await makeClient().status(force: true)
        XCTAssertEqual(StubProtocol.requests.last?.value(forHTTPHeaderField: "If-None-Match"), "W/\"abc\"")
        XCTAssertEqual(status.update, .available)
        XCTAssertEqual(status.source, .network)
    }

    func testOfflineFallsBackToCache() async {
        StubProtocol.handler = Self.ok()
        let client = makeClient()
        let first = await client.status()

        StubProtocol.handler = nil // not connected
        let offline = await client.status(force: true)
        XCTAssertEqual(offline.source, .cache)
        XCTAssertEqual(offline.fetchedAt, first.fetchedAt)
        XCTAssertTrue(offline.hasSameContent(as: first))
    }

    func testServerErrorFallsBackToCache() async {
        StubProtocol.handler = Self.ok()
        let client = makeClient()
        _ = await client.status()

        StubProtocol.handler = { _ in (500, [:], Data("{}".utf8)) }
        let status = await client.status(force: true)
        XCTAssertEqual(status.source, .cache)
        XCTAssertEqual(status.update, .available)
    }

    func testNeutralDefaultWithoutNetworkOrCache() async {
        StubProtocol.handler = nil
        let status = await makeClient().status()
        XCTAssertEqual(status.source, .default)
        XCTAssertEqual(status.update, .none)
        XCTAssertNil(status.latest)
        XCTAssertNil(status.minimum)
        XCTAssertNil(status.maintenance)
        XCTAssertNil(status.upcomingMaintenance)
    }

    func testInvalidBodyFallsBackToDefault() async {
        StubProtocol.handler = { _ in (200, [:], Data("not json".utf8)) }
        let status = await makeClient().status()
        XCTAssertEqual(status.source, .default)
    }

    func testUnknownKeyFallsBackToDefault() async {
        StubProtocol.handler = { _ in (404, [:], Data(#"{"statusCode":404,"code":"not_found","message":"Unknown key"}"#.utf8)) }
        let status = await makeClient().status()
        XCTAssertEqual(status.source, .default)
        XCTAssertEqual(status.update, .none)
    }

    // MARK: checkAfter

    func testCheckAfterReusesTheAnswer() async {
        StubProtocol.handler = Self.ok()
        let client = makeClient()
        let first = await client.status()
        let second = await client.status()
        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(second, first)

        _ = await client.status(force: true)
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testCheckAfterReuseAfterRelaunchIsMarkedCache() async {
        StubProtocol.handler = Self.ok()
        _ = await makeClient().status()
        let reused = await makeClient().status()
        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(reused.source, .cache)
        XCTAssertEqual(reused.update, .available)
    }

    func testExpiredCheckAfterAsksAgain() async {
        StubProtocol.handler = Self.ok(Self.body.replacingOccurrences(of: "\"checkAfter\": 300", with: "\"checkAfter\": 0"))
        let client = makeClient()
        _ = await client.status()
        _ = await client.status()
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testADifferentQueryDoesNotReuse() async {
        StubProtocol.handler = Self.ok()
        _ = await makeClient(locale: "it-IT").status()
        _ = await makeClient(locale: "en").status()
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    // MARK: statusUpdates

    func testStatusUpdatesYieldsAtOnce() async {
        StubProtocol.handler = Self.ok()
        let client = makeClient()
        var iterator = client.statusUpdates().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.update, .available)
    }

    // MARK: Legal

    static let legalBody = body.replacingOccurrences(of: "\"legal\": []", with: """
    "legal": [
      { "kind": "privacy", "version": 3, "title": "Privacy policy", "url": "https://example.test/legal/app/privacy/it",
        "updatedAt": "2026-11-01T09:00:00.000Z", "requiresAcceptance": true, "needsAcceptance": true },
      { "kind": "terms", "version": 1, "title": "Terms", "url": "https://example.test/legal/app/terms/it",
        "updatedAt": "2026-10-01T09:00:00.000Z", "requiresAcceptance": false, "needsAcceptance": false }
    ]
    """)

    static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static func isAcceptance(_ request: URLRequest) -> Bool {
        request.url?.path.hasSuffix("/api/v1/public/legal/acceptances") == true
    }

    /// Status requests get `statusBody`; acceptances get `acceptanceStatus` (nil: offline).
    static func legalHandler(statusBody: String = legalBody, acceptanceStatus: Int?) -> StubProtocol.Handler {
        { request in
            if isAcceptance(request) {
                guard let code = acceptanceStatus else { throw URLError(.notConnectedToInternet) }
                return (code, [:], Data(#"{"kind":"privacy","version":3,"acceptedAt":"2026-11-06T10:00:00.000Z"}"#.utf8))
            }
            return (200, ["ETag": "W/\"legal\""], Data(statusBody.utf8))
        }
    }

    func testDecodesLegalDocuments() throws {
        let status = try AppControl.decode(Data(Self.legalBody.utf8))
        XCTAssertEqual(status.legal.count, 2)
        let privacy = status.legal[0]
        XCTAssertEqual(privacy.kind, "privacy")
        XCTAssertEqual(privacy.version, 3)
        XCTAssertEqual(privacy.title, "Privacy policy")
        XCTAssertEqual(privacy.url, URL(string: "https://example.test/legal/app/privacy/it"))
        XCTAssertEqual(privacy.updatedAt, ISODate.parse("2026-11-01T09:00:00Z"))
        XCTAssertTrue(privacy.requiresAcceptance)
        XCTAssertEqual(privacy.needsAcceptance, true)
        XCTAssertEqual(status.pendingLegal.map(\.kind), ["privacy"])
    }

    func testLegalDecodingIsTolerant() throws {
        let json = """
        { "update": "none", "legal": [
          { "kind": "privacy", "version": 2, "needsAcceptance": null, "future": 1 },
          { "kind": "terms", "version": "x" },
          { "version": 1 },
          "nonsense",
          { "kind": "eula", "version": 1, "title": "EULA", "url": null, "requiresAcceptance": "yes" }
        ] }
        """
        let status = try AppControl.decode(Data(json.utf8))
        XCTAssertEqual(status.legal.map(\.kind), ["privacy", "eula"])
        XCTAssertEqual(status.legal[0].title, "privacy")
        XCTAssertNil(status.legal[0].needsAcceptance)
        XCTAssertFalse(status.legal[1].requiresAcceptance)
        XCTAssertNil(status.legal[1].url)

        let notAnArray = try AppControl.decode(Data(#"{ "legal": { "kind": "privacy" } }"#.utf8))
        XCTAssertEqual(notAnArray.legal, [])
    }

    func testAcceptEncodesTheRequest() async throws {
        StubProtocol.handler = Self.legalHandler(acceptanceStatus: 201)
        let client = makeClient()
        let status = await client.status()
        await client.accept(try XCTUnwrap(status.pendingLegal.first))

        let request = try XCTUnwrap(StubProtocol.requests.first(where: Self.isAcceptance))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/base/api/v1/public/legal/acceptances")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONDecoder().decode(AppControl.AcceptanceBody.self, from: XCTUnwrap(Self.bodyData(request)))
        let installation = await client.installationId()
        XCTAssertEqual(body, AppControl.AcceptanceBody(key: Self.key, installation: installation, kind: "privacy", version: 3,
                                                       platform: "macos", locale: "it-IT", appVersion: "2.3.1"))
        let pending = await client.pendingAcceptanceCount()
        XCTAssertEqual(pending, 0)
    }

    func testAcceptUpdatesTheCachedStatus() async throws {
        StubProtocol.handler = Self.legalHandler(acceptanceStatus: 201)
        let client = makeClient()
        let before = await client.status()
        XCTAssertEqual(before.pendingLegal.count, 1)
        await client.accept(before.pendingLegal[0])

        // Within checkAfter: the reused answer no longer asks.
        let after = await client.status()
        XCTAssertEqual(StubProtocol.requests.filter { !Self.isAcceptance($0) }.count, 1)
        XCTAssertEqual(after.legal.first?.needsAcceptance, false)
        XCTAssertTrue(after.pendingLegal.isEmpty)
        // After a relaunch too.
        let relaunched = await makeClient().status()
        XCTAssertTrue(relaunched.pendingLegal.isEmpty)
    }

    func testOfflineAcceptanceIsQueuedAndRetriedOnTheNextStatus() async throws {
        StubProtocol.handler = Self.legalHandler(acceptanceStatus: nil)
        let client = makeClient()
        let fetched = await client.status()
        let document = try XCTUnwrap(fetched.pendingLegal.first)
        await client.accept(document)

        let queued = await client.pendingAcceptanceCount()
        XCTAssertEqual(queued, 1)
        let offline = await client.status()
        XCTAssertTrue(offline.pendingLegal.isEmpty, "a queued acceptance already counts")

        // Back online: the next status() that asks the server sends it first.
        StubProtocol.handler = Self.legalHandler(
            statusBody: Self.legalBody.replacingOccurrences(of: #""needsAcceptance": true"#, with: #""needsAcceptance": false"#),
            acceptanceStatus: 201)
        let countBefore = StubProtocol.requests.count
        let online = await client.status(force: true)
        let newRequests = StubProtocol.requests.dropFirst(countBefore)
        XCTAssertEqual(newRequests.map(Self.isAcceptance), [true, false])
        let remaining = await client.pendingAcceptanceCount()
        XCTAssertEqual(remaining, 0)
        XCTAssertTrue(online.pendingLegal.isEmpty)
        let state = await client.readLegalState()
        XCTAssertEqual(state, AppControl.LegalState(), "the server's answer reflects it: nothing kept")
    }

    func testRejectedAcceptanceIsDropped() async throws {
        StubProtocol.handler = Self.legalHandler(acceptanceStatus: 409)
        let client = makeClient()
        let fetched = await client.status()
        let document = try XCTUnwrap(fetched.pendingLegal.first)
        await client.accept(document)
        let pending = await client.pendingAcceptanceCount()
        XCTAssertEqual(pending, 0)
        let status = await client.status()
        XCTAssertEqual(status.pendingLegal.count, 1, "the server refused it: ask again")
    }

    func testAnAcceptanceOfAnOlderVersionDoesNotCoverANewerOne() async throws {
        StubProtocol.handler = Self.legalHandler(acceptanceStatus: nil)
        let client = makeClient()
        await client.accept(LegalDocument(kind: "privacy", version: 2, title: "Old"))
        let status = await client.status()
        XCTAssertEqual(status.pendingLegal.map(\.version), [3])
    }

    func testStatusUpdatesReflectsAnAcceptance() async throws {
        StubProtocol.handler = Self.legalHandler(acceptanceStatus: 201)
        let client = makeClient()
        var iterator = client.statusUpdates().makeAsyncIterator()
        let firstValue = await iterator.next()
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.pendingLegal.count, 1)
        await client.accept(first.pendingLegal[0])
        let nextValue = await iterator.next()
        let next = try XCTUnwrap(nextValue)
        XCTAssertTrue(next.pendingLegal.isEmpty)
    }

    func testVersionPattern() {
        XCTAssertTrue(AppControl.isValidVersion("2.3.1"))
        XCTAssertTrue(AppControl.isValidVersion("v1"))
        XCTAssertFalse(AppControl.isValidVersion("2.3.1-beta"))
        XCTAssertFalse(AppControl.isValidVersion("0.1.2.3.4"))
    }
}
