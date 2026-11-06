# AppControl for Swift

A small client for the app-control Version API: "should I ask the user to update? is there maintenance?".
iOS 15, macOS 12, tvOS 15, watchOS 8, visionOS 1. No dependencies.

- **One call:** `GET /api/v1/public/status` with the environment's public key.
- **Never blocks, never throws:** 5 s timeout; on any failure you get the last cached answer (`source: .cache`) or a neutral one (`update: .none`, `source: .default`).
- **Cheap:** the last answer and its `ETag` are stored; an unchanged answer costs a 304. Within `checkAfter` seconds `status()` reuses the answer without a request; opening the app or bringing it back always asks the server.

## Install

Swift Package Manager, in Xcode (File → Add Package Dependencies…) or in `Package.swift`:

```swift
.package(url: "https://github.com/federico-it/app-control-swift.git", from: "0.3.1"),
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

To keep the status fresh, `statusUpdates()` asks the server at once (each launch and each return to the foreground, never reusing an earlier answer), then checks every `checkAfter` seconds (at least 30) and yields only when the answer changes. Consume it while the app is active:

```swift
.task(id: scenePhase) {
    guard scenePhase == .active else { return }
    for await status in appControl.statusUpdates() { self.status = status }
}
```

## SwiftUI gate

One modifier does the whole job, with a neutral look. **If the app has its own design system, build the
screens with its components instead** and drive them from `statusUpdates()` (see the
[integration guidelines](https://github.com/federico-it/app-control-swift/blob/main/docs/sdk.md#integration-guidelines)):

```swift
struct AppStatusGate: ViewModifier {
    let appControl: AppControl
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: AppStatus?

    func body(content: Content) -> some View {
        content
            .overlay { if let status { AppStatusScreens(status: status) } } // your own views
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                for await next in appControl.statusUpdates() { status = next }
            }
    }
}
```

The ready-made gate:

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

## Installation label

`appControl.installationLabel` is a short label for this installation, e.g. `a1b2c3d4` (8 hex characters), or `nil` before the first answer from the server. It's the label the app's **Stats → Recent installations** shows, so it's how you find this device there. Keep it hidden: 5 taps on the version row in Settings reveal it.

```swift
@State private var versionTaps = 0

Section("About") {
    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
        .contentShape(Rectangle())
        .onTapGesture { versionTaps += 1 }
    if versionTaps >= 5, let label = appControl.installationLabel {
        Text("ID \(label)").font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }
}
```

It is stored in `UserDefaults` and updated from each answer of the server, so reading it never waits for the network and works offline. It is `nonisolated`: no `await` needed.

## Legal documents

`status.legal` lists the app's legal documents in force (privacy, terms, cookie, EULA) in the requested locale: `kind`, `version`, `title`, `url` (the hosted page), `updatedAt`, `requiresAcceptance` and `acceptFrom`.

- **Link them** in the app, e.g. Settings → Privacy:

  ```swift
  ForEach(status.legal) { document in
      if let url = document.url { Link(document.title, destination: url) }
  }
  ```

- **Acceptance belongs to your backend.** app-control doesn't record who accepted what. If the app has its own backend and accounts, store the version each user accepted there; `acceptFrom` is the lowest version a user must have accepted (`nil` when no version asks for acceptance). When the stored version is lower than `acceptFrom`, ask the user to accept again.

Decoding is tolerant: a malformed document is dropped, never the whole answer.

## Privacy

The SDK sends the app's version, build, channel, language, platform and system version, plus a random installation id made on the first run. The server keeps only a per-app hash of that id, never an IP address, and only for the workspace's retention period (12 months by default). The id is never linked to the user, the device or an advertising id. On the device the SDK stores only that id, its short label and the last answer.

A sentence for your privacy policy: *"To tell you about updates and maintenance, the app sends its version and a random installation identifier to our update service. The service keeps only a per-app hash of that identifier, with no IP address, for a limited period. It is not linked to you or your device."*

## Development

```sh
cd sdks/swift
swift build
swift test
```

## Documentation

- [SDK overview: the status endpoint, what the app should show, integration guidelines, legal documents](docs/sdk.md)
- [API tokens: scopes, roles, CI recipes](docs/api-tokens.md)
- [Webhooks: Slack, Discord and signed URLs](docs/webhooks.md)
