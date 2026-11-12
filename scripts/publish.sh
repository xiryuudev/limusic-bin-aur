#!/usr/bin/env bash
# Publish the validated PKGBUILD/.SRCINFO to the AUR (branch master).
#
# Works on a throwaway clone of the AUR repo under $WORKDIR/aur, so the caller's
# checkout (which holds the workflows and scripts) is never modified.
#
# Requires:
#   AUR_SSH_PRIVATE_KEY  private key registered at aur.archlinux.org
#   AUR_USERNAME         AUR account name (commit identity)
#   AUR_EMAIL            commit email
#
# Guarantees:
#   - nothing is pushed when the AUR already carries this version + checksum
#   - the remote is re-read after the push and the published content verified
#
# Usage: publish.sh <version>
set -euo pipefail

REPO_ROOT="$(pwd)"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

: "${AUR_PKGNAME:=limusic-bin}"
: "${WORKDIR:=/tmp/aur-build}"
: "${DRY_RUN:=false}"

version="${1:-}"
[ -n "$version" ] || die "usage: publish.sh <version>"

require_cmd git ssh

# ---------------------------------------------------------------------------
# 0. Sanity-check the files we are about to publish.
# ---------------------------------------------------------------------------
[ -f "${REPO_ROOT}/PKGBUILD" ] || die "PKGBUILD missing"
[ -f "${REPO_ROOT}/.SRCINFO" ] || die ".SRCINFO missing"

local_pkgver="$(pkgbuild_var "${REPO_ROOT}/PKGBUILD" pkgver)"
local_sha="$(pkgbuild_var "${REPO_ROOT}/PKGBUILD" sha256sums)"
[ "$local_pkgver" = "$version" ] || die "PKGBUILD pkgver is '${local_pkgver}', expected '${version}'"
[ -n "$local_sha" ] || die "could not read sha256sums from PKGBUILD"

# .SRCINFO must agree with PKGBUILD, or the AUR page shows stale metadata.
srcinfo_pkgver="$(srcinfo_var "${REPO_ROOT}/.SRCINFO" pkgver)"
srcinfo_sha="$(srcinfo_var "${REPO_ROOT}/.SRCINFO" sha256sums)"
[ "$srcinfo_pkgver" = "$version" ] || die ".SRCINFO pkgver is '${srcinfo_pkgver}', expected '${version}'"
[ "$srcinfo_sha" = "$local_sha" ] || die ".SRCINFO sha256sums does not match PKGBUILD"
log "files consistent: pkgver=${version} sha256=${local_sha:0:16}..."

# ---------------------------------------------------------------------------
# 1. SSH material: private key + pinned host keys.
# ---------------------------------------------------------------------------
aur_remote="${AUR_REMOTE:-ssh://aur@aur.archlinux.org/${AUR_PKGNAME}.git}"

# Decide once whether this is the real AUR endpoint; both the identity check and
# the SSH-key setup below must agree, so SCP-style remotes cannot slip through.
is_real_aur=false
case "$aur_remote" in
  ssh://*aur.archlinux.org*|*@aur.archlinux.org:*) is_real_aur=true ;;
esac

# AUR attributes a push to the account owning the SSH key, and the commit author
# must match it or the package will not update. Both values are secrets.
git_name="${AUR_USERNAME:-}"
git_email="${AUR_EMAIL:-}"
if [ "$is_real_aur" = true ]; then
  [ -n "$git_name" ] || die "AUR_USERNAME is not set (required for the AUR commit author)"
  [ -n "$git_email" ] || die "AUR_EMAIL is not set (required for the AUR commit author)"
else
  # Rehearsing against a local repository: fall back to a placeholder identity.
  git_name="${git_name:-xiryuu}"
  git_email="${git_email:-farrel2008ganteng@protonmail.com}"
fi

# SSH material is only needed for a real SSH endpoint. AUR_REMOTE lets the
# pipeline be rehearsed against a throwaway local repository.
case "$aur_remote" in
  ssh://*|*@*:*)
    [ -n "${AUR_SSH_PRIVATE_KEY:-}" ] || die "AUR_SSH_PRIVATE_KEY is not set"

    mkdir -p "${WORKDIR}/ssh"
    chmod 700 "${WORKDIR}/ssh"
    known_hosts="${WORKDIR}/ssh/aur_known_hosts"
    cp "${SCRIPT_DIR}/aur-host-keys.txt" "$known_hosts"
    chmod 600 "$known_hosts"

    keyfile="${WORKDIR}/ssh/aur_key"
    umask 077
    # The secret may be pasted as real multi-line text or as one line with
    # literal \n escapes. %b expands the escapes and is a no-op for real
    # newlines, so one unconditional conversion handles both forms.
    printf '%b\n' "${AUR_SSH_PRIVATE_KEY//\\n/$'\n'}" >"$keyfile"
    chmod 600 "$keyfile"
    grep -q 'BEGIN .*PRIVATE KEY' "$keyfile" \
      || die "AUR_SSH_PRIVATE_KEY does not look like a PEM private key"
    command -v ssh-keygen >/dev/null 2>&1 \
      && ssh-keygen -y -f "$keyfile" >/dev/null 2>&1 \
      || warn "could not validate the SSH key locally (ssh-keygen unavailable or key encrypted)"

    export GIT_SSH_COMMAND="ssh -F /dev/null -i ${keyfile} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${known_hosts}"
    ;;
  *)
    warn "AUR_REMOTE is not an SSH endpoint (${aur_remote}); skipping SSH key setup"
    ;;
esac

# ---------------------------------------------------------------------------
# 2. Throwaway clone of the AUR repository.
# ---------------------------------------------------------------------------
aur_dir="${WORKDIR}/aur"
rm -rf "$aur_dir"
mkdir -p "$WORKDIR"

log "==> cloning ${aur_remote}"
if ! git clone --quiet "$aur_remote" "$aur_dir" 2>"${WORKDIR}/clone.err"; then
  cat "${WORKDIR}/clone.err" >&2 || true
  die "cannot clone the AUR repository (is the SSH key registered on the AUR account?)"
fi

cd "$aur_dir"
git config user.name "$git_name"
git config user.email "$git_email"

aur_pkgver="$(pkgbuild_var PKGBUILD pkgver 2>/dev/null || true)"
aur_sha="$(pkgbuild_var PKGBUILD sha256sums 2>/dev/null || true)"
log "AUR currently: pkgver=${aur_pkgver:-<none>} sha256=${aur_sha:0:16}..."

# Compare the whole PKGBUILD, not just pkgver+checksum: a dependency or install
# script fix for an unchanged upstream version must still reach the AUR.
if normalize_pkgbuild_file PKGBUILD >"${WORKDIR}/aur.PKGBUILD.norm" 2>/dev/null \
  && normalize_pkgbuild_file "${REPO_ROOT}/PKGBUILD" >"${WORKDIR}/local.PKGBUILD.norm"; then
  if diff -q "${WORKDIR}/aur.PKGBUILD.norm" "${WORKDIR}/local.PKGBUILD.norm" >/dev/null 2>&1; then
    log "AUR PKGBUILD is identical to the local one — nothing to push"
    set_output published false
    set_output push_reason "AUR already up to date"
    summary "### publish: skipped (AUR PKGBUILD already matches)"
    exit 0
  fi
  log "PKGBUILD differs from the AUR copy — a push is needed"
  diff -u "${WORKDIR}/aur.PKGBUILD.norm" "${WORKDIR}/local.PKGBUILD.norm" >&2 || true
else
  # Fall back to the version+checksum heuristic if either file is unreadable.
  if [ "$aur_pkgver" = "$version" ] && [ "$aur_sha" = "$local_sha" ]; then
    log "AUR already carries ${version} with the same checksum — nothing to push"
    set_output published false
    set_output push_reason "AUR already up to date"
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# 3. Stage the new files and commit.
# ---------------------------------------------------------------------------
cp -f "${REPO_ROOT}/PKGBUILD" PKGBUILD
cp -f "${REPO_ROOT}/.SRCINFO" .SRCINFO

# An AUR repo holds exactly these two files; report anything else but leave it.
extra="$(git status --porcelain | awk '{print $NF}' | grep -vE '^(PKGBUILD|\.SRCINFO)$' || true)"
if [ -n "$extra" ]; then
  warn "extra paths present in the AUR repo (left untouched): $(printf '%s' "$extra" | tr '\n' ' ')"
fi

git add -- PKGBUILD .SRCINFO
if git diff --cached --quiet; then
  log "staged content identical to AUR HEAD — nothing to push"
  set_output published false
  set_output push_reason "no change staged"
  exit 0
fi

if [ "$aur_pkgver" != "$version" ]; then
  commit_msg="upgpkg: ${AUR_PKGNAME} ${version}"
elif [ "$aur_sha" != "$local_sha" ]; then
  commit_msg="upgpkg: ${AUR_PKGNAME} ${version} (checksum refresh)"
else
  # Same version and same payload, but the recipe itself changed (dependencies,
  # prepare()/package(), options...). AUR convention keeps the version in the
  # subject; the pkgrel bump already makes pacman rebuild for users.
  commit_msg="upgpkg: ${AUR_PKGNAME} ${version} (PKGBUILD refresh)"
fi

git commit --quiet -m "$commit_msg" --author="${git_name} <${git_email}>"
commit_sha="$(git rev-parse HEAD)"
log "commit ${commit_sha:0:8}: ${commit_msg}"

summary "### changes submitted to AUR"
summary '```diff'
summary "$(git show --format= --unified=2 HEAD -- PKGBUILD | head -40)"
summary '```'

# ---------------------------------------------------------------------------
# 4. Push.
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = true ]; then
  log "DRY_RUN=true — commit created locally but not pushed"
  set_output published false
  set_output push_reason "dry run"
  exit 0
fi

log "==> pushing to AUR"
if ! git push --quiet origin HEAD:master 2>"${WORKDIR}/push.err"; then
  cat "${WORKDIR}/push.err" >&2 || true
  die "AUR push rejected (stale key, rate limit, or a conflicting update?)"
fi

# ---------------------------------------------------------------------------
# 5. Verify what actually landed.
# ---------------------------------------------------------------------------
git fetch --quiet origin master 2>/dev/null || die "push reported success but re-fetch failed"
remote_sha="$(git rev-parse origin/master)"
[ "$remote_sha" = "$commit_sha" ] || die "AUR master is ${remote_sha:0:8}, expected ${commit_sha:0:8}"

git show "${remote_sha}:PKGBUILD" >"${WORKDIR}/aur-remote-PKGBUILD"
remote_pkgver="$(pkgbuild_var "${WORKDIR}/aur-remote-PKGBUILD" pkgver)"
remote_sha_sum="$(pkgbuild_var "${WORKDIR}/aur-remote-PKGBUILD" sha256sums)"
[ "$remote_pkgver" = "$version" ] || die "AUR PKGBUILD has pkgver '${remote_pkgver}', expected '${version}'"
[ "$remote_sha_sum" = "$local_sha" ] || die "AUR checksum '${remote_sha_sum}' != validated '${local_sha}'"

log "AUR verified: ${remote_sha:0:8} pkgver=${remote_pkgver} sha256=${remote_sha_sum:0:16}..."

set_output published true
set_output commit_sha "$commit_sha"
set_output commit_message "$commit_msg"
set_output push_reason "published"

summary "### publish: ok"
summary ""
summary "- AUR commit \`${remote_sha:0:8}\` — ${commit_msg}"
summary "- verified on the remote: pkgver \`${remote_pkgver}\`, sha256 \`${remote_sha_sum:0:16}…\`"
