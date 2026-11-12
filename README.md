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
