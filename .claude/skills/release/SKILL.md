---
name: release
description: Cut a new Claude Island release (tag → GitHub Actions → DMG → website appcast). Use when the user asks to "release", "publish", "ship", "tag", or "cut version X.Y.Z". Covers the fork-Actions trap that silently skips tag triggers on ShuminFu/claude-island, how to trigger manually via workflow_dispatch, and how to monitor the run.
---

# Releasing Claude Island

The release pipeline is fully automated via `.github/workflows/release.yml`. You don't build DMGs locally — CI does it. Your job is to pick the version, trigger the workflow, and watch it.

## TL;DR happy path

```bash
VERSION=1.8.0
gh workflow run release.yml --ref main -f version=$VERSION
gh run watch $(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
```

That's it. `workflow_dispatch` is the reliable path on this fork (see "Fork trap" below). The workflow:

1. Bumps `MARKETING_VERSION` in `ClaudeIsland.xcodeproj/project.pbxproj` and commits `chore: bump version to X.Y.Z [skip ci]` back to main
2. Builds ad-hoc-signed `.app` via `scripts/build.sh`
3. Creates DMG via `scripts/create-release.sh`, signs with Sparkle EdDSA key (if `SPARKLE_PRIVATE_KEY` secret present)
4. Creates GitHub Release with generated notes, uploads DMG
5. Scans DMG with VirusTotal, appends results to release body
6. Dispatches `update-appcast` event to `ShuminFu/claude-island-web` (if Sparkle signature present)

## Fork trap — the #1 reason releases "don't happen"

**`ShuminFu/claude-island` is a fork of `farouqaldori/claude-island`.** GitHub disables automatic workflow triggers (`push`, `tag`) on forks by default, even when `gh api repos/:owner/:repo/actions/permissions` reports `enabled: true`. Symptom: you `git push origin 1.7.0`, the tag appears on GitHub, but **no workflow run is created**. The event never fires.

Diagnose:

```bash
# Tag exists on remote?
gh api repos/:owner/:repo/git/refs/tags --jq '.[] | .ref'

# Any runs for this repo at all?
gh run list --limit 10

# Events (push/create) actually received by GitHub?
gh api repos/:owner/:repo/events --jq '.[] | {type, created_at, ref: .payload.ref}' | head
```

If tag is on the remote but no run exists and no `CreateEvent` for the tag in events → fork trap.

**Two fixes:**

1. **One-time fix**: open https://github.com/ShuminFu/claude-island/actions and click "I understand my workflows, go ahead and enable them" on the yellow banner. Afterwards, `git push origin <tag>` will trigger `release.yml` normally.
2. **Workaround**: use `workflow_dispatch` (takes a `version` input), which works on forks without the banner dance. This is the TL;DR path above.

## Choosing the next version

```bash
# Highest existing tag
gh api repos/:owner/:repo/git/refs/tags --jq '.[].ref' | sed 's|refs/tags/||' | sort -V | tail -5
```

Semver. Breaking changes → major, features → minor, fixes → patch. `MARKETING_VERSION` in `project.pbxproj` is the source of truth locally but CI overwrites it to match the release version, so don't bother bumping it by hand before releasing.

The tag format is strict: `[0-9]+.[0-9]+.[0-9]+` (no `v` prefix). `release.yml` line 5 filter rejects anything else.

## Triggering via tag push (after fork fix)

```bash
VERSION=1.8.0
git tag $VERSION
git push origin $VERSION
```

If you need to re-push a tag (because the first attempt didn't trigger due to the fork trap), delete it first on both sides:

```bash
git push origin :refs/tags/$VERSION   # delete remote
git tag -d $VERSION                    # delete local
git tag $VERSION && git push origin $VERSION
```

Note: re-pushing a tag won't re-trigger the workflow if a run already exists for that tag. Bump to the next patch if you need a re-cut.

## Watching the run

```bash
# List
gh run list --workflow=release.yml --limit 5

# Live watch the latest
gh run watch $(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')

# Logs for a failed run
gh run view <run-id> --log-failed
```

The `virustotal-scan` job runs on `ubuntu-latest` and needs the `build` job's DMG artifact. `update-website` only runs if `SPARKLE_PRIVATE_KEY` is configured AND signing produced a signature — missing either, the website appcast is not dispatched (the release still succeeds).

## Secrets the workflow depends on

| Secret | Used by | What happens if missing |
|---|---|---|
| `SPARKLE_PRIVATE_KEY` | `build` job | DMG still built, but no EdDSA signature → Sparkle auto-update won't verify, website dispatch skipped |
| `VT_API_KEY` | `virustotal-scan` | VirusTotal job fails (release still published) |
| `WEBSITE_PAT` | `update-website` | `repository-dispatch` step fails (release still published but website doesn't update) |

Check which are set: `gh secret list`.

## After a successful release

1. Verify release page: https://github.com/ShuminFu/claude-island/releases/tag/$VERSION
2. Sparkle appcast updates via the website repo — check https://github.com/ShuminFu/claude-island-web actions for the dispatched `update-appcast` workflow
3. CI pushes a `chore: bump version` commit back to main — `git pull` locally before starting new work so your working tree matches
4. `MARKETING_VERSION` in `project.pbxproj` should now equal the released version

## Local dry-run (optional)

To sanity-check the packaging pipeline without publishing anything:

```bash
./scripts/create-release.sh --skip-notarization --skip-github --skip-website --skip-sparkle
```

Produces `releases/ClaudeIsland-<project-version>.dmg` locally. Does not touch git, tags, or GitHub. Useful when you've touched `build.sh` or `create-release.sh` and want to verify them before trusting CI with a real tag.
