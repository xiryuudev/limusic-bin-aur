#!/usr/bin/env bash
# Run a command as the unprivileged build user.
#
# makepkg refuses to run as root, but GitHub Actions container jobs run as root.
# This wrapper copies the working tree into a directory owned by the build user,
# runs the command there, then copies PKGBUILD/.SRCINFO back so the following
# steps (publish) see the freshly rendered files.
#
# Outside Actions, or when already unprivileged, it simply executes the command.
#
# Usage: SRC_DIR=/path/to/repo as-builder.sh ./scripts/ci-build.sh <args...>
set -euo pipefail

BUILD_USER="${BUILD_USER:-builder}"
BUILD_HOME_ROOT="${BUILD_HOME_ROOT:-/home/${BUILD_USER}}"
BUILD_HOME="${BUILD_HOME:-${BUILD_HOME_ROOT}/work}"
SRC_DIR="${SRC_DIR:-$(pwd)}"

if [ "$#" -eq 0 ]; then
  echo "usage: as-builder.sh <command> [args...]" >&2
  exit 2
fi

# Already unprivileged: nothing to drop.
if [ "$(id -u)" -ne 0 ]; then
  exec "$@"
fi

command -v setpriv >/dev/null 2>&1 || { echo "setpriv is not available" >&2; exit 1; }
id -u "$BUILD_USER" >/dev/null 2>&1 || { echo "user ${BUILD_USER} does not exist" >&2; exit 1; }

# Fresh copy of the checkout, without VCS metadata or stale build output.
rm -rf "$BUILD_HOME"
install -d -o "$BUILD_USER" -g "$BUILD_USER" -m 0755 "$BUILD_HOME"
cp -a "$SRC_DIR/." "$BUILD_HOME/"
rm -rf "${BUILD_HOME}/.git" "${BUILD_HOME}/.aur-build"
chown -R "$BUILD_USER:$BUILD_USER" "$BUILD_HOME"

uid="$(id -u "$BUILD_USER")"
gid="$(id -g "$BUILD_USER")"

build_output="${BUILD_HOME}/.gh_output"
build_summary="${BUILD_HOME}/.gh_summary"
: >"$build_output"
: >"$build_summary"
chown "$BUILD_USER:$BUILD_USER" "$build_output" "$build_summary"

restore() {
  local rc=$?
  # Only hand files back when the command succeeded: a failed run must not leave
  # a half-rendered PKGBUILD behind.
  if [ "$rc" -eq 0 ]; then
    if [ -f "${BUILD_HOME}/PKGBUILD" ]; then
      cp -f "${BUILD_HOME}/PKGBUILD" "${SRC_DIR}/PKGBUILD" || true
    fi
    if [ -f "${BUILD_HOME}/.SRCINFO" ]; then
      cp -f "${BUILD_HOME}/.SRCINFO" "${SRC_DIR}/.SRCINFO" || true
    fi
  fi
  if [ -s "$build_output" ]; then
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
      cat "$build_output" >>"$GITHUB_OUTPUT" || true
    else
      cat "$build_output" || true
    fi
  fi
  if [ -s "$build_summary" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$build_summary" >>"$GITHUB_STEP_SUMMARY" || true
  fi
  exit "$rc"
}
trap restore EXIT

cmd=""
for arg in "$@"; do
  cmd+=" $(printf '%q' "$arg")"
done

# setpriv preserves the environment (unlike su/runuser), so WORKDIR /
# EXPECTED_DIGEST and friends reach the script unchanged.
setpriv --reuid "$uid" --regid "$gid" --init-groups \
  env HOME="$BUILD_HOME_ROOT" \
  GITHUB_OUTPUT="$build_output" \
  GITHUB_STEP_SUMMARY="$build_summary" \
  WORKDIR_OVERRIDE="${BUILD_HOME}/.aur-build" \
  bash -c "cd $(printf '%q' "$BUILD_HOME") && exec${cmd}"
