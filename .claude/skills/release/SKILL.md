---
name: release
description: Cut a new Claude Island release. Covers the full pipeline (workflow_dispatch → DMG → Sparkle signing → appcast push to funfun.zone → CF Pages deploy), the fork-Actions trap that silently skips tag triggers, the Sparkle enclosure URL gotcha (generate_appcast defaults are wrong for our hosting split), and how to recover from a broken published appcast without re-releasing. Use when the user asks to "release", "publish", "ship", "tag", or "cut version X.Y.Z".
---

# Releasing Claude Island

The release pipeline is fully automated. CI builds DMGs, signs them with Sparkle, pushes the signed appcast to a separate website repo, and that site auto-deploys. You pick a version, dispatch the workflow, and watch it.

## TL;DR happy path

```bash
VERSION=1.8.0
gh workflow run release.yml --ref main -f version=$VERSION
gh run watch $(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
```

The workflow:

1. Bumps `MARKETING_VERSION` in `ClaudeIsland.xcodeproj/project.pbxproj`, commits `chore: bump version to X.Y.Z [skip ci]` back to main
2. Builds ad-hoc-signed `.app` via `scripts/build.sh`
3. Creates DMG via `scripts/create-release.sh`, signs with Sparkle EdDSA key, generates `appcast.xml` with a `--download-url-prefix` pointing at GitHub Releases (see "Enclosure URL gotcha" below)
4. Creates GitHub Release with DMG attached
5. Scans DMG with VirusTotal (best effort — fails soft)
6. `update-website` job: checks out `ShuminFu/funfun-zone`, copies `appcast.xml` into `public/`, commits, pushes main → Cloudflare Pages auto-redeploys `https://funfun.zone/appcast.xml`

After CI green, verify:

```bash
curl -sS https://funfun.zone/appcast.xml | grep -E 'shortVersion|enclosure url'
# Expect: the version you just cut, and a GitHub releases/download/ URL
```

## Sparkle infrastructure (where everything lives)

This fork runs a **completely independent** Sparkle setup from upstream `farouqaldori/claude-island`. Do not assume upstream's keys/URLs work here.

| Thing | Location | Who controls it |
|---|---|---|
| EdDSA public key | `ClaudeIsland/Info.plist` → `SUPublicEDKey` (`BD+OFwvBWWIIb1fP0vaJhHMNFRi5k2nkbY3raGSOiG0=`) | baked into every built app |
| EdDSA private key | `.sparkle-keys/eddsa_private_key` (gitignored) + `SPARKLE_PRIVATE_KEY` GitHub secret | never committed |
| Feed URL | `ClaudeIsland/Info.plist` → `SUFeedURL` = `https://funfun.zone/appcast.xml` | baked in, changing it breaks already-shipped apps |
| Appcast hosting | `ShuminFu/funfun-zone` repo, file `public/appcast.xml`, served via Cloudflare Pages at the user's Astro blog | pushes from `release.yml` |
| DMG hosting | GitHub Releases on `ShuminFu/claude-island` | the workflow's `softprops/action-gh-release` step |

**Why the split**: `funfun.zone` is a Cloudflare Pages-hosted Astro site (the user's personal blog). The Astro site ships `public/` files verbatim, so dropping `appcast.xml` into `public/` makes it live at the site root. DMGs live on GitHub Releases because CF Pages isn't a good host for large binaries and we already publish them there. This means the enclosure URL in the appcast needs to point at GitHub, not at the same origin as the appcast itself — which brings us to:

## Enclosure URL gotcha — do not remove `--download-url-prefix`

`scripts/create-release.sh` calls `generate_appcast` with `--download-url-prefix` set to `https://github.com/$GITHUB_REPO/releases/download/$VERSION/`. **This flag is load-bearing.** Without it, `generate_appcast` produces enclosure URLs that Sparkle resolves relative to the appcast URL:

```xml
<!-- WRONG (without --download-url-prefix) -->
<enclosure url="https://funfun.zone/ClaudeIsland-1.7.1.dmg" ... />

<!-- RIGHT -->
<enclosure url="https://github.com/ShuminFu/claude-island/releases/download/1.7.1/ClaudeIsland-1.7.1.dmg" ... />
```

Sparkle will happily fetch the wrong URL, get a 404, and fail all auto-updates silently (users just see "update failed"). The EdDSA signature is over the DMG bytes not the URL, so the signature remains valid regardless — meaning a wrong URL is a 100% auto-update break with zero diagnostic.

The script picks the prefix based on `$SKIP_GITHUB`: CI (`--skip-github`) uses bare semver tags (`1.7.1`), local runs use the script's own `gh release create "v$VERSION"` convention (`v1.7.1`). Don't "simplify" this to a single form without verifying which tag convention each path uses.

## Fork trap — tag pushes silently don't trigger workflows

`ShuminFu/claude-island` is a fork of `farouqaldori/claude-island`. GitHub disables automatic workflow triggers on forks by default, even when `gh api repos/:owner/:repo/actions/permissions` reports `enabled: true`. Symptom: `git push origin 1.8.0`, the tag appears on GitHub, but no workflow run is created.

Diagnose:

```bash
gh api repos/:owner/:repo/git/refs/tags --jq '.[].ref'   # tag on remote?
gh run list --limit 10                                    # any runs at all?
gh api repos/:owner/:repo/events --jq '.[] | {type, created_at, ref: .payload.ref}' | head  # event received?
```

**Fixes:**

1. **One-time**: open https://github.com/ShuminFu/claude-island/actions and click "I understand my workflows, go ahead and enable them". Afterwards `git push origin <tag>` triggers normally.
2. **Workaround (recommended)**: use `workflow_dispatch` — the TL;DR path. Works on forks without the banner dance and is the path proven to work end-to-end.

## Secrets the workflow depends on

| Secret | Used by | If missing |
|---|---|---|
| `SPARKLE_PRIVATE_KEY` | `build` job | DMG still built but no EdDSA signature → Sparkle rejects updates → `update-website` job skipped (guarded by `if: has_sparkle && ed_signature != ''`) |
| `FUNFUN_ZONE_PAT` | `update-website` job | `checkout` step 401s → CI red, appcast not pushed to funfun.zone. Must be a fine-grained PAT with Contents R/W on `ShuminFu/funfun-zone` only |
| `VT_API_KEY` | `virustotal-scan` job | 401 from VT, job fails, release still published (VT is decoupled from the critical path). Unset as of 2026-04-11 — expected red in every release until you either set it or delete the VT job |

Check: `gh secret list`.

## Choosing the next version

```bash
gh api repos/:owner/:repo/git/refs/tags --jq '.[].ref' | sed 's|refs/tags/||' | sort -V | tail -5
```

Strict semver. Tag format `[0-9]+.[0-9]+.[0-9]+`, no `v` prefix — `release.yml` line 5 filter rejects anything else. CI overwrites `MARKETING_VERSION` to match the input version, so don't pre-bump it by hand.

## After a successful release

1. **GitHub Release**: https://github.com/ShuminFu/claude-island/releases/tag/$VERSION — DMG should be attached
2. **funfun-zone main**: should have a new `chore: update appcast.xml for Claude Island $VERSION` commit from `github-actions[bot]`
3. **CF Pages deploy**: `gh api repos/ShuminFu/funfun-zone/commits/main/check-runs --jq '.check_runs[0].conclusion'` should eventually be `success` (1–2 min build)
4. **Live appcast**: `curl -sS https://funfun.zone/appcast.xml` — should contain the new `<item>` with a GitHub `releases/download/$VERSION/` enclosure URL and a `sparkle:edSignature` attribute
5. **Local main**: CI pushed a version-bump commit — `git pull` before starting new work
6. **Install test** (optional, when making behavior changes to Sparkle): install the published DMG fresh, menu → Check for Updates — should show "up to date" cleanly (not "failed")

## End-to-end verification one-liner

After a release, run this to confirm every hop:

```bash
VERSION=1.8.0
echo "=== GitHub release ===" && gh release view $VERSION --json assets --jq '.assets[] | {name, size}'
echo "=== funfun-zone latest commit ===" && gh api repos/ShuminFu/funfun-zone/commits/main --jq '{sha: .sha[:12], message: .commit.message | split("\n")[0], author: .commit.author.name}'
echo "=== live appcast ===" && curl -sS https://funfun.zone/appcast.xml | grep -E 'shortVersion|enclosure url'
echo "=== DMG URL ===" && curl -sI -L "https://github.com/ShuminFu/claude-island/releases/download/$VERSION/ClaudeIsland-$VERSION.dmg" 2>&1 | grep -E '^(HTTP|content-length)' | tail -2
```

Expected: DMG asset present, funfun-zone has the bot commit, appcast contains the new version + GitHub URL, final DMG HTTP 200.

## Recovery: fixing a broken published appcast without re-releasing

If an already-shipped appcast has a wrong enclosure URL (or wrong pubDate, or any metadata error), **you don't need to cut a new release**. The EdDSA signature is over the DMG file bytes, not the XML. As long as the DMG at the new URL has identical bytes to the one that was signed, the signature stays valid.

Patch via GitHub Contents API directly on `funfun-zone` main:

```bash
gh api repos/ShuminFu/funfun-zone/contents/public/appcast.xml > /tmp/appcast.json
python3 << 'PY'
import json, base64
d = json.load(open('/tmp/appcast.json'))
body = base64.b64decode(d['content']).decode()
fixed = body.replace('https://funfun.zone/ClaudeIsland-', 'https://github.com/ShuminFu/claude-island/releases/download/VERSION/ClaudeIsland-')  # edit as needed
payload = {'message': 'fix: patch appcast X', 'content': base64.b64encode(fixed.encode()).decode(), 'sha': d['sha'], 'branch': 'main'}
json.dump(payload, open('/tmp/put.json', 'w'))
PY
gh api -X PUT repos/ShuminFu/funfun-zone/contents/public/appcast.xml --input /tmp/put.json
```

CF Pages redeploys the new content in ~1 minute. Verify with the one-liner above. Only use this for cosmetic/URL fixes — if the DMG itself is wrong (bad signature, corrupted bytes, etc.) you have to cut a new version.

## Local dry-run

Sanity-check the packaging pipeline without publishing anything:

```bash
./scripts/create-release.sh --skip-notarization --skip-github --skip-website --skip-sparkle
```

Produces `releases/ClaudeIsland-<project-version>.dmg` locally. Does not touch git, tags, GitHub, or funfun-zone. Useful when editing `build.sh` or `create-release.sh`. Note `--skip-sparkle` also skips `generate_appcast`, so this dry-run does **not** exercise the `--download-url-prefix` path — to verify that, drop `--skip-sparkle` and inspect `releases/appcast/appcast.xml` for a GitHub enclosure URL.
