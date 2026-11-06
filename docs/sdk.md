# SDKs

Two small clients so an app needs only a few lines to ask app-control "should I ask the user to update? is
there maintenance?".

| SDK | Folder | Entry point |
|---|---|---|
| Swift (iOS, macOS, tvOS, watchOS, visionOS) | [this package](../README.md) | `AppControl` actor, `.appControlGate(_:)` SwiftUI modifier |
| JavaScript / TypeScript (web) | `@app-control/sdk` (not published yet: ask for the file) | `createAppControl({ key, version })` |

Both take the **environment's public key** (`ack_…`, in Settings → Environments → Integrate). The key isn't a
secret: it only identifies the environment.

## The endpoint

```
GET {baseURL}/api/v1/public/status?key=&platform=&version=&build=&channel=&locale=&installation=&os=
```

No user authentication, CORS open (`*`, no credentials), weak `ETag` with `If-None-Match` → 304. The full
contract is in the API reference of your app-control server (`/docs`, audience `public`).

```json
{
  "update": "available",
  "latest": { "version": "2.4.0", "build": "312", "notes": "…", "storeUrl": "https://…", "publishedAt": "…" },
  "minimum": { "version": "2.2.0" },
  "maintenance": null,
  "upcomingMaintenance": { "startsAt": "…", "endsAt": null, "message": "…", "blocking": false },
  "legal": [],
  "checkAfter": 300,
  "installation": "a1b2c3d4"
}
```

The SDKs flatten `minimum` to a string (`"2.2.0"`) and add `source` (`network`, `cache` or `default`) and
`fetchedAt`. `installation` is kept apart, as the installation label (below).

## Shared behaviour

- **Never blocks, never throws:** a 5 s timeout. On any failure the SDK returns the last cached answer, or a
  neutral one (`update: none`, everything else null, `legal: []`).
- **Cache:** the last 200 body plus its `ETag`, per key. A 304 returns the cached body, marked `network`. A
  cached answer made for another version, build, channel or locale is not reused.
- **`checkAfter`:** `status()` reuses the cached answer while it is younger than `checkAfter` seconds, unless
  forced. The watching helpers (`statusUpdates()` in Swift, `subscribe()` in JS) always ask the server when they
  start, that is on each launch and each return to the foreground or to a visible page (an unchanged answer
  costs a 304), then wait `checkAfter` between calls (at least 30 s), only while the app is in the foreground
  or the page visible.
- **Installation id:** a random UUID made once and stored. It is the rollout bucket, so an installation stays
  on the same side of a gradual rollout.
- **Installation label:** when the request has an installation id, the answer carries `installation`, a short
  label (8 hex characters, e.g. `a1b2c3d4`) of the per-app hash of that id. The SDK stores the last one and
  updates it from each network answer; a missing or malformed label leaves the stored one. Read it without a
  network call: Swift `appControl.installationLabel` (a `nonisolated` property, `String?`), JS
  `await appControl.installationLabel()` (`string | null`). Both are `nil`/`null` before the first answer.
- **Defaults:** base URL `https://app-control.srvly.it`, channel `store`, locale from the system; version and
  build from the bundle in Swift, while in JS the version is required.

## What the app should do

| Answer | What to show |
|---|---|
| `update: "required"` | Block the app with an "Update" button that opens `latest.storeUrl`. |
| `update: "available"` | A dismissible banner ("Version 2.4.0 is out"), remembered per version. |
| `maintenance.blocking: true` | A full screen with `maintenance.message` and, if set, until when (`endsAt`). |
| `maintenance.blocking: false` | A banner with the message. |
| `upcomingMaintenance` | Optional: a heads-up banner with the start time. |
| `source: "default"` | Nothing: the app runs normally. |
| `installationLabel` | Show it in Settings or About as "ID a1b2c3d4": it's how the developer finds this device in Stats → Recent installations. |

The SwiftUI `.appControlGate(appControl)` modifier does all of this but the label; on the web, the JavaScript
client's README has a React example.

## Integration guidelines

Follow these in every app (the AI prompts in app-control's Integrate dialog say the same):

1. **Use the app's design system.** The update and maintenance screens must look like the rest of the app: its
   colours and theme (light and dark), typography, components (buttons, banners, sheets, full-screen states) and
   localisation. The ready-made SwiftUI `.appControlGate` has a neutral look: keep it only in apps without a
   design system of their own; otherwise build the screens with the app's components and drive them from
   `statusUpdates()` (Swift) or `subscribe()` (JS), as in the table above.
2. **Show the version and the installation label in Settings.** Always show the app's version and build
   ("Version 1.2.0 (45)", read from the app, never hard-coded) in the Settings screen, or in the profile or
   account page when there is no Settings screen; if it's not clear where, ask the app's owner rather than adding
   a new screen. Next to it, the installation label ("ID a1b2c3d4", selectable or copied on tap), styled like the
   app's other secondary rows.
3. **Keep the SDK's checks and cache.** Don't add your own cache, timers, polling or retries:
   - the SDK stores the last answer and its ETag (an unchanged answer costs a 304), and offline returns the cached
     answer or a neutral one; it never throws;
   - `statusUpdates()` / `subscribe()` ask the server when they start (each launch and each return to the
     foreground or to a visible page), then every `checkAfter` seconds, only while the app is in the foreground;
     start them at the app root, once;
   - elsewhere, `status()` reuses the fresh answer; `force: true` only behind an explicit user action
     ("Check again");
   - never block launch or show a loader for the status: render the app at once, show the screens when the
     answer arrives.

## Testing on a device

To see the update and maintenance screens on a real device without publishing anything:

1. Show the installation label in the app's Settings or About screen ("ID a1b2c3d4", see above).
2. In app-control, open the app's **Versions → Test in app**, enter that label (or pick the device from Stats →
   Recent installations), choose the environment, the kind (update available, update required, maintenance)
   and the duration (5–60 minutes), and start. A non-production environment can also be tested as a whole.
3. Open the app on that device or bring it to the foreground. The answer keeps the same keys with test values:
   update `9999.0.0` (also the minimum when required) or a blocking maintenance until the test ends.
   While a test applies, `checkAfter` is 30 seconds, so the app returns to normal within 30 seconds of the
   test's end or stop.

The SDKs need no change. With Swift 0.3.1 and later (and the JS client), the app asks again each time it is
opened or brought back to the foreground, so starting or stopping a test shows up at once there.

## Legal documents

The app's legal documents in force (privacy, terms, cookie, EULA) come in the status answer, in `LEGAL_KINDS`
order and in the requested locale.

```json
"legal": [{ "kind": "privacy", "version": 3, "title": "Privacy policy", "url": "https://…/legal/{appId}/privacy/it",
            "updatedAt": "…", "requiresAcceptance": true, "acceptFrom": 2 }]
```

- **`url`** is the hosted page: link it in the app (e.g. Settings → Privacy).
- **`requiresAcceptance`:** users must accept this document (this version, or an earlier one asked for
  acceptance).
- **`acceptFrom`:** the lowest version a user must have accepted, or `null` when no version asks for acceptance.
- **app-control doesn't record acceptances.** If the app has its own backend and accounts, the backend stores
  the version each user accepted and compares it with `acceptFrom`: when the stored version is lower, the app
  asks the user to accept again. The SDKs have no `accept()` and the gate shows no acceptance sheet.
- Decoding is tolerant: a malformed entry is dropped, never the whole answer; an unknown or malformed field
  is ignored.

## Privacy

app-control stores only a per-app hash of the random installation id, never an IP address, and only for the
workspace's retention period (12 months by default for new workspaces). A sentence for the app's privacy policy:

> To check for updates and maintenance, the app sends its version, platform, language and a random
> installation identifier to our service. The service keeps only a per-app hash of that identifier, with no
> IP address, for a limited period. It is not linked to you or to your device, and no personal data is
> collected.
