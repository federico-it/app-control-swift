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
  "checkAfter": 300
}
```

The SDKs flatten `minimum` to a string (`"2.2.0"`) and add `source` (`network`, `cache` or `default`) and
`fetchedAt`.

## Shared behaviour

- **Never blocks, never throws:** a 5 s timeout. On any failure the SDK returns the last cached answer, or a
  neutral one (`update: none`, everything else null, `legal: []`).
- **Cache:** the last 200 body plus its `ETag`, per key. A 304 returns the cached body, marked `network`. A
  cached answer made for another version, build, channel or locale is not reused.
- **`checkAfter`:** `status()` reuses the cached answer while it is younger than `checkAfter` seconds, unless
  forced. The watching helpers (`statusUpdates()` in Swift, `subscribe()` in JS) wait `checkAfter` between
  calls (at least 30 s), only while the app is in the foreground or the page visible.
- **Installation id:** a random UUID made once and stored. It is the rollout bucket, so an installation stays
  on the same side of a gradual rollout.
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

The SwiftUI `.appControlGate(appControl)` modifier does all of this; on the web, the JavaScript client's README has a React example.

## Legal documents

The app's published legal documents (privacy, terms, cookie, EULA) come in the status answer, in `LEGAL_KINDS`
order and in the requested locale. The contract is in [`phase-6c.md`](phase-6c.md).

```json
"legal": [{ "kind": "privacy", "version": 3, "title": "Privacy policy", "url": "https://…/legal/{appId}/privacy/it",
            "updatedAt": "…", "requiresAcceptance": true, "needsAcceptance": true }]
```

- **`url`** is the hosted page: link it from the app's settings.
- **`requiresAcceptance`:** installations must accept this document (this version, or an earlier one that had
  the flag and is still covering it).
- **`needsAcceptance`:** `true` when this installation still has to accept this version; `null` without an
  installation id. Decoding is tolerant: a malformed entry is dropped, never the whole answer.
- **`accept(document)`** (Swift `await appControl.accept(document)`, JS `appControl.accept(document)`) posts
  `{ key, installation, kind, version, platform, locale?, appVersion? }` to
  `POST /api/v1/public/legal/acceptances`. It never throws. On failure the acceptance is kept on the device
  (`UserDefaults` / `storage`) and sent again before the next `status()` that asks the server. Either way the
  SDK reports `needsAcceptance: false` for that document from then on, and `statusUpdates()` / `subscribe()`
  get the change at once. An acceptance the server refuses for good (unknown key, version not in force) is
  dropped, so the app asks again.
- **SwiftUI:** `.appControlGate(appControl, legal: true)` shows a sheet the user can't dismiss, with the
  documents to accept, links to read them and one "Accept" button (en/it, overridable).

### The installation id, for GDPR requests

The server stores only a per-app hash of the installation id with each acceptance. To look up or erase an
installation's acceptances (Legal → Acceptances, for app admins) you need the id itself, so the app should let
the user find it without cluttering the UI. The suggested pattern, built by the app: **5 taps within about
3 seconds on the label that shows the app version** reveal `installationId()` with a Copy button and one line
("Share this ID with us to see or erase your data"). The SDK READMEs have a SwiftUI and a JavaScript example.

## Privacy

A sentence for the app's privacy policy:

> To check for updates and maintenance, the app sends its version, platform, language and a random
> installation identifier to our service. The identifier is not linked to you or to your device, and no
> personal data is collected. When you accept our terms or privacy policy, we record which version you
> accepted with that identifier, so we don't ask you again; you can find the identifier by tapping the app
> version 5 times and ask us to erase this record.
