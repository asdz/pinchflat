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
- **The daily retention job no longer crashes the app on large libraries.** It used to scan every
  downloaded video in one query; on a big library on NAS disks that took longer than the 15s
  database timeout, and the timed-out query took the whole app down with it (a restart every
  day at 01:00 UTC). It now only checks sources that have a retention period or cutoff date, one
  at a time. The database timeout is also raised to 60s, adjustable with `DATABASE_TIMEOUT_MS`.
- **A slow database query can no longer take the app down.** When a query ran past its timeout,
  the SQLite driver (exqlite 0.31) closed the connection but left the query running on it. When
  the query finished it could touch the closed connection and crash the whole Erlang VM, with
  nothing in the log; Docker then restarted the container. The driver is updated to a version
  that cancels the query instead, so a timeout only fails that one query (jobs retry, pages can
  be reloaded). The smoke test reproduces this: upstream's image dies on its slow query check
  (`SLOW_QUERY_COMPARE=1 tooling/smoke_test.sh <image>` shows it), this fork's image passes.
- **Large libraries put far less load on the database.** A video's row is big (it holds the
  description), and several queries that run constantly were reading every row: the "what's
  pending for this source?" check after each index, queueing downloads, the daily
  quality-upgrade job and the home page totals. They now read only the rows they need, mostly
  straight from small indexes, and download jobs are queued by ID instead of loading whole rows.
  The first start after updating builds those indexes, which can take a minute or two on a big
  library.
- **Long non-English titles no longer fail to download.** A file name can be at most 255 bytes,
  and Chinese/Japanese/emoji characters take 3-4 bytes each, so a long title plus `.info.json` or
  `.webp` went over and the download failed ("File name too long", "Cannot write video
  metadata"). `{{ title }}` in output templates is now capped at 170 bytes, which never shortens a
  title in plain English letters. Write `%(title)s` instead to keep the old, uncapped behaviour.
- **Downloads that can't succeed yet aren't retried 20 times in a row**: premieres and live
  events that haven't started, and file-name errors. The next index tries them again.
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
   this fork's current `stable`), rollback to the older image on the upgraded database, and a
   batch of database queries that outlive their timeout (each has to be cancelled, and the app
   has to survive them)
4. Only if all of that passes, tag it `edge` (or `stable` + `v*` for release tags)

`master` is also rebuilt weekly so `edge` picks up new yt-dlp, Deno and OS security updates.

To release: `git tag v2026.10.18 && git push origin v2026.10.18`.

## Updating a dependency

Elixir packages are pinned in `mix.lock`. To update one without installing Elixir, run the
**Preview a dependency update** workflow from the Actions tab (or
`gh workflow run update_dependency.yml -f packages="exqlite"`). It changes nothing itself: the
run's summary page shows the resulting `mix.lock` diff. Apply that diff, push it, and the
update goes through the same tests and smoke test as any other change.

Hex also lists known security advisories for the locked packages in that workflow's log.

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
