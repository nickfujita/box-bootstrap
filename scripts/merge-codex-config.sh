#!/usr/bin/env bash
#
# merge-codex-config.sh — additively merge a portable Codex baseline into a
# live ~/.codex/config.toml.
#
#   merge-codex-config.sh --baseline <file> --target <file>   # merged TOML to stdout
#   merge-codex-config.sh --check --baseline <f> --target <f>  # list missing keys
#
# ADDITIVE ONLY. A key that already exists in the target — at the top level or
# inside the matching table — is left exactly as it is, comments and value
# untouched. Keys and tables the baseline does not mention are never read,
# reordered, or rewritten. That is what keeps the sections a managed provider
# owns (shell_environment_policy, hooks.state, projects, marketplaces, plugins)
# safe: the baseline never names them, so this script never touches them.
#
# --check exits 0 when the target already satisfies the baseline and 1 when one
# or more baseline keys are missing (the keys are printed, one per line).
#
# Only single-line `key = value` assignments are recognised. A value spanning
# several lines is treated as opaque text; in the worst case a continuation line
# is mistaken for an existing key, and the script then declines to add that key.
# The failure direction is always "add nothing", never "overwrite something".

set -euo pipefail

BASELINE=""
TARGET=""
CHECK_ONLY=0

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --baseline) BASELINE="${2:-}"; shift 2 ;;
    --target)   TARGET="${2:-}"; shift 2 ;;
    --check)    CHECK_ONLY=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) printf 'merge-codex-config.sh: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$BASELINE" ] || { printf 'merge-codex-config.sh: --baseline is required\n' >&2; exit 2; }
[ -n "$TARGET" ]   || { printf 'merge-codex-config.sh: --target is required\n' >&2; exit 2; }
[ -f "$BASELINE" ] || { printf 'merge-codex-config.sh: no such baseline: %s\n' "$BASELINE" >&2; exit 2; }

# An absent target is treated as an empty one: every baseline key is missing.
if [ ! -f "$TARGET" ]; then
  TARGET_INPUT="/dev/null"
else
  TARGET_INPUT="$TARGET"
fi

awk -v check_only="$CHECK_ONLY" '
function trim(s) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", s); return s }
function keyname(line,   k) { k = line; sub(/=.*/, "", k); return trim(k) }
function is_header(line) { return (trim(line) ~ /^\[/) }
function headname(line,   s) {
  s = trim(line); sub(/^\[+/, "", s); sub(/\]+$/, "", s); return s
}
function is_assign(line) { return (trim(line) ~ /^[^#[][^=]*=/) }

# ── Pass 1: the baseline ────────────────────────────────────────────────────
FNR == NR {
  line = $0
  if (trim(line) == "" || trim(line) ~ /^#/) { pending = pending line "\n"; next }
  if (is_header(line)) { bsec = headname(line); bheader[bsec] = line; pending = ""; next }
  if (is_assign(line)) {
    k = keyname(line)
    id = bsec SUBSEP k
    bblock[id] = pending line "\n"
    pending = ""
    if (bsec == "") { rootkey[++nroot] = k }
    else {
      if (!(bsec in seen_sec)) { seen_sec[bsec] = ++nsec; secname[nsec] = bsec }
      seckey[bsec, ++nseckey[bsec]] = k
    }
  }
  next
}

# ── Pass 2: the live target ─────────────────────────────────────────────────
{
  tline[++nt] = $0
  if (is_header($0)) {
    tsec = headname($0)
    tsec_start[tsec] = nt
    order[++nsec_t] = tsec
    if (nsec_t == 1) root_end = nt - 1
  } else if (is_assign($0)) {
    thas[tsec, keyname($0)] = 1
  }
  if (trim($0) != "") last_nonblank[tsec] = nt
}

END {
  if (nsec_t == 0) root_end = nt
  # Region end for each target table: the line before the next header.
  for (i = 1; i <= nsec_t; i++) {
    s = order[i]
    end = (i < nsec_t) ? tsec_start[order[i + 1]] - 1 : nt
    sec_end[s] = (s in last_nonblank) ? last_nonblank[s] : end
  }
  if (root_end < 0) root_end = 0
  root_insert = ("" in last_nonblank) ? last_nonblank[""] : root_end

  missing = 0

  # Root-level scalars.
  for (i = 1; i <= nroot; i++) {
    k = rootkey[i]
    if (!((SUBSEP k) in thas)) {
      missing++
      if (check_only) { print k; continue }
      add_root = add_root bblock[SUBSEP k]
    }
  }

  # Table keys.
  for (i = 1; i <= nsec; i++) {
    s = secname[i]
    if (!(s in tsec_start)) {
      # The whole table is absent: append it verbatim.
      for (j = 1; j <= nseckey[s]; j++) {
        missing++
        if (check_only) print s "." seckey[s, j]
      }
      if (!check_only) {
        block = bheader[s] "\n"
        for (j = 1; j <= nseckey[s]; j++) block = block bblock[s, seckey[s, j]]
        append_tail = append_tail "\n" block
      }
      continue
    }
    for (j = 1; j <= nseckey[s]; j++) {
      k = seckey[s, j]
      if (!((s SUBSEP k) in thas)) {
        missing++
        if (check_only) { print s "." k; continue }
        add_sec[s] = add_sec[s] bblock[s, k]
      }
    }
  }

  if (check_only) { exit (missing > 0 ? 1 : 0) }

  for (n = 1; n <= nt; n++) {
    print tline[n]
    if (n == root_insert && add_root != "") printf "%s", add_root
    for (i = 1; i <= nsec_t; i++) {
      s = order[i]
      if (n == sec_end[s] && (s in add_sec)) printf "%s", add_sec[s]
    }
  }
  if (nt == 0 && add_root != "") printf "%s", add_root
  if (append_tail != "") printf "%s", append_tail
}
' "$BASELINE" "$TARGET_INPUT"
