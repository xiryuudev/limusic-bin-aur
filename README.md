# limusic for Arch Linux

Community AUR package for [limusic](https://github.com/SimoHypers/limusic), a
native YouTube Music client built with Tauri, Rust and SvelteKit.

```sh
paru -S limusic-bin
# or: yay -S limusic-bin
```

Launch **limusic** from the applications menu, or run `limusic-app`.

Playback goes through libmpv, so a working audio stack is required, plus
`webkit2gtk-4.1`. YouTube Music login uses your own account.

## How updates work

Nothing is pushed to the AUR unless the whole pipeline passes.

```
watch.yml        polls upstream every minute for ~6 hours, then chains a new watch
  └─ update.yml  started as soon as a release appears
       ├─ check    compare upstream vs PKGBUILD vs AUR (no container)
       ├─ build    makepkg + namcap in an Arch container; namcap errors block
       └─ publish  push to the AUR, then re-read the remote to verify
```

`watch.yml` is what makes this timely. GitHub's cron schedule routinely fires
hours late and on some repositories never fires at all, so the watch polls
upstream itself and starts `update.yml` about a minute after a release.

## One-time setup

Add these under **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `AUR_SSH_PRIVATE_KEY` | SSH private key registered on your AUR account (no passphrase) |
| `AUR_USERNAME` | your AUR account name |
| `AUR_EMAIL` | your AUR account email — the commit author must match |

All three are required. If the commit author does not match the AUR account, the
push succeeds but the package does not update.

A bad key is rejected with a clear message, and the fingerprint of the key
actually used is printed in the log so you can compare it with the one on your
AUR account.

## Running locally

Needs Arch (or a derivative) with `base-devel`, `namcap` and `jq`.

```sh
./scripts/check-update.sh        # report versions only, changes nothing
./scripts/local-test.sh          # build + namcap for the current PKGBUILD
./scripts/local-test.sh 1.4.0    # force version 1.4.0 (rewrites PKGBUILD)
```

## Layout

```
.github/workflows/watch.yml     release polling, starts update.yml
.github/workflows/update.yml    check → build → validate → publish
scripts/watch.py                polling logic
scripts/check-update.sh         version, checksum and stale-recipe detection
scripts/render-pkgbuild.sh      download .deb, verify sha256, write PKGBUILD/.SRCINFO
scripts/validate.sh             makepkg + namcap gate
scripts/publish.sh              push to the AUR, then verify
scripts/commit-state.sh         commit the new PKGBUILD back to main
scripts/ci-setup.sh             bootstrap the Arch container
scripts/ci-build.sh             orchestrate render + validate
scripts/as-builder.sh           run as a non-root user (makepkg refuses root)
scripts/aur-host-keys.txt       pinned AUR host keys
```

## Notes

- namcap **E:** findings block the push; **W:** findings are only logged.
- `pkgrel` is bumped when upstream re-uploads a file for the same version, so
  users actually rebuild.
- AUR host keys are pinned; if AUR rotates them the push fails and
  `scripts/aur-host-keys.txt` must be updated.
- `keepalive.yml` writes `.github/heartbeat` on the 1st of each month so GitHub
  does not disable the schedule after 60 days without activity.
