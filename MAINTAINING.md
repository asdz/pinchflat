# About this fork

This is a fork of [kieraneglin/pinchflat](https://github.com/kieraneglin/pinchflat), whose
development is paused. It carries a small set of fixes on top of upstream and publishes its own
Docker image. See `git log upstream/master..master` for the full list.

## Changes from upstream

- **Members-only and private videos are skipped instead of retried forever.** Pinchflat now stores
  yt-dlp's `availability` for each video. Members-only videos are indexed but not downloaded
  unless the source's new **Download Members-Only Media** setting is on (turn it on once you've
  joined the channel and set up cookies). Private videos are always skipped. Videos that already
  failed with a members-only error are marked automatically when the database migrates.
- **Age-restricted videos are skipped unless the source uses cookies.** Without cookies they
  can never download, but they used to be retried on every index, holding up the download
  queue. They're marked `needs_auth` and picked up again as soon as the source's Cookie
  Behaviour is set to anything other than Disabled. Already-failed ones are marked on migration.
- **Fast indexing no longer re-requests unavailable videos on every run**, and YouTube's newer
  "Join this channel…" error wording is recognised.
- **Indexing and source-metadata jobs no longer crash on bad yt-dlp output** (upstream #899).
  Previously a crash could exhaust the job's retries and stop a source from ever re-indexing.

## Docker image

`ghcr.io/<owner>/pinchflat` with these tags:

| Tag            | Meaning                                                              |
| -------------- | -------------------------------------------------------------------- |
| `edge`         | Latest `master` that passed every check                              |
| `stable`       | Latest `v*` release tag that passed every check                      |
| `v<version>`   | A specific release, eg `v2026.10.18`                                 |
| `sha-<commit>` | Every build that passed tests; pin one of these to roll back exactly |

Switching from upstream's image is a one-line change of the `image:` in your compose file. The
database migrates automatically on first start; back up your `/config` folder first.

## How changes are checked

Every push runs the full upstream test suite plus linting (`lint_and_test.yml`). Pushes to
`master` and release tags then go through `build_and_release.yml`:

1. Secret scan (gitleaks) and the test suite
2. Build the image and push it as `sha-<commit>`
3. Boot it with `tooling/smoke_test.sh`: fresh install, upgrade from upstream's image (and from
   this fork's current `stable`), and rollback to the older image on the upgraded database
4. Only if all of that passes, tag it `edge` (or `stable` + `v*` for release tags)

`master` is also rebuilt weekly so `edge` picks up new yt-dlp, Deno and OS security updates.

To release: `git tag v2026.10.18 && git push origin v2026.10.18`.

## This repo is public

Never commit cookies (`cookies.txt`), API keys, notification URLs, passwords, compose/`.env`
files or databases. The secret scan fails the build if it finds something that looks like a
credential. If one is ever pushed, revoke or rotate it first, then remove it from the repo.

## yt-dlp

The image downloads the latest yt-dlp at build time, and Pinchflat runs `yt-dlp --update` on
every start and once a day, so yt-dlp stays current without a new image.

## Pulling in upstream changes

```sh
git remote add upstream https://github.com/kieraneglin/pinchflat.git
git fetch upstream
git merge upstream/master   # resolve conflicts, push a branch, let CI test it
```
