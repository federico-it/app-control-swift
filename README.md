# AppControl for Swift

A small client for the app-control Version API: "should I ask the user to update? is there maintenance?".
iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1. No dependencies.

- **One call:** `GET /api/v1/public/status` with the environment's public key.
- **Never blocks, never throws:** 5 s timeout; on any failure you get the last cached answer (`source: .cache`) or a neutral one (`update: .none`, `source: .default`).
- **Cheap:** the last answer and its `ETag` are stored; an unchanged answer costs a 304. Within `checkAfter` seconds the answer is reused without a request.

## Install

Swift Package Manager, in Xcode (File → Add Package Dependencies…) or in `Package.swift`:

```swift
.package(url: "https://github.com/federico-it/app-control-swift.git", from: "0.1.0"),
```

The package is developed in the app-control monorepo (`sdks/swift`) and published to
[federico-it/app-control-swift](https://github.com/federico-it/app-control-swift) with a version tag.

Then add the `AppControl` product to your target.

## Quick start

```swift
import AppControl

let appControl = AppControl(key: "ack_…") // the environment's public key: not a secret

let status = await appControl.status()
switch status.update {
case .required: showBlockingUpdate(status.latest?.storeURL)
case .available: showUpdateBanner(status.latest)
case .none: break
}
if let maintenance = status.maintenance, maintenance.blocking { showMaintenance(maintenance) }
```

Every argument but `key` is optional:

| Argument | Default |
|---|---|
| `baseURL` | `https://app-control.srvly.it` |
| `version`, `build` | `CFBundleShortVersionString`, `CFBundleVersion` |
| `channel` | detected once: `DEBUG` build → `.debug`, TestFlight → `.testflight`, else `.store` |
| `locale` | the user's preferred language |
| `defaults` | `UserDefaults.standard` |
| `session` | an ephemeral session with a 5 s timeout |

To keep the status fresh, `statusUpdates()` yields at once, then checks every `checkAfter` seconds (at least 30) and yields only when the answer changes. Consume it while the app is active:

```swift
.task(id: scenePhase) {
    guard scenePhase == .active else { return }
    for await status in appControl.statusUpdates() { self.status = status }
}
```

## SwiftUI gate

One modifier does the whole job:

```swift
@main
struct MyApp: App {
    let appControl = AppControl(key: "ack_…")

    var body: some Scene {
        WindowGroup {
            ContentView().appControlGate(appControl)
        }
    }
}
```

- **Required update** or **blocking maintenance:** a full-screen cover (with "Update", which opens the store URL, or "Try again" and the expected end).
- **Available update** or **non-blocking maintenance:** a dismissible banner. A dismissed update stays hidden until a newer version comes.
- It checks again whenever the scene becomes active.
- Texts are built in for English and Italian; pass your own with `.appControlGate(appControl, texts: AppControlGateTexts(…))` or adjust `AppControlGateTexts.english`.
- With `legal: true` it also asks the user to accept legal documents (see below).

## Legal documents

`status.legal` lists the app's published documents (privacy, terms, cookie, EULA) in the requested locale: `kind`, `version`, `title`, `url` (the hosted page), `updatedAt`, `requiresAcceptance` and `needsAcceptance`. `status.pendingLegal` is the subset with `needsAcceptance == true`: a new version that requires acceptance, or none accepted yet on this installation.

```swift
for document in status.pendingLegal {
    // show document.title, link document.url, then when the user accepts:
    await appControl.accept(document)
}
```

`accept(_:)` posts the kind, version, installation id, platform, locale and app version. It never throws: offline, the acceptance is kept in `UserDefaults` and sent again before the next `status()` that asks the server. Either way, `status()` and `statusUpdates()` report `needsAcceptance == false` from then on, so the app doesn't ask again.

The gate can do it for you:

```swift
ContentView().appControlGate(appControl, legal: true)
```

It shows a sheet the user cannot dismiss, listing the documents to accept with links to read them and one "Accept" button. The texts (`legalTitle`, `legalMessage`, `legalVersion`, `legalAcceptButton`) are in English and Italian and can be overridden through `AppControlGateTexts`. The sheet waits while a required update or a blocking maintenance is on screen.

### Installation id for GDPR requests

Only a hash of the installation id is stored with an acceptance. To see or erase a user's acceptances, the admin needs that id, so let the user find it without cluttering the UI: 5 taps within about 3 seconds on the label that shows the app version reveal `installationId()` with a Copy button.

```swift
struct VersionLabel: View {
    let appControl: AppControl
    @State private var taps: [Date] = []
    @State private var installationId: String?

    var body: some View {
        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
            .onTapGesture {
                let now = Date()
                taps = taps.filter { now.timeIntervalSince($0) < 3 } + [now]
                guard taps.count >= 5 else { return }
                taps = []
                Task { installationId = await appControl.installationId() }
            }
            .alert("Installation ID", isPresented: .constant(installationId != nil), presenting: installationId) { id in
                Button("Copy") { UIPasteboard.general.string = id; installationId = nil } // iOS; NSPasteboard on macOS
                Button("Close", role: .cancel) { installationId = nil }
            } message: { id in
                Text("\(id)\n\nShare it with us to see or erase your data.")
            }
    }
}
```

## Privacy

The SDK sends the app's version, build, channel, language, platform and system version, plus a random installation id made on the first run. That id is never linked to the user, the device or an advertising id; it only places the installation in a rollout bucket. The SDK stores nothing else on the device but that id, the last answer and the acceptances not yet delivered, and collects no IP address or user data. An acceptance adds the document's kind and version; the server keeps only a hash of the installation id.

A sentence for your privacy policy: *"To tell you about updates and maintenance, the app sends its version and a random installation identifier to our update service. This identifier is not linked to you or your device."*

## Development

```sh
cd sdks/swift
swift build
swift test
```

## Documentation

- [SDK overview: the status endpoint, what the app should show, legal documents](docs/sdk.md)
- [API tokens: scopes, roles, CI recipes](docs/api-tokens.md)
