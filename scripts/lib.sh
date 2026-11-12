#!/usr/bin/env bash
# Shared helpers for the limusic-bin AUR automation.
# Sourced, never executed directly.

log() { printf '%s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Write a GitHub Actions output (no-op outside Actions).
set_output() {
  local key="$1" value="$2"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >>"$GITHUB_OUTPUT"
  fi
  log "  $key=$value"
}

# Append markdown to the job summary when running in Actions.
summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  fi
}

# Print a GitHub annotation when running in Actions.
annotate() { # level message
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::%s::%s\n' "$1" "$2"
  fi
  log "$1: $2"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

# Strip surrounding single or double quotes.
unquote() {
  local v="$1"
  v="${v#[\"\']}"
  v="${v%[\"\']}"
  printf '%s' "$v"
}

# Read a PKGBUILD/.SRCINFO scalar without spawning a pipeline. Reading a file
# (rather than piping) means `exit` inside awk cannot cause a SIGPIPE that
# `pipefail` would turn into a spurious failure.
#
#   pkgbuild_var PKGBUILD pkgver     -> 1.3.0
#   pkgbuild_var PKGBUILD sha256sums -> e39385...   (quotes/brackets stripped)
#   srcinfo_var  .SRCINFO pkgver     -> 1.3.0
pkgbuild_var() { # file name
  awk -v key="$2" '
    index($0, key "=") == 1 {
      v = substr($0, length(key) + 2)
      gsub(/^[ \t]*[(]+[ \t]*/, "", v)     # array opener
      gsub(/[ \t]*[)]+[ \t]*$/, "", v)     # array closer
      gsub(/^[ \t"'"'"']+|[ \t"'"'"']+$/, "", v)
      print v
      exit
    }
  ' "$1"
}

srcinfo_var() { # file name
  awk -v key="$2" '$1 == key && $2 == "=" { print $3; exit }' "$1"
}

# Print a PKGBUILD in a canonical form for comparison: trailing whitespace
# removed, runs of blank lines collapsed. Comments are kept, because the
# Maintainer line and short notes are real content a maintainer changes on
# purpose; the comparison is a plain diff, so cosmetic churn converges after the
# first push instead of looping.
normalize_pkgbuild_file() { # file
  sed -E 's/[[:space:]]+$//' "$1" 2>/dev/null | awk 'BEGIN{blank=0} /^$/{blank++; if(blank>1) next} !/^$/{blank=0} {print}'
}
