# Maintaining this fork

This is a personal fork of [kieraneglin/pinchflat](https://github.com/kieraneglin/pinchflat),
whose development is paused. It carries a few fixes on top (see `git log upstream/master..master`).

## Golden rule: this repo is public

Never commit cookies (`cookies.txt`), YouTube API keys, Apprise URLs, passwords, your
`docker-compose.yml`/`.env`, or the database. Those stay on the NAS only. CI runs a secret
scan (gitleaks) and fails the build if it finds something that looks like a credential.
If a secret is ever pushed, treat it as leaked: revoke/rotate it first, then remove it.

## How a change gets to the NAS

1. Make the change on a branch and push it. The full test suite (~1000 tests) runs automatically.
2. Merge to `master`. CI then:
   - scans for secrets and runs the test suite again,
   - builds the Docker image and pushes it as `ghcr.io/<you>/pinchflat:sha-<commit>`,
   - boots that image three ways (`tooling/smoke_test.sh`): fresh install, upgrade from
     upstream's image / our current `stable`, and rollback back to the old image,
   - only if all of that passes, tags it `edge`.
3. When happy with `edge`, release it by tagging: `git tag v2026.10.18 && git push --tags`.
   The same checks run and the image is tagged `stable` and `v2026.10.18`.
4. The NAS runs `ghcr.io/<you>/pinchflat:stable`. Update it with
   `sh pinchflat-update.sh update` (see below).

Master is also rebuilt weekly so `edge` picks up new yt-dlp, Deno and OS security updates.

## Updating and rolling back on the Synology

Copy `tooling/nas/pinchflat-update.sh` next to your `docker-compose.yml` and run it as root:

| Command                                   | What it does                                                                                                                                    |
| ----------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `sh pinchflat-update.sh update`           | Saves the current image, backs up the DB, pulls and starts the new image, and **rolls back automatically** if it isn't healthy within 5 minutes |
| `sh pinchflat-update.sh rollback`         | Previous image + the DB from just before the last update                                                                                        |
| `sh pinchflat-update.sh rollback-keep-db` | Previous image, keeps the current DB (keeps anything indexed since the update)                                                                  |
| `sh pinchflat-update.sh status`           | Running image, health, yt-dlp version, backups                                                                                                  |

DB backups go to `<your config folder>/db-backups/` (last 10 kept).

To pin an exact build instead of `stable`, set the compose image to a `sha-…` or `v…` tag.

## Pulling in upstream changes (if development resumes)

```sh
git remote add upstream https://github.com/kieraneglin/pinchflat.git
git fetch upstream
git merge upstream/master   # resolve conflicts, push to a branch, let CI test it
```

## yt-dlp

The image downloads the latest yt-dlp at build time, and Pinchflat runs `yt-dlp --update`
on every start and once a day, so yt-dlp stays current without a new image.
