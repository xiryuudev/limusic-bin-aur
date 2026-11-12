#!/usr/bin/env bash
# Container bootstrap (runs as root inside the Arch container).
#
# Prepares everything makepkg and namcap need:
#   - a current keyring and a full upgrade (the rolling image is routinely behind
#     the mirrors; a partial upgrade would break pacman)
#   - namcap, git, curl, jq
#   - an unprivileged `builder` user, because makepkg refuses to run as root
#   - the package's own runtime dependencies, so namcap resolves sonames against
#     real packages instead of reporting them as unknown libraries
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

: "${GITHUB_WORKSPACE:=$(pwd)}"
export LC_ALL=C

# ---------------------------------------------------------------------------
# Tooling. git and openssh are NOT part of base-devel; the bootstrap step in the
# workflow normally installs them together with the sysupgrade, so this is a
# top-up that also covers a locally run container.
# ---------------------------------------------------------------------------
log "==> installing build tooling"
if ! pacman -S --noconfirm --needed --quiet \
  base-devel git openssh curl jq namcap pacman-contrib >/dev/null 2>&1; then
  # Stale sync database or outdated keyring: do a real sysupgrade and retry.
  warn "pacman -S failed; refreshing the keyring and doing a full upgrade"
  pacman -Sy --noconfirm --quiet archlinux-keyring >/dev/null 2>&1 || true
  pacman -Su --noconfirm --needed --quiet || die "could not upgrade the container"
  pacman -S --noconfirm --needed --quiet \
    base-devel git openssh curl jq namcap pacman-contrib >/dev/null \
    || die "could not install build tooling"
fi

# Fail early and clearly rather than halfway through a publish.
for tool in makepkg namcap git ssh curl jq setpriv bsdtar; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool missing after setup: ${tool}"
done
log "namcap: $(namcap --version 2>&1 | head -n1)"

# git refuses to operate on a workspace it considers foreign-owned.
git config --global --add safe.directory "$GITHUB_WORKSPACE" || true

# ---------------------------------------------------------------------------
# Unprivileged build user.
# ---------------------------------------------------------------------------
BUILD_USER="${BUILD_USER:-builder}"
if ! id -u "$BUILD_USER" >/dev/null 2>&1; then
  log "==> creating build user ${BUILD_USER}"
  useradd --create-home --shell /bin/bash "$BUILD_USER"
fi
install -d -o "$BUILD_USER" -g "$BUILD_USER" -m 0755 "/home/${BUILD_USER}"

# ---------------------------------------------------------------------------
# Runtime dependencies, so namcap can resolve every soname the binary needs.
# ---------------------------------------------------------------------------
deps_line=""
if [ -f "${GITHUB_WORKSPACE}/PKGBUILD" ]; then
  deps_line="$(sed -n 's/^depends=(\(.*\))$/\1/p' "${GITHUB_WORKSPACE}/PKGBUILD" | head -n1)"
fi

if [ -n "$deps_line" ]; then
  deps=()
  while IFS= read -r d; do
    if [ -n "$d" ]; then
      deps+=("$d")
    fi
  done < <(printf '%s' "$deps_line" | tr -d '"' | tr ' ' '\n' | sed '/^$/d')

  log "==> checking ${#deps[@]} declared runtime dependencies"
  missing="$(pacman -T "${deps[@]}" 2>/dev/null || true)"

  if [ -z "$missing" ]; then
    log "all declared dependencies already satisfied"
  else
    # Install the unmet specs *as written*. pacman resolves a soname provides to
    # the owning package itself (libmpv.so=2-64 -> mpv, libcrypto.so=3-64 ->
    # openssl-3), which is what namcap needs to verify the dependencies. Deriving
    # a package name by stripping ".so..." is wrong: it turns mpv into libmpv.
    specs=()
    while IFS= read -r spec; do
      if [ -n "$spec" ]; then
        specs+=("$spec")
      fi
    done <<<"$missing"

    if [ "${#specs[@]}" -eq 0 ]; then
      warn "could not parse the unmet dependencies; skipping"
    else
      log "installing: ${specs[*]}"
      install_failed=0
      for spec in "${specs[@]}"; do
        if ! pacman -S --noconfirm --needed --asdeps --quiet "$spec" >/dev/null 2>&1; then
          warn "could not install runtime dependency '${spec}'"
          install_failed=$((install_failed + 1))
        fi
      done
      if [ "$install_failed" -gt 0 ]; then
        warn "${install_failed} dependency package(s) unavailable; namcap may report unresolved libraries"
      fi
    fi
  fi
else
  warn "no depends= line found in PKGBUILD; skipping dependency install"
fi

log "container ready"
