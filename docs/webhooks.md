# Webhooks

A workspace can send its events to **Slack**, **Discord** or **any HTTPS URL**. Workspace owners and admins manage
the webhooks in the web app (workspace settings → Webhooks) or through the API
(`/api/v1/workspaces/{workspaceId}/webhooks`, user session only: API tokens can't manage webhooks).

Each webhook chooses:

- **events**: one or more of the kinds below;
- **apps**: every app of the workspace (also future ones) or a list; events without an app (`connection_failed`)
  always go to every webhook subscribed to them;
- **language** (`en` or `it`) of Slack and Discord messages.

At most **20 webhooks per workspace**. The URL is stored encrypted and never shown again: lists only show its host.

## Kinds

| Kind | URL | What is sent |
|---|---|---|
| `slack` | `https://hooks.slack.com/services/…` (or `/triggers/…`): a Slack [incoming webhook](https://api.slack.com/messaging/webhooks) | `{ "text": "PingTxt · version 1.2.0 (iOS) is Ready for distribution\n<link\|Open in App Control>" }` |
| `discord` | `https://discord.com/api/webhooks/…` (also `discordapp.com`, `ptb.discord.com`, `canary.discord.com`): channel settings → Integrations → Webhooks | `{ "content": "…", "allowed_mentions": { "parse": [] } }` |
| `url` | any public `https://` URL | the signed JSON body below |

Chat messages are one short line plus a link to the app page. Names and texts coming from users or Apple are
escaped (Slack `& < >`; Discord markdown and mentions), and Discord never pings anyone.

## Events

`type` is the event kind. `data` is shown per kind; every app-control event also has
`actor: { id, name } | null` (who did it; null for scheduled work).

| Kind | When | `data` |
|---|---|---|
| `version_state_changed` | an App Store version reached a notable state (rejected, action needed, pending release, live) | `versionId`, `versionString`, `platform` (`IOS`…), `from`, `to` (Apple states) |
| `build_processed` | a build **failed** processing (`FAILED` / `INVALID`) | `buildId`, `buildNumber`, `versionString` (or null), `state` |
| `build_ready` | a build finished processing (`VALID`) | same as `build_processed` |
| `beta_review_changed` | TestFlight Beta App Review reached a final state | `buildId`, `buildNumber`, `versionString`, `from`, `to` |
| `phased_release_changed` | a phased release was paused or completed | `versionId`, `versionString`, `from`, `to`, `currentDayNumber` |
| `review_received` | new customer reviews (one event per sync) | `count`, `lowestRating`, `reviewIds` |
| `connection_failed` | an Apple connection stopped working (no app) | `connectionId`, `connectionName`, `error` |
| `release_published` | a release of the version API was published (now or at its scheduled date) | `actor`, `releaseId`, `environmentId`, `environmentName`, `platform`, `version`, `rolloutPercent` |
| `maintenance_scheduled` | a maintenance window was created | `actor`, `windowId`, `environmentName` (null: every environment), `startsAt`, `endsAt` (or null), `blocking` |
| `maintenance_ended` | a maintenance window was ended by hand | `actor`, `windowId`, `environmentName` |
| `legal_published` | a legal document version was published | `actor`, `documentId`, `kind` (`privacy`, `terms`, `cookie`, `eula`), `version`, `requiresAcceptance`, `acceptFrom` |
| `store_action_succeeded` | a confirmed App Store action finished | `actor`, `actionId`, `kind` (e.g. `submit_for_review`), `versionString`, `error` (null) |
| `store_action_failed` | a confirmed App Store action failed | same, with a short `error` |
| `test` | the "Send test" button | `{ "webhookId": "…", "message": "This is a test delivery from App Control." }` |

Intermediate states (waiting for review, phased release started, …) are never sent. New kinds and new `data`
fields may be added: ignore what you don't know.

## The `url` body

```http
POST /your/endpoint HTTP/1.1
Content-Type: application/json
User-Agent: app-control-webhooks/1
X-AppControl-Event: release_published
X-AppControl-Delivery: 3c4d5e6f-7a8b-4c9d-8e1f-2a3b4c5d6e7f
X-AppControl-Signature: t=1730887920,v1=5f0c…e9a1
```

```json
{
  "id": "4d5e6f7a-8b9c-4d0e-9f2a-3b4c5d6e7f8a",
  "type": "release_published",
  "occurredAt": "2026-11-06T09:11:59.000Z",
  "workspace": { "id": "9b1c…", "slug": "acme", "name": "Acme" },
  "app": { "id": "3f6c…", "name": "PingTxt" },
  "data": {
    "actor": { "id": "5d2c…", "name": "Ada" },
    "releaseId": "…", "environmentId": "…", "environmentName": "Production",
    "platform": "ios", "version": "1.2.0", "rolloutPercent": 100
  },
  "link": "https://app.example.com/apps/3f6c…/releases"
}
```

- `id` is the event id (the same on every retry and redelivery: use it to ignore duplicates); for a test it is
  the delivery id.
- `app` is null for `connection_failed` and `test`.
- `X-AppControl-Delivery` identifies the delivery (one per event and webhook), shown in the delivery log.

Answer with any **2xx** within **10 seconds**. Anything else is a failure: other statuses, redirects (3xx are not
followed), timeouts and connection errors. At most 8 KB of your answer is read, then discarded.

## Verifying the signature

`X-AppControl-Signature: t=<unix seconds>,v1=<hex>` where `v1 = HMAC-SHA256(secret, "<t>.<raw body>")`. The key is
**the whole secret as shown**, `whsec_` prefix included. The secret is shown once, when the webhook is created
or its secret is rotated (the old secret stops working at once).

Always verify against the **raw** body bytes (before any JSON parsing), compare in constant time, and reject a
`t` more than 5 minutes away from your clock (replays).

### Node.js

```js
import { createHmac, timingSafeEqual } from 'node:crypto';

/** rawBody: the request body exactly as received (Buffer or string). */
export function verifyAppControl(secret, header, rawBody) {
  const parts = Object.fromEntries(
    String(header ?? '').split(',').map((p) => p.split('=', 2)),
  );
  const t = Number(parts.t);
  if (!Number.isInteger(t) || Math.abs(Date.now() / 1000 - t) > 300) return false;
  const expected = createHmac('sha256', secret).update(`${t}.${rawBody}`).digest();
  const given = Buffer.from(parts.v1 ?? '', 'hex');
  return given.length === expected.length && timingSafeEqual(given, expected);
}

// Express: app.post('/hooks/app-control', express.raw({ type: 'application/json' }), (req, res) => {
//   if (!verifyAppControl(process.env.APP_CONTROL_WEBHOOK_SECRET, req.get('X-AppControl-Signature'), req.body))
//     return res.sendStatus(401);
//   const event = JSON.parse(req.body);
//   res.sendStatus(204);
// });
```

### Python

```python
import hashlib, hmac, time

def verify_app_control(secret: str, header: str, raw_body: bytes) -> bool:
    parts = dict(p.split("=", 1) for p in (header or "").split(",") if "=" in p)
    try:
        t = int(parts["t"])
    except (KeyError, ValueError):
        return False
    if abs(time.time() - t) > 300:
        return False
    expected = hmac.new(
        secret.encode(), f"{t}.".encode() + raw_body, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, parts.get("v1", ""))
```

## Retries, the delivery log and auto-disable

- A failed attempt is retried after **1 min, 5 min, 30 min, 2 h, 6 h and 12 h**: 7 attempts in about 20.6 hours.
  The body (and its `id`) stays the same; the signature is computed again with a new `t`.
- Each webhook keeps its **last 100 deliveries**: event, status (`pending`, `succeeded`, `failed`), attempts, HTTP
  status, a short error (`timeout`, `dns`, `blocked_address`, `http_<code>`, `connection`, `webhook disabled`,
  `event_deleted`), duration and the next attempt. A failed delivery can be **redelivered** (from attempt 1) while
  the webhook is on.
- **Auto-disable:** when a delivery fails its last attempt and the webhook had no success since that delivery was
  created, the webhook is turned off (`disabledReason: "failing"`), audited as `webhook.disabled`, and its creator
  gets an email (or the workspace owners, if the creator is no longer an owner or admin). Pending deliveries of a
  turned-off webhook fail with `webhook disabled`. Turn it back on from the web app (or `PATCH` with
  `enabled: true`) after fixing your endpoint.
- **Send test** makes one attempt (no retries), also when the webhook is off, and never turns it off.

## Network rules

Webhooks only reach public addresses: the host is resolved first and the request is refused (`blocked_address`)
when any of its addresses is loopback, private, link-local, CGNAT, unique-local, multicast, reserved or unspecified
(IPv4 and IPv6, IPv4-mapped included). The connection then goes to that checked address only. Operators can lift
this for development and tests with `WEBHOOKS_ALLOW_PRIVATE=true`, which also allows `http://` URLs.

## Audit

`webhook.created`, `webhook.updated`, `webhook.deleted`, `webhook.secret_rotated`, `webhook.test_sent`,
`webhook.redelivered`, `webhook.disabled`. Their metadata holds the workspace, webhook id, kind and host; never the
URL or the secret.
