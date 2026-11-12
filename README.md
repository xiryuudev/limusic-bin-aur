# limusic-bin-prerelease for Arch Linux

Prerelease AUR package for [limusic](https://github.com/SimoHypers/limusic).
It follows the newest upstream release, rc or final: when a stable release ships,
this package moves to it too.

```sh
paru -S limusic-bin-prerelease
# or: yay -S limusic-bin-prerelease
```

Launch **limusic** from the applications menu, or run `limusic-app`.

Installing this removes `limusic-bin` (and vice versa) — both provide the same
application files.

Playback goes through libmpv, so a working audio stack is required, plus
`webkit2gtk-4.1`. YouTube Music login uses your own account.

## How updates work

Nothing is pushed to the AUR unless the whole pipeline passes.

```
watch-prerelease.yml        polls upstream, starts update-prerelease.yml
  └─ update-prerelease.yml  check → build → validate → publish
       ├─ check    newest upstream release (rc or final) vs packaged version
       ├─ build    AppImage extract + makepkg + namcap in an Arch container
       └─ publish  push to the AUR, then re-read the remote to verify
```

Upstream publishes **no `.deb` for prereleases** — only an AppImage — so this
channel packages the AppImage. The bundled libraries are dropped and the system
ones are used instead, keeping the package around 40 MB rather than 190 MB.

The workflows live on `main` because GitHub only runs `schedule` on the default
branch; they check out this branch for the package files.

## Layout

```
PKGBUILD                             AppImage-based recipe
.github/  (workflows live on main)    watch-prerelease.yml, update-prerelease.yml
scripts/check-update-prerelease.sh    newest release (rc or final) vs packaged
scripts/render-pkgbuild-prerelease.sh AppImage download, checksum, tag/pkgver mapping
scripts/ci-build-prerelease.sh        orchestrate render + validate
scripts/watch-prerelease.py           release polling
scripts/validate.sh                   makepkg + namcap gate
scripts/publish.sh                    push to the AUR, then verify
scripts/commit-state.sh               commit the new PKGBUILD back here
scripts/ci-setup.sh                   bootstrap the Arch container
scripts/as-builder.sh                 run as a non-root user (makepkg refuses root)
scripts/aur-host-keys.txt             pinned AUR host keys
```
