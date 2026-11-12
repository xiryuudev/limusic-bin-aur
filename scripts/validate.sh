#!/usr/bin/env bash
# Build the package and gate the result with namcap before anything is pushed.
#
# Blocks (exit 1) on:
#   - makepkg failure, or no artifact produced
#   - a package that does not ship usr/bin/limusic-app
#   - .SRCINFO not matching `makepkg --printsrcinfo`
#   - any namcap "E:" (error) finding on PKGBUILD or on the built package
# "W:" (warning) findings are reported and do not block.
#
# Usage: validate.sh [--skip-build]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

: "${WORKDIR:=/tmp/aur-build}"
: "${AUR_PKGNAME:=limusic-bin}"

skip_build=false
[ "${1:-}" = "--skip-build" ] && skip_build=true

[ -f PKGBUILD ] || die "PKGBUILD not found in $(pwd)"
mkdir -p "$WORKDIR"

# ---------------------------------------------------------------------------
# 1. .SRCINFO must be exactly what makepkg generates from PKGBUILD.
# ---------------------------------------------------------------------------
require_cmd makepkg
makepkg --printsrcinfo >"${WORKDIR}/SRCINFO.expected" 2>/dev/null \
  || die "makepkg --printsrcinfo failed"
if ! diff -q "${WORKDIR}/SRCINFO.expected" .SRCINFO >/dev/null 2>&1; then
  log "--- .SRCINFO differs from makepkg --printsrcinfo ---"
  diff -u .SRCINFO "${WORKDIR}/SRCINFO.expected" >&2 || true
  die ".SRCINFO is not in sync with PKGBUILD"
fi
log "==> .SRCINFO matches PKGBUILD"

# ---------------------------------------------------------------------------
# 2. Build.
# ---------------------------------------------------------------------------
pkgfile=""
mkdir -p "${WORKDIR}/pkgdest"
if [ "$skip_build" = false ]; then
  mkdir -p "${WORKDIR}/srcdest"
  rm -f "${WORKDIR}/pkgdest/"*.pkg.tar.* 2>/dev/null || true

  log "==> makepkg"
  build_log="${WORKDIR}/makepkg.log"
  if ! SRCDEST="${WORKDIR}/srcdest" PKGDEST="${WORKDIR}/pkgdest" \
    makepkg --force --nodeps --noconfirm --cleanbuild >"$build_log" 2>&1; then
    tail -n 40 "$build_log" >&2 || true
    die "makepkg failed (full log above)"
  fi
  tail -n 3 "$build_log" >&2 || true
else
  log "==> skipping build (--skip-build)"
fi

# An artifact may already be present when the build was skipped (local testing).
pkgfile="$(find "${WORKDIR}/pkgdest" -maxdepth 1 -name "${AUR_PKGNAME}-*.pkg.tar.*" -type f | sort | tail -n1)"

if [ "$skip_build" = false ]; then
  [ -n "$pkgfile" ] || die "no package artifact produced in ${WORKDIR}/pkgdest"
  log "artifact: $(basename "$pkgfile") ($(stat -c %s "$pkgfile") bytes)"

  # Structural sanity check: the .deb must have unpacked into a real tree.
  # The listing is captured first: piping a huge listing into `grep -q` makes
  # bsdtar die of SIGPIPE, which pipefail would report as a failure.
  require_cmd bsdtar
  if ! bsdtar -tf "$pkgfile" >"${WORKDIR}/filelist.txt" 2>"${WORKDIR}/filelist.err"; then
    cat "${WORKDIR}/filelist.err" >&2 || true
    die "cannot read the built package"
  fi
  if ! grep -qx 'usr/bin/limusic-app' "${WORKDIR}/filelist.txt"; then
    head -n 50 "${WORKDIR}/filelist.txt" >&2 || true
    die "package does not ship usr/bin/limusic-app — upstream layout changed?"
  fi
  log "package ships usr/bin/limusic-app"
elif [ -n "$pkgfile" ]; then
  log "==> reusing existing artifact: $(basename "$pkgfile")"
fi

# ---------------------------------------------------------------------------
# 4. namcap on PKGBUILD and on the built package.
# ---------------------------------------------------------------------------
require_cmd namcap

# namcap exits 0 even when it finds problems and even when it fails to read the
# target, so its output must be inspected rather than its exit status.
run_namcap() { # target
  local target="$1" out
  out="$(namcap "$target" 2>&1)" || true
  if printf '%s\n' "$out" | grep -qE '^Error: '; then
    printf '%s\n' "$out" >&2
    die "namcap could not analyse ${target}"
  fi
  printf '%s\n' "$out"
}

log "==> namcap PKGBUILD"
pkgbuild_findings="$(run_namcap PKGBUILD)"

pkg_findings=""
if [ -n "$pkgfile" ]; then
  log "==> namcap $(basename "$pkgfile")"
  pkg_findings="$(run_namcap "$pkgfile")"
fi

all_findings="$(printf '%s\n%s\n' "$pkgbuild_findings" "$pkg_findings")"
errors="$(printf '%s\n' "$all_findings" | grep -E '(^|[[:space:]])E: ' || true)"
warnings="$(printf '%s\n' "$all_findings" | grep -E '(^|[[:space:]])W: ' || true)"

if [ -n "$warnings" ]; then
  log ""
  log "namcap warnings (non-blocking):"
  printf '%s\n' "$warnings" >&2
fi

if [ -n "$errors" ]; then
  log ""
  log "namcap errors (BLOCKING):"
  printf '%s\n' "$errors" >&2
  summary "### namcap: blocking errors ❌"
  summary '```'
  summary "$errors"
  summary '```'
  die "namcap reported errors — refusing to publish"
fi

# Also record the clean namcap output so the run log shows what was checked.
printf '%s\n%s\n' "$pkgbuild_findings" "$pkg_findings" | sed '/^$/d' >"${WORKDIR}/namcap.log" || true
log "namcap: no errors"

warn_count="$(printf '%s\n' "$warnings" | grep -c . || true)"
summary "### validation"
summary ""
if [ "$skip_build" = false ]; then
  summary "- build: ok — \`$(basename "$pkgfile")\` ($(numfmt --to=iec "$(stat -c %s "$pkgfile")" 2>/dev/null || stat -c %s "$pkgfile"))"
else
  summary "- build: skipped"
fi
summary "- .SRCINFO: in sync with PKGBUILD"
summary "- namcap errors: none"
summary "- namcap warnings: ${warn_count}"
if [ -n "$warnings" ]; then
  summary '```'
  summary "$warnings"
  summary '```'
fi

set_output validated true
