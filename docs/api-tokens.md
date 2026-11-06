# API tokens

Workspace API tokens let CI jobs and integrations call the REST API without a user session. For example, a
release pipeline can create a draft release for a new build, publish it once the App Store sells the version,
or check how many users a new minimum version would force to update.

Create and revoke them in **Workspace settings → API tokens** (workspace admins and owners).

## How a token works

- **Format:** `acp_` followed by 43 characters, e.g. `acp_3q2…`. The prefix lets secret scanners (GitHub,
  GitLab…) flag a leaked token.
- **Shown once.** Only a hash is stored. Lists show the first characters (`acp_abc123…`) so you can tell
  tokens apart. If you lose a token, revoke it and create a new one.
- **Header:** the same as a signed-in user:

  ```sh
  curl -H "Authorization: Bearer $APP_CONTROL_TOKEN" https://app.example.com/api/v1/apps
  ```

- **It acts for you, capped.** Every request is checked against four limits, and the lowest one wins:
  1. **your own access**, checked live on every request: if you leave the workspace or are demoted, the token
     loses that power too, and if your account is disabled or deleted it stops working;
  2. **the token's workspace**: it never reaches another workspace, even one you belong to;
  3. **its apps**, when you pick some: other apps answer `404`, as if they didn't exist;
  4. **its role and scopes** (below).
- **Expiry:** 30, 90 (the default), 180 or 365 days, or never. An expired or revoked token gets `401`.
- **Audit:** everything done with a token is logged with you as the actor and the token's id, so the audit
  log tells a person from a pipeline. Creating and revoking a token are logged too (`api_token.created`,
  `api_token.revoked`); the token itself never is.
- **Rate limit:** each token has its own budget, the same as a signed-in user.
- **Creating a token** asks you to confirm your identity (password, code or passkey) if you haven't recently.

## Scopes

A token can only call routes that declare a scope, and only with a scope it has. `write` includes `read` of
the same area (`releases:write` can also read releases).

| Scope | What it allows |
|---|---|
| `apps:read` | `GET /workspaces`, `GET /workspaces/{id}` (and by slug), `GET /apps` (list and get), environments (list only, never the key rotation), `GET …/versions`, `GET …/maintenance`, the "needs attention" GETs |
| `releases:read` | every `GET` of releases (list, get, publish checks) |
| `releases:write` | create, update, delete a draft, publish (also with `whenOnSale`), schedule, rollout actions, withdraw |
| `maintenance:write` | create, update, end and delete maintenance windows |
| `store:read` | every `GET` of the App Store mirror: versions, builds, TestFlight groups and testers, ratings, reviews, listing and localizations, screenshots; and the store actions `GET`s |
| `store:write` | store actions plan / confirm / retry / cancel, "sync now", review replies, screenshot uploads |
| `stats:read` | every usage stats `GET`, including the impact of a release (not the delete) |
| `legal:read` | legal documents `GET /` and `GET /{documentId}` |
| `legal:write` | legal documents create, update, delete a draft, publish (not the acceptances routes) |

A token request to a route without a scope gets `403 forbidden` ("This route can't be used with an API
token"); a token without the needed scope gets `403 forbidden` ("The API token lacks the scope X").

**Never with a token**, by design: your account, sessions, MFA and passkeys; creating, updating or deleting
workspaces; members, invitations and app members; Apple connections; creating, updating, deleting
environments and rotating their keys; API tokens themselves; realtime tickets; superadmin routes; deleting
stats; looking up and erasing legal acceptances (GDPR requests stay with a person).

## Roles

The token's role caps what it can do inside the scopes. It can't be higher than your own role in the
workspace (owners and admins act as app `admin`, members as `editor`, viewers as `viewer`).

| Token role | App role it acts with | Workspace role it acts with | In practice |
|---|---|---|---|
| `viewer` | `viewer` | `viewer` | Reads only, whatever the scopes |
| `editor` | `editor` | `member` | Creates and edits draft releases; can't publish |
| `admin` | `admin` | `admin` | Also publishes releases and runs store actions |

Each limit is the lower of your role and the token's: an `admin` token made by someone later demoted to
`viewer` can only read.

## CI recipes

The examples use two secrets and a few variables:

```sh
export APP_CONTROL_URL=https://app.example.com/api/v1   # your server + /api/v1
export APP_CONTROL_TOKEN=acp_…                           # a CI secret, never committed
export APP_ID=…                                          # from the app's page URL (/apps/{id}), or GET /apps
export ENVIRONMENT_ID=…                                  # GET /apps/$APP_ID/environments
```

### Create a draft release for a new build

Token: `releases:write`, role `editor` or higher.

```sh
curl -sS --fail-with-body -X POST "$APP_CONTROL_URL/apps/$APP_ID/releases" \
  -H "Authorization: Bearer $APP_CONTROL_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"environmentId\":\"$ENVIRONMENT_ID\",\"platform\":\"ios\",\"version\":\"$VERSION\",\"build\":\"$BUILD\",\"notes\":{\"en\":\"Bug fixes.\"}}"
```

The answer is the release (`id`, `state: "draft"`, `rev`…). The same environment, platform and version
can exist once: a second run answers `409 conflict`, which a pipeline can treat as "already there".

### Publish when the App Store sells the version

Token: `releases:write`, role `admin`.

```sh
curl -sS --fail-with-body -X POST "$APP_CONTROL_URL/apps/$APP_ID/releases/$RELEASE_ID/publish" \
  -H "Authorization: Bearer $APP_CONTROL_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"whenOnSale":true}'
```

The release becomes `scheduled` with `awaitingStore` and is published when the App Store sells this version
(at once if it already does). Publishing runs the same checks as the web: a failing check answers
`409 release_checks_failed` with the `checks` in the body. Send `{}` to publish now, or `{"at":"…"}` to
schedule.

### Read the impact before raising the minimum version

Token: `stats:read` (any role).

```sh
curl -sS --fail-with-body -G "$APP_CONTROL_URL/apps/$APP_ID/stats/impact" \
  -H "Authorization: Bearer $APP_CONTROL_TOKEN" \
  --data-urlencode "environmentId=$ENVIRONMENT_ID" \
  --data-urlencode "platform=ios" \
  --data-urlencode "minimumVersion=1.3.0"
```

```json
{ "active30": 1840, "belowMinimum": 212, "belowVersion": 905 }
```

`belowMinimum` is how many of the last 30 days' active installations would be asked to update. A pipeline can
stop when it's too many, e.g. `jq -e '.belowMinimum / .active30 < 0.05'`.

### GitHub Actions

Store the token as a repository or environment secret named `APP_CONTROL_TOKEN`, and the rest as variables.

```yaml
name: Release
on:
  push:
    tags: ["v*"]

jobs:
  app-control:
    runs-on: ubuntu-latest
    environment: production
    env:
      APP_CONTROL_URL: ${{ vars.APP_CONTROL_URL }}       # https://app.example.com/api/v1
      APP_CONTROL_TOKEN: ${{ secrets.APP_CONTROL_TOKEN }}
      APP_ID: ${{ vars.APP_CONTROL_APP_ID }}
      ENVIRONMENT_ID: ${{ vars.APP_CONTROL_ENVIRONMENT_ID }}
    steps:
      - name: Impact of the new minimum version
        run: |
          curl -sS --fail-with-body -G "$APP_CONTROL_URL/apps/$APP_ID/stats/impact" \
            -H "Authorization: Bearer $APP_CONTROL_TOKEN" \
            --data-urlencode "environmentId=$ENVIRONMENT_ID" \
            --data-urlencode "platform=ios" \
            --data-urlencode "minimumVersion=1.3.0" | tee impact.json
          jq -e '.active30 == 0 or .belowMinimum / .active30 < 0.05' impact.json

      - name: Create the draft release
        id: draft
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          BODY=$(jq -n --arg env "$ENVIRONMENT_ID" --arg v "$VERSION" --arg b "$GITHUB_RUN_NUMBER" \
            '{environmentId: $env, platform: "ios", version: $v, build: $b, minimumVersion: "1.3.0"}')
          curl -sS --fail-with-body -X POST "$APP_CONTROL_URL/apps/$APP_ID/releases" \
            -H "Authorization: Bearer $APP_CONTROL_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$BODY" | tee release.json
          echo "id=$(jq -r .id release.json)" >> "$GITHUB_OUTPUT"

      - name: Publish when the App Store sells it
        run: |
          curl -sS --fail-with-body -X POST \
            "$APP_CONTROL_URL/apps/$APP_ID/releases/${{ steps.draft.outputs.id }}/publish" \
            -H "Authorization: Bearer $APP_CONTROL_TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"whenOnSale":true}'
```

This job needs a token with `releases:write` and `stats:read`, role `admin` (publishing), limited to the app.
If only drafts should come from CI, use role `editor` and publish from the web.

## Good practice

- **Least privilege:** one token per pipeline, only the scopes and apps it needs, the lowest role that works.
- **Prefer an expiry**, and rotate before it ends: create the new token, update the CI secret, check a run
  passes, then revoke the old one. The list shows when each token was **last used**, so you can tell whether
  the old one is still in use.
- **Revoke** in Workspace settings → API tokens → Revoke. It takes effect immediately, and revoked tokens stay
  in the list for 30 days for reference. Revoke at once if a token may have leaked (a log, a commit, a
  screenshot): the `acp_` prefix helps secret scanners spot it.
- **Errors:** `401` means the token is wrong, expired or revoked (or its creator was disabled); `403 forbidden`
  means a missing scope or a route tokens can't use; `404` means an app outside the token's apps or workspace.
- The full API reference is in the OpenAPI documents (`/docs/api/v1/openapi.json`); each route shows the scope
  it needs.
