# shellcheck shell=bash
# env-file.sh — can the scripts read .env? (Workforce issue 462 review, finding 2.) Sourced by bin/update.sh,
# bin/doctor.sh and bin/backup.sh BEFORE they read .env, which they do with `. ./.env`: a value with a space and no
# quotes (GATEWAY_TRUSTED_PROXIES=203.0.113.10/32 203.0.113.11/32) then runs its second word as a command, and under
# `set -e` the update, the health check and the nightly backup stop with a puzzling "No such file or directory".
# Docker Compose reads such a line without complaint, so nothing else would say so. No output of its own except
# what env_file_problem prints.

# env_file_problem [file] — why the scripts can't read that .env (default ./.env), in words naming the line and
# the setting (never its value: it may be a password); nothing when they can. Reads it twice: line by line for an unquoted value with a space, then as the
# scripts do, in a subshell of its own (nothing it sets reaches the caller).
env_file_problem() {
  local f="${1:-.env}" line n=0 name value err src
  [ -f "$f" ] || return 0
  case "$f" in */*) src="$f" ;; *) src="./$f" ;; esac   # never a file of that name found on PATH
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    name="${BASH_REMATCH[2]}"; value="${BASH_REMATCH[3]}"
    case "$value" in \'*|\"*) continue ;; esac
    # A space followed by anything but a comment: the rest would run as a command.
    if [[ "$value" =~ ^[^[:space:]]*[[:space:]]+[^#[:space:]] ]]; then
      echo "${f##*/} line ${n}: ${name}'s value has a space but no quotes, so the scripts can't read ${f##*/} (they'd run its second word as a command). Put the whole value in single quotes: ${name}='…'"
      return 0
    fi
  done < "$f"
  if ! err="$( (set -e; . "$src") 2>&1 >/dev/null)"; then
    # Only where, never bash's own words: they can quote a piece of a value, and a value can be a password.
    echo "${f##*/} can't be read as the scripts read it ($(printf '%s\n' "$err" | grep -oE 'line [0-9]+' | head -n 1 || true)): check its quotes there"
  fi
}
