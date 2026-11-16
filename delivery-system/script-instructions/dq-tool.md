# The coordination tool

`tools/dq`: claims, heartbeats, takeover, leases, look-around, the board,
evidence, install and hooks. Every session calls it.

Each `## <path>` section below is one script. The path is relative to the
directory this file's parent folder sits in (delivery-system/). The script is not kept in
git as a file: it is generated locally from the code block, and the generated
file is ignored. See "Generating the scripts" in README.txt.

## tools/dq

````bash
#!/usr/bin/env bash
# dq - delivery queue tool for the proof-driven delivery system.
#
# Coordinates many agent sessions through one git repository (the queue).
# Read manual/COORDINATE.txt for when to use each command.
#
# Needs: bash 4+, git 2.20+, coreutils, awk, sed, tar.
# Optional: python3 (JSON work: proof checks, hooks, settings merge).
#
# How the locking works: every write to the queue is a plain push of a
# commit built on the remote tip. The server's ordinary refusal of a
# non-fast-forward push is the lock, so two sessions can never both win.
# Nothing is ever force-pushed or deleted. The one exception is the
# deliberate test in "protect-check", on a throwaway branch.

set -euo pipefail

DQ_VERSION="0.3.1"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_DIR="$(cd "$SELF_DIR/.." && pwd)"
ENVFILE="${DQ_ENVIRONMENT:-$SYSTEM_DIR/environment.yaml}"
TMPERR="$(mktemp)"
IDX=""
cleanup() { rm -f "$TMPERR"; if [ -n "$IDX" ]; then rm -f "$IDX"; fi; }
trap cleanup EXIT

STATES="Draft Ready Claimed Local-proven Track-proven UAT-proven Live Confirmed Regressed Satisfied Cancelled Decomposed"
HOLDS="none parked waiting-track waiting-results waiting-approval waiting-answer challenge"
CLOSED_STATES="Regressed Satisfied Cancelled Decomposed"   # no longer open work; kept as a record
CARD_SCOPE_KEYS="kind epic remit tier repos services flows depends_on blocks"
BOARD_FIELDS="kind state hold engineer active_session active_machine heartbeat_at claimed_at remit epic repos services flows depends_on blocks proofs_flag hold_since tier"
BOARD_HEADER="$(printf 'key\tkind\tstate\thold\tengineer\tsession\tmachine\theartbeat_at\tclaimed_at\tremit\tepic\trepos\tservices\tflows\tdepends_on\tblocks\tflag\thold_since\ttier')"

usage() {
  cat <<'EOF'
dq - delivery queue tool (details: manual/COORDINATE.txt)

Look before you work
  dq look [--near KEY] [--prefix P] [--all] [--quiet] [--to NAME]
                                  who holds what, who is near, open questions
  dq whois KEY                    one item's card, and whether you may take it
  dq show KEY [FILE]              read a file of any item; no FILE lists them
  dq done-check KEY [REPO...]     mechanical checks for "already done?"
  dq overlap KEY REPO [KEY...]    files this item and other items both change
  dq inbox [--to NAME]            open questions addressed to you
  dq configs [ENGINEER/MACHINE]   configs other engineers published

Hold an item
  dq claim KEY [--kind K] [--epic E] [--remit R] [--reopen]
                                  claim first; prints SESSION and ITEM_DIR
  dq take KEY [--from ENG --reason "..."] [--replace-mine "..."]
                                  become the active session (resume, hand over)
  dq beat KEY -s SESSION [--state S] [--hold H --reason "..."]
            [--set field=value ...] [-m "message"]
                                  save item files, heartbeat, push
  dq push KEY -s SESSION          push the item's code branches, then beat
  dq release KEY -s SESSION [--hold H --reason "..."]
                                  final save; give up the active session
  dq state KEY -s SESSION STATE [--by NAME] [--no-run]
                                  move state; refuses without the evidence
  dq freeze KEY -s SESSION [--by NAME]
                                  freeze the proof list (only "passes" may change)

Files and evidence
  dq path KEY                     where the item's files are on this machine
  dq new KEY contract|proofs|challenge|escalation|summary|jira|
             decomposition|handoff|verification [--to WHO]
                                  create a file from its template
  dq check-proofs KEY [--rung R] [--static]
                                  re-run the proofs marked passing
  dq evidence KEY -s SESSION FILE...
                                  store large evidence outside the claim
  dq work KEY REPO...             one worktree per repo on branch item/KEY

Shared resources
  dq lease list | take TRACK|any KEY -s SESSION [--minutes N]
           | release TRACK -s SESSION
  dq spot status | take KEY -s SESSION | release -s SESSION
                                  one spotlight per workspace

System
  dq version [--check] [--pull]   manual version; update from the shared repo
  dq generate                     write the scripts from script-instructions/*.md
  dq doctor                       check this workspace
  dq install [--workspace DIR]    bootstrap block, skills, hooks, permissions
  dq protect-check                test that claims cannot be overwritten
  dq publish-config               publish this workspace's config
  dq request SLUG FILE            file a request to the harness team
  dq board [--publish] [--out DIR]  build the board (for a pipeline job)

Exit codes: 0 ok, 1 error, 3 held by someone else, 4 you are not the active
session, 5 not available here, 6 evidence missing, 7 needs your attention.
EOF
}

# ---------------------------------------------------------------- helpers

die()  { printf 'dq: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

to_epoch() {
  if [ -z "${1:-}" ]; then echo 0; return 0; fi
  date -u -d "$1" +%s 2>/dev/null && return 0
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null && return 0
  echo 0
}
from_epoch() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}
age_sec() { # seconds since an ISO time; huge when the time is missing
  local t; t="$(to_epoch "${1:-}")"
  if [ "${t:-0}" -le 0 ]; then echo 99999999; else echo $(( $(date -u +%s) - t )); fi
}
file_age_sec() {
  local m; m="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)"
  echo $(( $(date -u +%s) - m ))
}
slug() { printf '%s' "${1:-}" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'; }
rand4() { od -An -N2 -tx1 /dev/urandom | tr -d ' \n'; }
valid_key() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "bad key: '${1:-}'"; }
have_py() { [ -z "${DQ_NO_PYTHON:-}" ] && command -v python3 >/dev/null 2>&1; }   # DQ_NO_PYTHON=1 is for testing
fmt_table() { if command -v column >/dev/null 2>&1; then column -t -s "$(printf '\t')"; else cat; fi; }
csv_norm() { printf '%s\n' "${1:-}" | tr ',' '\n' | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//' -e '/^$/d'; }
has_files() { [ -d "$1" ] && [ -n "$(find "$1" -type f -print -quit 2>/dev/null)" ]; }

# Two-level YAML: value of "  KEY:" under "SECTION:".
yget2() {
  if [ -z "${1:-}" ] || [ ! -f "$1" ]; then return 0; fi
  awk -v sec="$2" -v key="$3" '
    /^[A-Za-z_][A-Za-z0-9_]*:/ { cur = $0; sub(/:.*/, "", cur); insec = (cur == sec); next }
    insec && index($0, "  " key ":") == 1 {
      v = substr($0, length(key) + 4)
      sub(/[ \t]+#.*$/, "", v); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }' "$1"
}
# Flat "key: value" files (cards, leases, message headers).
# A value loses a trailing " # comment"; a value that is only a comment is empty.
fclean()   { head -n1 | sed -e 's/[ \t][ \t]*#.*$//' -e 's/^#.*$//' -e 's/[ \t]*$//'; }
fget()     { if [ -f "$1" ]; then sed -n "s/^$2:[ \t]*//p" "$1" | fclean; fi; }
fget_str() { printf '%s\n' "$1" | sed -n "s/^$2:[ \t]*//p" | fclean; }
fset() { # FILE KEY VALUE
  local f="$1" k="$2" tmp; tmp="$(mktemp)"
  if [ -f "$f" ] && grep -q "^$k:" "$f"; then
    V="$3" awk -v k="$k" '
      index($0, k ":") == 1 && !done { print (ENVIRON["V"] == "" ? k ":" : k ": " ENVIRON["V"]); done = 1; next }
      { print }' "$f" > "$tmp"
  else
    { if [ -f "$f" ]; then cat "$f"; fi
      if [ -n "$3" ]; then printf '%s: %s\n' "$k" "$3"; else printf '%s:\n' "$k"; fi; } > "$tmp"
  fi
  cat "$tmp" > "$f"; rm -f "$tmp"
}

# ---------------------------------------------------------------- context

CONFIG=""; WORKSPACE=""; QUEUE=""; ENGINEER=""; MACHINE=""; DEFAULT=""
STATE_DIR=""; ITEMS_DIR=""

load_context() {
  CONFIG="${DELIVERY_CONFIG:-}"
  if [ -z "$CONFIG" ]; then
    local d="$PWD"
    while :; do
      if [ -f "$d/delivery.config.yaml" ]; then CONFIG="$d/delivery.config.yaml"; break; fi
      if [ "$d" = "/" ]; then break; fi
      d="$(dirname "$d")"
    done
  fi
  if [ -z "$CONFIG" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/delivery.config.yaml" ]; then
    CONFIG="$CLAUDE_PROJECT_DIR/delivery.config.yaml"
  fi
  WORKSPACE="${DQ_WORKSPACE:-$(yget2 "$CONFIG" workspace root)}"
  if [ -z "$WORKSPACE" ]; then
    if [ -n "$CONFIG" ]; then WORKSPACE="$(dirname "$CONFIG")"; else WORKSPACE="${CLAUDE_PROJECT_DIR:-$PWD}"; fi
  fi
  QUEUE="${DQ_QUEUE:-$(yget2 "$CONFIG" queue path)}"
  ENGINEER="$(slug "${DQ_ENGINEER:-$(yget2 "$CONFIG" engineer name)}")"
  MACHINE="$(slug "${DQ_MACHINE:-$(yget2 "$CONFIG" workspace machine)}")"
  if [ -z "$MACHINE" ]; then MACHINE="$(slug "$(hostname 2>/dev/null || echo unknown)")"; fi
  STATE_DIR="${DQ_STATE_DIR:-$WORKSPACE/.delivery}"
  ITEMS_DIR="$STATE_DIR/items"
  DEFAULT="${DQ_DEFAULT_BRANCH:-$(yget2 "$CONFIG" queue default_branch)}"
}

# A setting: environment variable, then local config, then the shared
# environment file, then the default.
setting() { # SECTION KEY DEFAULT [ENVVAR]
  local v=""
  if [ -n "${4:-}" ]; then v="${!4:-}"; fi
  if [ -z "$v" ]; then v="$(yget2 "$CONFIG" "$1" "$2")"; fi
  if [ -z "$v" ]; then v="$(yget2 "$ENVFILE" "$1" "$2")"; fi
  if [ -z "$v" ]; then v="$3"; fi
  printf '%s' "$v"
}

need_queue() {
  [ -n "$QUEUE" ] || die "no queue repo configured (queue.path in delivery.config.yaml, or DQ_QUEUE)"
  git -C "$QUEUE" rev-parse --git-dir >/dev/null 2>&1 || die "queue path is not a git repo: $QUEUE"
  if [ -z "$DEFAULT" ]; then
    DEFAULT="$(git -C "$QUEUE" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
    if [ -z "$DEFAULT" ]; then DEFAULT="main"; fi
  fi
}
need_me() { [ -n "$ENGINEER" ] || die "no engineer name (engineer.name in delivery.config.yaml, or DQ_ENGINEER)"; }
item_dir() { printf '%s/%s' "$ITEMS_DIR" "$1"; }

# Repos listed in the local config: name<TAB>path<TAB>default_branch
config_repos() {
  if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then return 0; fi
  awk '
    function handle(l,   k, v) {
      k = l; sub(/:.*/, "", k); v = l; sub(/^[^:]*:[ \t]*/, "", v)
      sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v)
      if (k == "name") name = v; else if (k == "path") path = v; else if (k == "default_branch") br = v
    }
    function flush() { if (name != "" || path != "") print name "\t" path "\t" br; name = ""; path = ""; br = "" }
    /^repos:/ { inrepos = 1; next }
    /^[A-Za-z_]/ { if (inrepos) flush(); inrepos = 0 }
    inrepos && /^  - / { flush(); line = $0; sub(/^  - /, "", line); handle(line); next }
    inrepos && /^    [a-z_]+:/ { line = $0; sub(/^    /, "", line); handle(line); next }
    END { if (inrepos) flush() }' "$CONFIG"
}
repo_default() { # REPO_PATH -> its default branch
  local p b; p="$(cd "$1" && pwd)"
  b="$(config_repos | awk -F'\t' -v p="$p" '$2 == p { print $3; exit }')"
  if [ -z "$b" ]; then b="$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"; fi
  if [ -z "$b" ]; then b="main"; fi
  printf '%s' "$b"
}

# ---------------------------------------------------------- queue plumbing

Q()  { git -C "$QUEUE" "$@"; }
QI() { GIT_INDEX_FILE="$IDX" git -C "$QUEUE" "$@"; }
new_index()  { IDX="$(mktemp -u "${TMPDIR:-/tmp}/dq-index.XXXXXX")"; }
drop_index() { if [ -n "$IDX" ]; then rm -f "$IDX"; fi; IDX=""; }

ensure_identity() {
  if ! Q config user.name >/dev/null 2>&1; then
    export GIT_AUTHOR_NAME="${ENGINEER:-dq}" GIT_COMMITTER_NAME="${ENGINEER:-dq}"
  fi
  if ! Q config user.email >/dev/null 2>&1; then
    export GIT_AUTHOR_EMAIL="${ENGINEER:-dq}@${MACHINE:-local}" GIT_COMMITTER_EMAIL="${ENGINEER:-dq}@${MACHINE:-local}"
  fi
}

remote_tip() { # BRANCH -> sha, or empty when the branch does not exist
  local out
  out="$(Q ls-remote origin "refs/heads/$1" 2>"$TMPERR")" || die "cannot reach the queue remote: $(head -n1 "$TMPERR")"
  printf '%s\n' "$out" | awk 'NR == 1 { print $1 }'
}
fetch_branch() { # BRANCH -> refs/remotes/origin/BRANCH (retries on lock contention)
  local i
  for i in 1 2 3; do
    if Q fetch -q origin "+refs/heads/$1:refs/remotes/origin/$1" 2>"$TMPERR"; then return 0; fi
    sleep "$i"
  done
  return 1
}
push_commit() { # COMMIT BRANCH : a plain push. Never forced.
  local opts=() o
  for o in $(setting queue push_options "" DQ_PUSH_OPTIONS | tr ',' ' '); do opts+=(-o "$o"); done
  Q push -q ${opts[@]+"${opts[@]}"} origin "$1:refs/heads/$2" 2>"$TMPERR"
}

# Build a commit holding the given files on top of PARENT (or a first commit
# when PARENT is empty). Arguments after MSG come in pairs: PATH LOCALFILE.
commit_files() {
  local parent="$1" msg="$2" tree blob mode
  shift 2
  new_index
  if [ -n "$parent" ]; then QI read-tree "$parent"; fi
  while [ $# -ge 2 ]; do
    mode=100644; if [ -x "$2" ]; then mode=100755; fi
    blob="$(Q hash-object -w -- "$2")"
    QI update-index --add --cacheinfo "$mode,$blob,$1"
    shift 2
  done
  tree="$(QI write-tree)"
  drop_index
  if [ -n "$parent" ]; then
    if [ "$tree" = "$(Q rev-parse "$parent^{tree}")" ]; then printf '%s' "$parent"; return 0; fi
    Q commit-tree "$tree" -p "$parent" -m "$msg"
  else
    Q commit-tree "$tree" -m "$msg"
  fi
}

# Snapshot the local item directory as items/KEY/ on top of PARENT.
snapshot() { # KEY PARENT MSG -> commit (PARENT itself when nothing changed)
  local key="$1" parent="$2" msg="$3" dir f rel mode blob tree max kb big=0
  dir="$(item_dir "$key")"
  max="$(setting evidence max_file_kb 512 DQ_MAX_FILE_KB)"
  new_index
  QI read-tree "$parent"
  QI rm -r -q --cached --ignore-unmatch -- "items/$key" >/dev/null
  while IFS= read -r -d '' f; do
    rel="${f#"$dir"/}"
    case "$rel" in .dq/*|*.remote) continue ;; esac
    kb=$(( ( $(wc -c < "$f") + 1023 ) / 1024 ))
    if [ "$kb" -gt "$max" ]; then
      note "not saved to the claim (larger than ${max} KB): $rel"
      big=1; continue
    fi
    mode=100644; if [ -x "$f" ]; then mode=100755; fi
    blob="$(Q hash-object -w -- "$f")"
    QI update-index --add --cacheinfo "$mode,$blob,items/$key/$rel"
  done < <(find "$dir" -type f -print0 | sort -z)
  tree="$(QI write-tree)"
  drop_index
  if [ "$big" = 1 ]; then note "store large files with: dq evidence $key -s SESSION FILE..."; fi
  if [ "$tree" = "$(Q rev-parse "$parent^{tree}")" ]; then printf '%s' "$parent"; return 0; fi
  Q commit-tree "$tree" -p "$parent" -m "$msg"
}

# Write items/KEY/ from COMMIT into the local item directory.
materialize() { # KEY COMMIT
  local key="$1" commit="$2" dir; dir="$(item_dir "$key")"
  mkdir -p "$dir/.dq"
  if Q cat-file -e "$commit:items/$key" 2>/dev/null; then
    Q archive --format=tar "$commit:items/$key" | tar -xf - -C "$dir"
  fi
  printf '%s\n' "$commit" > "$dir/.dq/base"
}

# Bring remote changes (an answer, pipeline results) into the local item
# directory. A file changed on both sides is a conflict: the local file is
# kept and the remote version is saved beside it as FILE.remote.
MERGED=""; CONFLICTS=""
merge_from_remote() { # KEY BASE REMOTE
  local key="$1" base="$2" remote="$3" dir list path rel lf bb rb lb
  dir="$(item_dir "$key")"; MERGED=""; CONFLICTS=""
  list="$(mktemp)"
  if [ -n "$base" ] && Q cat-file -e "$base^{commit}" 2>/dev/null; then
    Q diff --name-only -z --no-renames "$base" "$remote" -- "items/$key" > "$list"
  else
    base=""
    Q ls-tree -r -z --name-only "$remote" -- "items/$key/" > "$list"
  fi
  while IFS= read -r -d '' path; do
    rel="${path#items/"$key"/}"; lf="$dir/$rel"
    bb=""; if [ -n "$base" ]; then bb="$(Q rev-parse -q --verify "$base:$path" 2>/dev/null || true)"; fi
    rb="$(Q rev-parse -q --verify "$remote:$path" 2>/dev/null || true)"
    lb=""; if [ -f "$lf" ]; then lb="$(Q hash-object -- "$lf")"; fi
    if [ "$lb" = "$rb" ]; then continue; fi
    if [ "$lb" = "$bb" ]; then
      if [ -n "$rb" ]; then mkdir -p "$(dirname "$lf")"; Q cat-file blob "$rb" > "$lf"; else rm -f "$lf"; fi
      MERGED="$MERGED $rel"
    else
      if [ -n "$rb" ]; then mkdir -p "$(dirname "$lf")"; Q cat-file blob "$rb" > "$lf.remote"; fi
      CONFLICTS="$CONFLICTS $rel"
    fi
  done < "$list"
  rm -f "$list"
}

# ------------------------------------------------------------------ proofs

# MODE: validate (structure) | static (passing proofs have evidence)
#     | gate (every proof of the rung passes, with evidence)
#     | run (re-run the command of every passing proof)
proofs_py() { # FILE MODE RUNG ITEMDIR
  if [ ! -f "$1" ]; then note "proofs.json is missing"; return 6; fi
  if ! have_py; then
    echo "PROOF_CHECK=skipped (python3 is not installed; proofs were not machine-checked)"
    return 0
  fi
  python3 - "$1" "$2" "$3" "$4" "$WORKSPACE" <<'PY'
import json, os, subprocess, sys, time
path, mode, rung, itemdir, cwd_default = sys.argv[1:6]
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception as exc:
    print("proofs.json does not parse: %s" % exc)
    sys.exit(6)
if not isinstance(data, list) or not data:
    print("proofs.json must be a non-empty list")
    sys.exit(6)
bad, seen, in_rung = 0, set(), 0
for p in data:
    if not isinstance(p, dict):
        print("every proof must be an object")
        bad += 1
        continue
    pid = p.get("id")
    if not pid or pid in seen:
        print("missing or repeated id: %r" % (pid,))
        bad += 1
        continue
    seen.add(pid)
    for field in ("scenario", "rung", "command", "evidence", "passes"):
        if field not in p:
            print("%s: missing field '%s'" % (pid, field))
            bad += 1
    if rung != "all" and p.get("rung") != rung:
        continue
    in_rung += 1
    if mode == "validate":
        continue
    if p.get("passes") is not True:
        if mode == "gate":
            print("%s: not passing yet" % pid)
            bad += 1
        continue
    ev = p.get("evidence") or ""
    evpath = os.path.join(itemdir, ev)
    if not (ev and os.path.isfile(evpath) and os.path.getsize(evpath) > 0):
        print("%s: marked passing, but its evidence file is missing or empty: %s" % (pid, ev or "(none named)"))
        bad += 1
        continue
    if mode == "run":
        cwd = p.get("cwd") or cwd_default
        if not os.path.isabs(cwd):          # relative to the workspace root, so it works on any machine
            cwd = os.path.join(cwd_default, cwd)
        started = time.time()
        try:
            done = subprocess.run(["bash", "-c", p.get("command", "false")], cwd=cwd,
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                  timeout=int(p.get("timeout_s", 900)))
            rc = done.returncode
        except subprocess.TimeoutExpired:
            rc = 124
        except Exception as exc:
            print("%s: could not run: %s" % (pid, exc))
            rc = 1
        print("%s: %s (%.0fs)" % (pid, "PASS" if rc == 0 else "FAIL rc=%d" % rc, time.time() - started))
        if rc != 0:
            bad += 1
if mode == "gate" and in_rung == 0:
    print("no proofs are defined for rung '%s'" % rung)
    bad += 1
sys.exit(6 if bad else 0)
PY
}

# Hash of the proof list with every "passes" value removed. Used to see
# whether anything other than "passes" changed after the proofs were frozen.
proofs_hash() { # FILE -> "py:HASH" or "sh:HASH"
  if [ ! -f "$1" ]; then return 0; fi
  if have_py; then
    printf 'py:%s' "$(python3 - "$1" <<'PY' | git hash-object --stdin
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    for p in data:
        if isinstance(p, dict):
            p.pop("passes", None)
    print(json.dumps(data, sort_keys=True))
except Exception as exc:
    print("unparseable: %s" % exc)
PY
)"
  else
    printf 'sh:%s' "$(grep -v '"passes"' "$1" | git hash-object --stdin)"
  fi
}

# --------------------------------------------------------------- the card

report_taken() { # KEY : say who holds it
  local key="$1" card=""
  if fetch_branch "claim/$key"; then
    card="$(Q show "refs/remotes/origin/claim/$key:items/$key/claim.yaml" 2>/dev/null || true)"
  fi
  local hb; hb="$(fget_str "$card" heartbeat_at)"
  echo "TAKEN=$key"
  echo "HELD_BY=$(fget_str "$card" engineer)"
  echo "STATE=$(fget_str "$card" state)"
  echo "HOLD=$(fget_str "$card" hold)"
  echo "ACTIVE_SESSION=$(fget_str "$card" active_session)"
  echo "HEARTBEAT_AT=$hb"
  echo "HEARTBEAT_AGE_MIN=$(( $(age_sec "$hb") / 60 ))"
}

write_new_card() { # FILE KEY KIND EPIC REMIT SESSION TIME
  cat > "$1" <<EOF
key: $2
kind: $3
epic: $4
remit: $5
tier:
state: Draft
hold: none
hold_reason:
hold_since:
engineer: $ENGINEER
claimed_at: $7
active_session: $6
active_machine: $MACHINE
active_since: $7
heartbeat_at: $7
active_seconds: 0
released_at:
repos:
services:
flows:
depends_on:
blocks:
proofs_frozen:
proofs_frozen_at:
proofs_approved_by:
proofs_flag:
previous_holders:
EOF
}

# Save the item, heartbeat, and push. Used by beat, release, state, freeze.
# Options come through these globals, set by the callers.
SET_STATE=""; SET_HOLD=""; SET_REASON=""; SET_PAIRS=(); SET_BY=""
sync_item() { # KEY SESSION MODE(beat|release) MSG
  local key="$1" sess="$2" mode="$3" msg="$4"
  local dir card stale try tip rcard rsess base t prev delta sec commit pair k v h flag
  dir="$(item_dir "$key")"; card="$dir/claim.yaml"
  [ -f "$card" ] || die "no local copy of $key on this machine ($dir). Run: dq take $key"
  stale=$(( $(setting coordination session_stale_minutes 120 DQ_STALE_MINUTES) * 60 ))
  for try in 1 2 3 4; do
    tip="$(remote_tip "claim/$key")"
    [ -n "$tip" ] || die "claim/$key does not exist on the remote"
    fetch_branch "claim/$key" || die "cannot fetch claim/$key: $(head -n1 "$TMPERR")"
    rcard="$(Q show "$tip:items/$key/claim.yaml" 2>/dev/null || true)"
    rsess="$(fget_str "$rcard" active_session)"
    if [ "$rsess" != "$sess" ]; then
      echo "NOT_ACTIVE=$key"
      echo "ACTIVE_SESSION=${rsess:-none}"
      echo "HEARTBEAT_AT=$(fget_str "$rcard" heartbeat_at)"
      note "This session ($sess) is not the active session for $key. Stop work on it."
      note "Your local files are kept in $dir. To continue, run: dq take $key"
      exit 4
    fi
    base="$(cat "$dir/.dq/base" 2>/dev/null || true)"
    if [ "$tip" != "$base" ]; then
      merge_from_remote "$key" "$base" "$tip"
      printf '%s\n' "$tip" > "$dir/.dq/base"
      if [ -n "$MERGED" ]; then echo "MERGED_FROM_REMOTE=${MERGED# }"; fi
      if [ -n "$CONFLICTS" ]; then
        echo "CONFLICTS=${CONFLICTS# }"
        note "Both you and someone else changed:${CONFLICTS}. Your version is kept; theirs is saved as FILE.remote. Read both and reconcile."
      fi
    fi
    t="$(now)"
    prev="$(fget "$card" heartbeat_at)"; delta="$(age_sec "$prev")"
    sec="$(fget "$card" active_seconds)"; sec="${sec:-0}"
    if [ "$delta" -gt 0 ] && [ "$delta" -lt "$stale" ]; then sec=$(( sec + delta )); fi
    fset "$card" active_seconds "$sec"
    fset "$card" heartbeat_at "$t"
    if [ -n "$SET_STATE" ]; then
      fset "$card" state "$SET_STATE"
      printf '%s %s by=%s session=%s\n' "$t" "$SET_STATE" "${SET_BY:-$ENGINEER}" "$sess" >> "$dir/history.log"
    fi
    if [ -n "$SET_HOLD" ]; then
      if [ "$SET_HOLD" != "$(fget "$card" hold)" ]; then
        if [ "$SET_HOLD" = none ]; then fset "$card" hold_since ""; else fset "$card" hold_since "$t"; fi
      fi
      fset "$card" hold "$SET_HOLD"
      fset "$card" hold_reason "$SET_REASON"
    fi
    for pair in ${SET_PAIRS[@]+"${SET_PAIRS[@]}"}; do
      k="${pair%%=*}"; v="${pair#*=}"
      fset "$card" "$k" "$v"
    done
    if [ "$mode" = release ]; then
      fset "$card" active_session ""; fset "$card" active_machine ""; fset "$card" active_since ""
      fset "$card" released_at "$t"
    fi
    h="$(fget "$card" proofs_frozen)"; flag=""
    if [ -n "$h" ] && [ -f "$dir/proofs.json" ]; then
      if [ "${h%%:*}" = "$(proofs_hash "$dir/proofs.json" | cut -d: -f1)" ] && [ "$h" != "$(proofs_hash "$dir/proofs.json")" ]; then
        flag="changed-after-freeze $t"
        if [ -z "$(fget "$card" proofs_flag)" ]; then fset "$card" proofs_flag "$flag"; fi
      fi
    fi
    commit="$(snapshot "$key" "$tip" "$msg")"
    if push_commit "$commit" "claim/$key"; then
      printf '%s\n' "$commit" > "$dir/.dq/base"
      if [ "$mode" = release ]; then rm -f "$dir/.dq/session"; fi
      if [ -f "$STATE_DIR/locks/spotlight/info" ] && grep -q "^session: $sess\$" "$STATE_DIR/locks/spotlight/info"; then
        touch "$STATE_DIR/locks/spotlight/info"
      fi
      echo "SAVED=$key"
      echo "AT=$t"
      echo "STATE=$(fget "$card" state)"
      echo "HOLD=$(fget "$card" hold)"
      printf 'ACTIVE_HOURS=%d.%d\n' $(( sec / 3600 )) $(( (sec % 3600) / 360 ))
      if [ -n "$flag" ]; then
        echo "PROOFS_FLAG=changed-after-freeze"
        note "proofs.json changed in more than its 'passes' values after it was frozen. That needs approval: get it, then run dq freeze again."
      fi
      budget_report "$key" "$sec"
      return 0
    fi
    sleep 1
  done
  die "could not push $key after several attempts: $(head -n1 "$TMPERR")"
}

budget_report() { # KEY ACTIVE_SECONDS : say when a budget in the contract is spent
  local dir bh bi n; dir="$(item_dir "$1")"
  bh="$(yget2 "$dir/contract.yaml" budget hours)"
  bi="$(yget2 "$dir/contract.yaml" budget iterations)"
  if [ -n "$bh" ] && awk -v s="$2" -v h="$bh" 'BEGIN { exit !(h + 0 > 0 && s > h * 3600) }'; then
    echo "BUDGET=hours-spent"
    note "The hours budget ($bh h) is spent. That is a stop condition: park and ask."
  fi
  if [ -n "$bi" ] && [ -f "$dir/journal.md" ]; then
    n="$(grep -c '^### Attempt' "$dir/journal.md" || true)"
    if awk -v n="$n" -v b="$bi" 'BEGIN { exit !(b + 0 > 0 && n > b) }'; then
      echo "BUDGET=iterations-spent"
      note "The iterations budget ($bi) is spent ($n attempts logged). That is a stop condition: park and ask."
    fi
  fi
}

# What must exist before an item may enter a state.
gate() { # KEY STATE BY -> 0, or says what is missing and returns 6
  local key="$1" st="$2" by="$3" dir missing=0; dir="$(item_dir "$key")"
  case "$st" in
    Draft|Ready) ;;
    Claimed)
      if [ ! -s "$dir/contract.yaml" ]; then note "missing for $st: contract.yaml"; missing=1
      elif [ -z "$(fget "$dir/contract.yaml" approved_by)" ]; then note "missing for $st: approved_by in contract.yaml"; missing=1; fi
      if [ ! -s "$dir/proofs.json" ]; then note "missing for $st: proofs.json"; missing=1; fi
      if [ -z "$(fget "$dir/claim.yaml" proofs_frozen)" ]; then note "missing for $st: frozen proofs (run: dq freeze $key -s SESSION)"; missing=1; fi
      ;;
    Local-proven)
      proofs_py "$dir/proofs.json" gate local "$dir" || missing=1
      if ! has_files "$dir/bundle/rung1"; then note "missing for $st: saved outputs under bundle/rung1/"; missing=1; fi
      if [ ! -s "$dir/bundle/verification.md" ]; then note "missing for $st: bundle/verification.md (the fresh-eyes check and what was done about it)"; missing=1; fi
      ;;
    Track-proven)
      proofs_py "$dir/proofs.json" gate track "$dir" || missing=1
      if ! has_files "$dir/bundle/rung2"; then note "missing for $st: track results under bundle/rung2/"; missing=1; fi
      if [ ! -s "$dir/bundle/SUMMARY.md" ]; then note "missing for $st: bundle/SUMMARY.md"; missing=1; fi
      if [ ! -s "$dir/jira-update.md" ]; then note "missing for $st: jira-update.md"; missing=1; fi
      ;;
    Satisfied)
      if [ ! -s "$dir/bundle/SUMMARY.md" ]; then note "missing for $st: bundle/SUMMARY.md with the evidence that it is already done"; missing=1; fi
      if [ ! -s "$dir/jira-update.md" ]; then note "missing for $st: jira-update.md"; missing=1; fi
      ;;
    Decomposed)
      if [ ! -s "$dir/decomposition.yaml" ]; then note "missing for $st: decomposition.yaml"; missing=1; fi
      ;;
    UAT-proven|Live|Confirmed|Regressed|Cancelled)
      if [ -z "$by" ]; then note "missing for $st: --by NAME (the person who confirmed it)"; missing=1; fi
      ;;
    *) die "unknown state: $st (one of: $STATES)" ;;
  esac
  if [ "$missing" = 1 ]; then return 6; fi
}

# ---------------------------------------------------------------- commands

cmd_claim() {
  local key="" kind="story" epic="" remit="" reopen=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind="$2"; shift 2 ;;
      --epic) epic="$2"; shift 2 ;;
      --remit) remit="$2"; shift 2 ;;
      --reopen) reopen=1; shift ;;
      -*) die "claim: unknown option $1" ;;
      *) key="$1"; shift ;;
    esac
  done
  [ -n "$key" ] || die "usage: dq claim KEY [--kind story|bug|task|spike|epic] [--epic KEY] [--remit NAME] [--reopen]"
  valid_key "$key"; need_queue; need_me; ensure_identity
  local tip parent dir sess t commit closed="" st=""
  tip="$(remote_tip "claim/$key")"
  if [ -n "$tip" ]; then
    if fetch_branch "claim/$key"; then
      st="$(Q show "refs/remotes/origin/claim/$key:items/$key/claim.yaml" 2>/dev/null | sed -n 's/^state:[ \t]*//p' | head -n1)"
    fi
    case " $CLOSED_STATES " in
      *" $st "*)
        echo "CLOSED=$key"
        echo "STATE=$st"
        note "$key is closed (state: $st). Read it with: dq show $key bundle/SUMMARY.md"
        if [ "$reopen" = 1 ]; then
          note "Its claim branch is still on the server, so it cannot be claimed again from here."
          note "More work on a closed item is normally a new ticket. Otherwise ask the harness team to archive claim/$key first."
          exit 5
        fi
        exit 3 ;;
    esac
    report_taken "$key"; exit 3
  fi
  fetch_branch "$DEFAULT" || die "cannot fetch $DEFAULT from the queue remote: $(head -n1 "$TMPERR")"
  parent="$(Q rev-parse "refs/remotes/origin/$DEFAULT")"
  if Q cat-file -e "$parent:items/$key/claim.yaml" 2>/dev/null; then
    closed="$(Q show "$parent:items/$key/claim.yaml" | sed -n 's/^state:[ \t]*//p' | head -n1)"
    if [ "$reopen" = 0 ]; then
      echo "CLOSED=$key"
      echo "STATE=$closed"
      note "$key was already closed on $DEFAULT (state: $closed). Read items/$key/ there first."
      note "If it truly needs more work, claim it again with: dq claim $key --reopen"
      exit 3
    fi
  fi
  dir="$(item_dir "$key")"; sess="$ENGINEER@$MACHINE#$(rand4)"; t="$(now)"
  if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    mv "$dir" "$dir.old-$(date -u +%Y%m%d%H%M%S)"
    note "an older local copy of $key was moved aside: $dir.old-*"
  fi
  mkdir -p "$dir/.dq"
  if [ -n "$closed" ]; then materialize "$key" "$parent"; fi
  if [ ! -f "$dir/contract.yaml" ] && Q cat-file -e "$parent:ready/$key.yaml" 2>/dev/null; then
    Q show "$parent:ready/$key.yaml" > "$dir/contract.yaml"
  fi
  write_new_card "$dir/claim.yaml" "$key" "$kind" "$epic" "$remit" "$sess" "$t"
  if [ ! -f "$dir/journal.md" ]; then
    if [ -f "$SYSTEM_DIR/templates/journal.md" ]; then
      sed -e "s/{{KEY}}/$key/g" -e "s/{{NOW}}/$t/g" -e "s/{{SESSION}}/$sess/g" "$SYSTEM_DIR/templates/journal.md" > "$dir/journal.md"
    else
      printf '# %s journal\n\n## Log\n%s Claimed by %s.\n' "$key" "$t" "$sess" > "$dir/journal.md"
    fi
  fi
  if [ -n "$closed" ]; then printf '%s reopened (was %s) by=%s session=%s\n' "$t" "$closed" "$ENGINEER" "$sess" >> "$dir/history.log"; fi
  commit="$(snapshot "$key" "$parent" "claim $key: $sess")"
  if ! push_commit "$commit" "claim/$key"; then
    tip="$(remote_tip "claim/$key")"
    if [ -z "$tip" ]; then die "claim push failed: $(head -n1 "$TMPERR")"; fi
    if [ "$tip" != "$commit" ]; then rm -rf "$dir"; report_taken "$key"; exit 3; fi
  fi
  printf '%s\n' "$commit" > "$dir/.dq/base"
  printf '%s\n' "$sess" > "$dir/.dq/session"
  echo "CLAIMED=$key"
  echo "SESSION=$sess"
  echo "ITEM_DIR=$dir"
  echo "STATE=Draft"
  if [ -f "$dir/contract.yaml" ]; then echo "CONTRACT=found in ready/ and copied"; fi
}

cmd_whois() {
  local key="${1:-}"; valid_key "$key"; need_queue
  local tip card hb age stale sess eng
  tip="$(remote_tip "claim/$key")"
  if [ -z "$tip" ]; then
    fetch_branch "$DEFAULT" || true
    if Q cat-file -e "refs/remotes/origin/$DEFAULT:items/$key/claim.yaml" 2>/dev/null; then
      echo "CLOSED=$key"
      Q show "refs/remotes/origin/$DEFAULT:items/$key/claim.yaml" | sed -n -e '/^state:/p' -e '/^engineer:/p' -e '/^released_at:/p'
    else
      echo "FREE=$key"
    fi
    return 0
  fi
  fetch_branch "claim/$key" || die "cannot fetch claim/$key"
  card="$(Q show "$tip:items/$key/claim.yaml" 2>/dev/null || true)"
  printf '%s\n' "$card"
  hb="$(fget_str "$card" heartbeat_at)"; age=$(( $(age_sec "$hb") / 60 ))
  stale="$(setting coordination session_stale_minutes 120 DQ_STALE_MINUTES)"
  sess="$(fget_str "$card" active_session)"; eng="$(fget_str "$card" engineer)"
  echo "---"
  case " $CLOSED_STATES " in *" $(fget_str "$card" state) "*) echo "CLOSED=$key" ;; esac
  echo "HEARTBEAT_AGE_MIN=$age"
  if [ -z "$sess" ]; then
    echo "ACTIVE=no"
    if [ "$eng" = "$ENGINEER" ]; then echo "CAN_TAKE=yes (released, and it is yours)"
    else echo "CAN_TAKE=with --from $eng --reason, after $eng or the remit lead agrees"; fi
  elif [ "$age" -ge "$stale" ]; then
    echo "ACTIVE=silent for $age min (stale after $stale)"
    if [ "$eng" = "$ENGINEER" ]; then echo "CAN_TAKE=yes (your own silent session)"
    else echo "CAN_TAKE=with --from $eng --reason, after $eng or the remit lead agrees"; fi
  else
    echo "ACTIVE=yes"
    if [ "$eng" = "$ENGINEER" ]; then echo "CAN_TAKE=only with --replace-mine \"reason\", if that session is truly gone"
    else echo "CAN_TAKE=no (an active session holds it)"; fi
  fi
}

cmd_show() { # KEY [FILE] : print one file of any item, open or closed; with no FILE, list its files
  local key="${1:-}" file="${2:-}" tip ref=""
  valid_key "$key"; need_queue
  tip="$(remote_tip "claim/$key")"
  if [ -n "$tip" ] && fetch_branch "claim/$key"; then
    ref="$tip"
  else
    fetch_branch "$DEFAULT" || die "cannot fetch $DEFAULT from the queue remote"
    if Q cat-file -e "refs/remotes/origin/$DEFAULT:items/$key/claim.yaml" 2>/dev/null; then ref="refs/remotes/origin/$DEFAULT"; fi
  fi
  [ -n "$ref" ] || die "there is no item $key in the queue"
  if [ -z "$file" ]; then
    Q ls-tree -r --name-only "$ref" -- "items/$key/" | sed "s#^items/$key/##"
    return 0
  fi
  Q show "$ref:items/$key/$file" 2>/dev/null || die "$key has no file '$file'. List its files with: dq show $key"
}

cmd_take() {
  local key="" from="" reason="" replace=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      --replace-mine) replace="$2"; shift 2 ;;
      -*) die "take: unknown option $1" ;;
      *) key="$1"; shift ;;
    esac
  done
  [ -n "$key" ] || die "usage: dq take KEY [--from ENGINEER --reason \"...\"] [--replace-mine \"reason\"]"
  valid_key "$key"; need_queue; need_me; ensure_identity
  local tip rcard eng asess hb age stale dir card base sess t commit prev
  tip="$(remote_tip "claim/$key")"
  [ -n "$tip" ] || die "there is no claim for $key. Use: dq claim $key"
  fetch_branch "claim/$key" || die "cannot fetch claim/$key"
  rcard="$(Q show "$tip:items/$key/claim.yaml" 2>/dev/null || true)"
  eng="$(fget_str "$rcard" engineer)"; asess="$(fget_str "$rcard" active_session)"
  hb="$(fget_str "$rcard" heartbeat_at)"; age=$(( $(age_sec "$hb") / 60 ))
  stale="$(setting coordination session_stale_minutes 120 DQ_STALE_MINUTES)"
  if [ -n "$asess" ] && [ "$age" -lt "$stale" ]; then
    if [ "$eng" = "$ENGINEER" ] && [ -n "$replace" ]; then
      note "replacing your own session $asess: $replace"
    else
      echo "ACTIVE_ELSEWHERE=$key"
      echo "ACTIVE_SESSION=$asess"
      echo "HEARTBEAT_AGE_MIN=$age"
      note "$key has an active session ($asess, last heartbeat $age min ago)."
      note "Ask that session to run 'dq release', or wait until it has been silent for $stale min."
      if [ "$eng" = "$ENGINEER" ]; then note "If it is your own session and it is gone for good: dq take $key --replace-mine \"reason\""; fi
      exit 3
    fi
  fi
  if [ "$eng" != "$ENGINEER" ]; then
    if [ "$from" != "$eng" ] || [ -z "$reason" ]; then
      echo "OWNED_BY=$eng"
      note "$key belongs to $eng. Taking it over is a handover: get $eng's or the remit lead's agreement,"
      note "then run: dq take $key --from $eng --reason \"who agreed and why\""
      exit 3
    fi
  fi
  dir="$(item_dir "$key")"; card="$dir/claim.yaml"
  base="$(cat "$dir/.dq/base" 2>/dev/null || true)"
  if [ -n "$base" ] && [ -f "$card" ]; then
    merge_from_remote "$key" "$base" "$tip"
    if [ -n "$CONFLICTS" ]; then
      echo "CONFLICTS=${CONFLICTS# }"
      note "Local and remote both changed:${CONFLICTS}. Yours is kept; the remote version is saved as FILE.remote."
    fi
    # the card on the remote is the truth for who holds the item
    printf '%s\n' "$rcard" > "$card"; rm -f "$card.remote"
    printf '%s\n' "$tip" > "$dir/.dq/base"
  else
    if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
      mv "$dir" "$dir.old-$(date -u +%Y%m%d%H%M%S)"
      note "an older local copy of $key was moved aside: $dir.old-*"
    fi
    materialize "$key" "$tip"
  fi
  sess="$ENGINEER@$MACHINE#$(rand4)"; t="$(now)"
  if [ "$eng" != "$ENGINEER" ]; then
    prev="$(fget "$card" previous_holders)"
    fset "$card" previous_holders "${prev:+$prev; }$eng until $t ($reason)"
    fset "$card" engineer "$ENGINEER"
    printf '%s handover from %s to %s: %s\n' "$t" "$eng" "$ENGINEER" "$reason" >> "$dir/history.log"
  fi
  fset "$card" active_session "$sess"
  fset "$card" active_machine "$MACHINE"
  fset "$card" active_since "$t"
  fset "$card" heartbeat_at "$t"
  fset "$card" released_at ""
  commit="$(snapshot "$key" "$tip" "take $key: $sess")"
  if ! push_commit "$commit" "claim/$key"; then
    echo "LOST_RACE=$key"
    note "Another session took $key first. Run: dq whois $key"
    exit 3
  fi
  printf '%s\n' "$commit" > "$dir/.dq/base"
  printf '%s\n' "$sess" > "$dir/.dq/session"
  echo "TAKEN_OVER=$key"
  echo "SESSION=$sess"
  echo "ITEM_DIR=$dir"
  echo "STATE=$(fget "$card" state)"
  echo "HOLD=$(fget "$card" hold)"
  note "Read $dir/journal.md, starting at 'Resume from', before doing anything else."
}

parse_sync_args() { # sets KEY SESS MSG and the SET_* globals from "$@"
  KEY=""; SESS=""; MSG=""; SET_STATE=""; SET_HOLD=""; SET_REASON=""; SET_PAIRS=(); SET_BY=""; POS=()
  local k
  while [ $# -gt 0 ]; do
    case "$1" in
      -s|--session) SESS="$2"; shift 2 ;;
      --state) SET_STATE="$2"; shift 2 ;;
      --hold) SET_HOLD="$2"; shift 2 ;;
      --reason) SET_REASON="$2"; shift 2 ;;
      --by) SET_BY="$2"; shift 2 ;;
      -m) MSG="$2"; shift 2 ;;
      --set)
        k="${2%%=*}"
        case " $CARD_SCOPE_KEYS " in *" $k "*) SET_PAIRS+=("$2") ;; *) die "--set: '$k' is not one of: $CARD_SCOPE_KEYS" ;; esac
        shift 2 ;;
      --no-run) NO_RUN=1; shift ;;
      -*) die "unknown option $1" ;;
      *) if [ -z "$KEY" ]; then KEY="$1"; else POS+=("$1"); fi; shift ;;
    esac
  done
  [ -n "$KEY" ] || die "which item? Give its key."
  valid_key "$KEY"
  [ -n "$SESS" ] || die "which session? Pass -s SESSION (printed by dq claim or dq take)."
  if [ -n "$SET_HOLD" ]; then
    case " $HOLDS " in *" $SET_HOLD "*) ;; *) die "--hold must be one of: $HOLDS" ;; esac
  fi
  if [ -n "$SET_STATE" ]; then
    case " $STATES " in *" $SET_STATE "*) ;; *) die "--state must be one of: $STATES" ;; esac
  fi
}
KEY=""; SESS=""; MSG=""; POS=(); NO_RUN=0

cmd_beat() {
  parse_sync_args "$@"; need_queue; need_me; ensure_identity
  if [ -n "$SET_STATE" ]; then gate "$KEY" "$SET_STATE" "$SET_BY" || exit 6; fi
  sync_item "$KEY" "$SESS" beat "${MSG:-beat $KEY}"
}

cmd_release() {
  parse_sync_args "$@"; need_queue; need_me; ensure_identity
  if [ -n "$SET_STATE" ]; then gate "$KEY" "$SET_STATE" "$SET_BY" || exit 6; fi
  sync_item "$KEY" "$SESS" release "${MSG:-release $KEY}"
  echo "RELEASED=$KEY"
}

cmd_state() {
  parse_sync_args "$@"; need_queue; need_me; ensure_identity
  local st="${POS[0]:-}" dir; dir="$(item_dir "$KEY")"
  [ -n "$st" ] || die "usage: dq state KEY -s SESSION STATE [--by NAME] [--no-run]   (states: $STATES)"
  case " $STATES " in *" $st "*) ;; *) die "unknown state: $st (one of: $STATES)" ;; esac
  gate "$KEY" "$st" "$SET_BY" || exit 6
  if [ -z "$SET_HOLD" ]; then SET_HOLD="none"; fi   # progress ends whatever the item was waiting for
  if [ "$st" = Local-proven ] && [ "$NO_RUN" = 0 ]; then
    note "re-running the local proofs before recording $st ..."
    proofs_py "$dir/proofs.json" run local "$dir" || { note "a proof marked passing does not pass now. State not changed."; exit 6; }
  fi
  SET_STATE="$st"
  sync_item "$KEY" "$SESS" beat "${MSG:-state $KEY: $st}"
}

cmd_freeze() {
  parse_sync_args "$@"; need_queue; need_me; ensure_identity
  local dir tier h t; dir="$(item_dir "$KEY")"
  proofs_py "$dir/proofs.json" validate all "$dir" || exit 6
  tier="$(fget "$dir/contract.yaml" tier)"
  case "$tier" in 0|1|2|3) ;; *) die "contract.yaml needs tier: 0, 1, 2 or 3 before the proofs can be frozen (found: '${tier:-nothing}')" ;; esac
  if [ "$tier" -ge 2 ] && [ -z "$SET_BY" ]; then
    note "Tier $tier proofs are approved by the remit lead before any implementation."
    note "Get that approval, then run: dq freeze $KEY -s $SESS --by NAME"
    exit 6
  fi
  h="$(proofs_hash "$dir/proofs.json")"; t="$(now)"
  fset "$dir/claim.yaml" proofs_frozen "$h"
  fset "$dir/claim.yaml" proofs_frozen_at "$t"
  fset "$dir/claim.yaml" proofs_approved_by "${SET_BY:-$ENGINEER}"
  fset "$dir/claim.yaml" proofs_flag ""
  fset "$dir/claim.yaml" tier "$tier"
  printf '%s proofs frozen by=%s session=%s\n' "$t" "${SET_BY:-$ENGINEER}" "$SESS" >> "$dir/history.log"
  sync_item "$KEY" "$SESS" beat "freeze proofs for $KEY (approved by ${SET_BY:-$ENGINEER})"
  echo "FROZEN=$KEY"
}

cmd_path() { local key="${1:-}"; valid_key "$key"; item_dir "$key"; echo; }

cmd_new() {
  local key="${1:-}" kind="${2:-}" to="" force=0
  if [ $# -ge 2 ]; then shift 2; else shift $#; fi
  while [ $# -gt 0 ]; do
    case "$1" in --to) to="$2"; shift 2 ;; --force) force=1; shift ;; *) die "new: unknown option $1" ;; esac
  done
  valid_key "$key"
  local dir tpl dest n sess t; dir="$(item_dir "$key")"
  [ -d "$dir" ] || die "no local copy of $key ($dir). Claim or take it first."
  case "$kind" in
    contract)      tpl="contract.yaml";      dest="contract.yaml" ;;
    proofs)        tpl="proofs.json";        dest="proofs.json" ;;
    challenge)     tpl="challenge.md";       dest="escalations/$key-challenge.md" ;;   # so it shows as an open question
    summary)       tpl="SUMMARY.md";         dest="bundle/SUMMARY.md" ;;
    jira)          tpl="jira-update.md";     dest="jira-update.md"; force=1 ;;
    decomposition) tpl="decomposition.yaml"; dest="decomposition.yaml" ;;
    handoff)       tpl="track-handoff.md";   dest="track-handoff.md" ;;
    verification)  tpl="verification.md";    dest="bundle/verification.md" ;;
    escalation)
      n=1; while [ -e "$dir/escalations/$key-$n.md" ]; do n=$(( n + 1 )); done
      tpl="escalation.md"; dest="escalations/$key-$n.md" ;;
    *) die "usage: dq new KEY contract|proofs|challenge|escalation|summary|jira|decomposition|handoff|verification [--to WHO]" ;;
  esac
  [ -f "$SYSTEM_DIR/templates/$tpl" ] || die "template not found: $SYSTEM_DIR/templates/$tpl"
  if [ -e "$dir/$dest" ] && [ "$force" = 0 ]; then die "$dest already exists. Edit it, or pass --force to start again."; fi
  mkdir -p "$(dirname "$dir/$dest")"
  sess="$(cat "$dir/.dq/session" 2>/dev/null || echo unknown)"; t="$(now)"
  sed -e "s/{{KEY}}/$key/g" -e "s/{{NOW}}/$t/g" -e "s/{{ENGINEER}}/$ENGINEER/g" \
      -e "s/{{SESSION}}/$sess/g" -e "s/{{N}}/${n:-1}/g" -e "s/{{TO}}/$(printf '%s' "$to" | sed 's/[&/\]/\\&/g')/g" \
      "$SYSTEM_DIR/templates/$tpl" > "$dir/$dest"
  echo "CREATED=$dir/$dest"
}

cmd_check_proofs() {
  local key="" rung="all" mode="run"
  while [ $# -gt 0 ]; do
    case "$1" in --rung) rung="$2"; shift 2 ;; --static) mode="static"; shift ;; -*) die "check-proofs: unknown option $1" ;; *) key="$1"; shift ;; esac
  done
  valid_key "$key"
  local dir; dir="$(item_dir "$key")"
  if proofs_py "$dir/proofs.json" "$mode" "$rung" "$dir"; then echo "PROOFS=ok"; else echo "PROOFS=failed"; exit 6; fi
}

cmd_work() {
  local key="${1:-}"; if [ $# -ge 1 ]; then shift; fi
  valid_key "$key"
  [ $# -ge 1 ] || die "usage: dq work KEY REPO_PATH..."
  local repo name wt br
  for repo in "$@"; do
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $repo"
    name="$(basename "$(cd "$repo" && pwd)")"
    wt="$STATE_DIR/work/$key/$name"
    if [ -e "$wt/.git" ]; then echo "WORKTREE=$wt"; continue; fi
    br="$(repo_default "$repo")"
    git -C "$repo" fetch -q origin "+refs/heads/$br:refs/remotes/origin/$br" 2>/dev/null || note "could not fetch $br for $name; using what is here"
    mkdir -p "$(dirname "$wt")"
    if [ -n "$(git -C "$repo" ls-remote origin "refs/heads/item/$key" 2>/dev/null)" ]; then
      git -C "$repo" fetch -q origin "+refs/heads/item/$key:refs/remotes/origin/item/$key"
      if git -C "$repo" show-ref -q --verify "refs/heads/item/$key"; then
        git -C "$repo" worktree add -q "$wt" "item/$key"
        git -C "$wt" merge -q --ff-only "origin/item/$key" 2>/dev/null || note "$name: local item/$key and the remote have diverged. Look before you continue."
      else
        git -C "$repo" worktree add -q --track -b "item/$key" "$wt" "origin/item/$key"
      fi
      echo "WORKTREE=$wt"
      echo "RESUMED=$name item/$key from the remote"
    else
      if git -C "$repo" show-ref -q --verify "refs/heads/item/$key"; then
        git -C "$repo" worktree add -q "$wt" "item/$key"
      else
        git -C "$repo" worktree add -q --no-track -b "item/$key" "$wt" "origin/$br"
      fi
      echo "WORKTREE=$wt"
    fi
  done
}

cmd_push() {
  parse_sync_args "$@"; need_queue; need_me; ensure_identity
  local w n=0
  for w in "$STATE_DIR/work/$KEY"/*/; do
    if [ ! -e "$w/.git" ]; then continue; fi
    if git -C "$w" push -q -u origin "item/$KEY" 2>"$TMPERR"; then
      n=$(( n + 1 )); echo "PUSHED=$(basename "$w") item/$KEY"
    else
      note "push failed for $(basename "$w"): $(head -n1 "$TMPERR")"
      note "If the remote moved, bring it in with a merge (never a force-push), then push again."
      exit 7
    fi
  done
  if [ "$n" = 0 ]; then note "no worktrees under $STATE_DIR/work/$KEY. Push your item/$KEY branches yourself."; fi
  sync_item "$KEY" "$SESS" beat "${MSG:-push $KEY}"
}

cmd_evidence() {
  parse_sync_args "$@"; need_queue; need_me; ensure_identity
  [ "${#POS[@]}" -ge 1 ] || die "usage: dq evidence KEY -s SESSION FILE..."
  local loc dir tip rcard f rel args=() commit try dest
  dir="$(item_dir "$KEY")"
  loc="$(setting evidence location branch DQ_EVIDENCE_LOCATION)"
  tip="$(remote_tip "claim/$KEY")"; [ -n "$tip" ] || die "claim/$KEY does not exist"
  fetch_branch "claim/$KEY" || die "cannot fetch claim/$KEY"
  rcard="$(Q show "$tip:items/$KEY/claim.yaml" 2>/dev/null || true)"
  if [ "$(fget_str "$rcard" active_session)" != "$SESS" ]; then echo "NOT_ACTIVE=$KEY"; exit 4; fi
  for f in "${POS[@]}"; do
    [ -f "$f" ] || die "not a file: $f"
    f="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
    case "$f" in "$dir"/*) rel="${f#"$dir"/}" ;; *) rel="$(basename "$f")" ;; esac
    args+=("$KEY/$rel" "$f")
  done
  case "$loc" in
    branch)
      for try in 1 2 3; do
        tip="$(remote_tip "evidence/$KEY")"
        if [ -n "$tip" ]; then fetch_branch "evidence/$KEY" || die "cannot fetch evidence/$KEY"; fi
        commit="$(commit_files "$tip" "evidence for $KEY" "${args[@]}")"
        if [ "$commit" = "$tip" ] || push_commit "$commit" "evidence/$KEY"; then
          echo "EVIDENCE_BRANCH=evidence/$KEY"
          echo "EVIDENCE_COMMIT=$commit"
          set -- "${args[@]}"
          while [ $# -ge 2 ]; do echo "STORED=$1"; shift 2; done
          note "Name the branch, the commit and each path in bundle/SUMMARY.md."
          return 0
        fi
        sleep 1
      done
      die "could not push evidence/$KEY: $(head -n1 "$TMPERR")"
      ;;
    path:*)
      dest="${loc#path:}/$KEY"
      mkdir -p "$dest" || die "cannot write to $dest"
      set -- "${args[@]}"
      while [ $# -ge 2 ]; do
        mkdir -p "$(dirname "${loc#path:}/$1")"; cp "$2" "${loc#path:}/$1"; echo "STORED=${loc#path:}/$1"; shift 2
      done
      ;;
    *)
      echo "EVIDENCE=not-handled"
      note "evidence.location is '$loc'. dq does not handle it; follow the note in the shared environment file."
      exit 5 ;;
  esac
}

# ------------------------------------------------------------ look around

LOOKGIT=()
card_row() { # KEY (card text on stdin) -> one board row
  awk -v key="$1" -v fields="$BOARD_FIELDS" '
    { i = index($0, ":")
      if (i > 1) { k = substr($0, 1, i - 1); v = substr($0, i + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); if (!(k in val)) val[k] = v } }
    END { n = split(fields, f, " "); out = key; for (j = 1; j <= n; j++) out = out "\t" val[f[j]]; print out }'
}
open_only() { # board rows on stdin -> rows whose state is not closed
  awk -F'\t' -v closed=" $CLOSED_STATES " 'NF && index(closed, " " $3 " ") == 0'
}
of_open_items() { # question rows on stdin, board rows in $1 -> questions of open items
  KEYS="$(printf '%s\n' "$1" | cut -f1)" awk -F'\t' 'BEGIN { n = split(ENVIRON["KEYS"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") k[a[i]] = 1 } NF && ($1 in k)'
}
quiet_rows() { # board rows on stdin -> open claims with no session and no save for claim_quiet_days
  local cut
  cut="$(from_epoch $(( $(date -u +%s) - $(setting coordination claim_quiet_days 3 DQ_QUIET_DAYS) * 86400 )))"
  awk -F'\t' -v cut="$cut" 'NF && $6 == "" && $8 != "" && $8 <= cut'
}
claim_rows() { # REFPREFIX
  local ref key
  "${LOOKGIT[@]}" for-each-ref --format='%(refname)' "$1" | while IFS= read -r ref; do
    key="${ref#"$1"}"
    case "$key" in _smoke-*) continue ;; esac
    { "${LOOKGIT[@]}" show "$ref:items/$key/claim.yaml" 2>/dev/null || true; } | card_row "$key"
  done
}
question_rows() { # REFPREFIX : escalation files that have no answer yet
  local ref key f body answer
  "${LOOKGIT[@]}" for-each-ref --format='%(refname)' "$1" | while IFS= read -r ref; do
    key="${ref#"$1"}"
    { "${LOOKGIT[@]}" ls-tree -r --name-only "$ref" -- "items/$key/escalations/" 2>/dev/null || true; } | while IFS= read -r f; do
      body="$("${LOOKGIT[@]}" show "$ref:$f" 2>/dev/null || true)"
      answer="$(printf '%s\n' "$body" | awk '
        /^Answer:/ { found = 1; rest = $0; sub(/^Answer:[ \t]*/, "", rest); if (rest != "" && rest !~ /^\(/) { print rest; exit } next }
        found && $0 ~ /[^ \t]/ && $0 !~ /^[ \t]*\(/ { print; exit }')"
      if [ -n "$answer" ]; then continue; fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "${f##*/}" "$(fget_str "$body" To)" \
        "$(fget_str "$body" Blocking)" "$(fget_str "$body" "Asked by")" "$(fget_str "$body" Asked)"
    done
  done
}
request_rows() { # REFPREFIX
  local ref name body
  "${LOOKGIT[@]}" for-each-ref --format='%(refname)' "$1" | while IFS= read -r ref; do
    name="${ref#"$1"}"
    body="$("${LOOKGIT[@]}" show "$ref:requests/$name.md" 2>/dev/null || true)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$(fget_str "$body" Status)" "$(fget_str "$body" From)" \
      "$(fget_str "$body" Date)" "$(printf '%s\n' "$body" | sed -n '1s/^# *//p')"
  done
}

ROWS=""; QROWS=""; RROWS=""; SRC=""
load_rows() { # [PREFIX] : fill ROWS, QROWS, RROWS from the board, else from the claims
  local pfx="${1:-}" tip gen age max n cache url
  ROWS=""; QROWS=""; RROWS=""; SRC=""
  tip="$(remote_tip board)"
  if [ -n "$tip" ] && fetch_branch board; then
    ROWS="$(Q show "refs/remotes/origin/board:BOARD.tsv" 2>/dev/null | sed '1,2d' | open_only || true)"
    QROWS="$(Q show "refs/remotes/origin/board:QUESTIONS.tsv" 2>/dev/null | sed '1d' || true)"
    RROWS="$(Q show "refs/remotes/origin/board:REQUESTS.tsv" 2>/dev/null | sed '1d' || true)"
    gen="$(Q show "refs/remotes/origin/board:BOARD.tsv" 2>/dev/null | sed -n '1s/^# generated_at: //p' || true)"
    age=$(( $(age_sec "$gen") / 60 ))
    SRC="board, generated $age min ago"
    max="$(setting coordination board_stale_minutes 30 DQ_BOARD_STALE_MINUTES)"
    if [ "$age" -gt "$max" ]; then note "The board is $age minutes old. Tell the harness team the board job may be stuck."; fi
    if [ -n "$pfx" ]; then ROWS="$(printf '%s\n' "$ROWS" | awk -F'\t' -v p="$pfx" 'index($1, p) == 1')"; fi
    return 0
  fi
  n="$(Q ls-remote origin "refs/heads/claim/${pfx}*" 2>/dev/null | wc -l | tr -d ' ')"
  max="$(setting coordination look_max_without_board 200 DQ_LOOK_MAX)"
  if [ "$n" -gt "$max" ]; then
    SRC="none ($n claims and no board)"
    note "There are $n claims and no board branch, so reading them all would be slow."
    note "Narrow it with: dq look --prefix PROJECT-   and ask the harness team to schedule: dq board --publish"
    return 0
  fi
  cache="$STATE_DIR/lookcache"; url="$(Q remote get-url origin)"
  mkdir -p "$STATE_DIR"
  if [ ! -d "$cache" ]; then git init -q --bare "$cache"; fi
  git --git-dir "$cache" fetch -q --depth=1 --prune "$url" \
    "+refs/heads/claim/${pfx}*:refs/claims/${pfx}*" "+refs/heads/request/*:refs/requests/*" 2>"$TMPERR" \
    || note "look: fetch problem: $(head -n1 "$TMPERR")"
  LOOKGIT=(git --git-dir "$cache")
  ROWS="$(claim_rows refs/claims/ | open_only)"
  QROWS="$(question_rows refs/claims/ | of_open_items "$ROWS")"
  RROWS="$(request_rows refs/requests/)"
  if [ -n "$pfx" ]; then ROWS="$(printf '%s\n' "$ROWS" | awk -F'\t' -v p="$pfx" 'index($1, p) == 1')"; fi
  SRC="claim branches read directly ($n; no board yet)"
}

show_rows() { # TSV rows on stdin; an optional last column is shown as WHY
  { printf 'KEY\tSTATE\tHOLD\tENGINEER\tSESSION\tLAST_BEAT\tREPOS\tFLOWS\tDEPENDS_ON\tWHY\n'
    awk -F'\t' 'function d(x) { return x == "" ? "-" : x }
      NF { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, d($3), d($4), d($5), d($6), d($8), d($12), d($14), d($15), d($20) }'
  } | fmt_table
}

near_rows() { # KEY : rows that share scope with KEY, or are linked to it
  local key="$1" me
  me="$(printf '%s\n' "$ROWS" | awk -F'\t' -v k="$key" '$1 == k')"
  if [ -z "$me" ] && [ -f "$(item_dir "$key")/claim.yaml" ]; then me="$(card_row "$key" < "$(item_dir "$key")/claim.yaml")"; fi
  if [ -z "$me" ]; then note "look: no card found for $key"; return 0; fi
  printf '%s\n' "$ROWS" | ME="$me" awk -F'\t' -v k="$key" '
    function has(list, item,   n, a, i) { n = split(list, a, /[ \t]*,[ \t]*/); for (i = 1; i <= n; i++) if (a[i] != "" && a[i] == item) return 1; return 0 }
    function share(l1, l2,   n, a, i) { n = split(l1, a, /[ \t]*,[ \t]*/); for (i = 1; i <= n; i++) if (a[i] != "" && has(l2, a[i])) return 1; return 0 }
    BEGIN { split(ENVIRON["ME"], m, "\t") }
    NF && $1 != k {
      why = ""
      if (share($12, m[12])) why = why "same-repo "
      if (share($13, m[13])) why = why "same-service "
      if (share($14, m[14])) why = why "same-flow "
      if (has(m[15], $1) || has($16, k)) why = why "you-depend-on-it "
      if (has(m[16], $1) || has($15, k)) why = why "it-depends-on-you "
      if ($11 != "" && $11 == m[11]) why = why "same-epic "
      if (why != "") { sub(/ $/, "", why); print $0 "\t" why }
    }'
}

cmd_look() {
  local near="" pfx="" all=0 to="" quiet=0 qr
  while [ $# -gt 0 ]; do
    case "$1" in
      --near) near="$2"; shift 2 ;;
      --prefix) pfx="$2"; shift 2 ;;
      --all) all=1; shift ;;
      --quiet) quiet=1; shift ;;
      --to) to="$2"; shift 2 ;;
      *) die "look: unknown option $1" ;;
    esac
  done
  need_queue
  load_rows "$pfx"
  local total stale cut mine nr q who
  total="$(printf '%s\n' "$ROWS" | awk 'NF' | wc -l | tr -d ' ')"
  echo "SOURCE=$SRC"
  echo "OPEN_CLAIMS=$total"
  if [ "$total" -gt 0 ]; then
    stale=$(( $(setting coordination session_stale_minutes 120 DQ_STALE_MINUTES) * 60 ))
    cut="$(from_epoch $(( $(date -u +%s) - stale )))"
    printf 'BY_STATE='; printf '%s\n' "$ROWS" | awk -F'\t' 'NF { c[$3]++ } END { for (s in c) printf "%s:%d ", s, c[s]; print "" }'
    printf 'ON_HOLD='; printf '%s\n' "$ROWS" | awk -F'\t' 'NF && $4 != "" && $4 != "none" { c[$4]++ } END { for (s in c) printf "%s:%d ", s, c[s]; print "" }'
    printf 'SILENT_SESSIONS='; printf '%s\n' "$ROWS" | awk -F'\t' -v cut="$cut" 'NF && $6 != "" && $8 < cut { n++ } END { print n + 0 }'
    printf 'FLAGGED_PROOFS='; printf '%s\n' "$ROWS" | awk -F'\t' 'NF && $17 != "" { n++ } END { print n + 0 }'
    qr="$(printf '%s\n' "$ROWS" | quiet_rows)"
    echo "QUIET_CLAIMS=$(printf '%s\n' "$qr" | awk 'NF' | wc -l | tr -d ' ')"
    if [ -n "$ENGINEER" ]; then
      mine="$(printf '%s\n' "$ROWS" | awk -F'\t' -v e="$ENGINEER" 'NF && $5 == e')"
      if [ -n "$mine" ]; then echo; echo "YOURS ($ENGINEER):"; printf '%s\n' "$mine" | show_rows; fi
    fi
    if [ -n "$near" ]; then
      nr="$(near_rows "$near")"
      echo; echo "NEAR $near:"
      if [ -n "$nr" ]; then printf '%s\n' "$nr" | show_rows; else echo "(nothing else shares its repos, services, flows or epic)"; fi
    fi
    if [ "$quiet" = 1 ]; then
      echo; echo "QUIET (no active session and no save for $(setting coordination claim_quiet_days 3 DQ_QUIET_DAYS) days or more):"
      if [ -n "$qr" ]; then printf '%s\n' "$qr" | show_rows; else echo "(none)"; fi
    fi
    if [ "$all" = 1 ]; then echo; echo "ALL:"; printf '%s\n' "$ROWS" | show_rows; fi
  fi
  who="${to:-$ENGINEER}"
  if [ -n "$who" ] && [ -n "$QROWS" ]; then
    q="$(printf '%s\n' "$QROWS" | awk -F'\t' -v w="$who" 'NF && index(tolower($3), tolower(w)) > 0')"
    if [ -n "$q" ]; then
      echo; echo "OPEN QUESTIONS FOR $who:"
      { printf 'KEY\tFILE\tTO\tBLOCKING\tASKED_BY\tASKED\n'; printf '%s\n' "$q"; } | fmt_table
    fi
  fi
  echo; lease_list brief
}

cmd_inbox() {
  local to=""
  while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; *) die "inbox: unknown option $1" ;; esac; done
  need_queue
  load_rows ""
  local who="${to:-$ENGINEER}" q
  q="$(printf '%s\n' "$QROWS" | awk -F'\t' -v w="$who" 'NF && (w == "" || index(tolower($3), tolower(w)) > 0)')"
  if [ -z "$q" ]; then echo "INBOX=empty"; return 0; fi
  { printf 'KEY\tFILE\tTO\tBLOCKING\tASKED_BY\tASKED\n'; printf '%s\n' "$q"; } | fmt_table
  note "Read a question with:  dq show KEY escalations/FILE"
}

cmd_done_check() {
  local key="${1:-}"; if [ $# -ge 1 ]; then shift; fi
  valid_key "$key"; need_queue
  local found=0 tip st name path br hits atlas repos=() line mine theirs
  echo "== queue =="
  tip="$(remote_tip "claim/$key")"
  if [ -n "$tip" ] && fetch_branch "claim/$key"; then
    st="$(Q show "$tip:items/$key/claim.yaml" 2>/dev/null | sed -n 's/^state:[ \t]*//p' | head -n1)"
    mine="$(cat "$(item_dir "$key")/.dq/session" 2>/dev/null || true)"
    theirs="$(Q show "$tip:items/$key/claim.yaml" 2>/dev/null | sed -n 's/^active_session:[ \t]*//p' | head -n1)"
    case " $CLOSED_STATES " in
      *" $st "*) echo "open claim: no (closed, state $st). Read it: dq show $key bundle/SUMMARY.md"; found=$(( found + 1 )) ;;
      *) if [ -n "$mine" ] && [ "$mine" = "$theirs" ]; then
           echo "open claim: yours (state $st), held by this session"
         else
           echo "open claim: yes (state $st). Someone already holds it: dq whois $key"; found=$(( found + 1 ))
         fi ;;
    esac
  else
    echo "open claim: no"
  fi
  fetch_branch "$DEFAULT" || note "could not fetch $DEFAULT"
  if Q cat-file -e "refs/remotes/origin/$DEFAULT:items/$key/claim.yaml" 2>/dev/null; then
    st="$(Q show "refs/remotes/origin/$DEFAULT:items/$key/claim.yaml" | sed -n 's/^state:[ \t]*//p' | head -n1)"
    echo "closed item on $DEFAULT: yes (state $st). Read items/$key/bundle/SUMMARY.md there."
    found=$(( found + 1 ))
  else
    echo "closed item on $DEFAULT: no"
  fi
  if Q cat-file -e "refs/remotes/origin/$DEFAULT:ready/$key.yaml" 2>/dev/null; then echo "ready contract: yes (ready/$key.yaml)"; else echo "ready contract: no"; fi
  echo "== code =="
  if [ $# -gt 0 ]; then
    for path in "$@"; do repos+=("$(basename "$path")	$path	"); done
  else
    while IFS= read -r line; do if [ -n "$line" ]; then repos+=("$line"); fi; done < <(config_repos)
  fi
  if [ "${#repos[@]}" -eq 0 ]; then echo "(no repos given and none in the config)"; fi
  for line in ${repos[@]+"${repos[@]}"}; do
    name="$(printf '%s' "$line" | cut -f1)"; path="$(printf '%s' "$line" | cut -f2)"; br="$(printf '%s' "$line" | cut -f3)"
    if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then echo "$name: not a git repo at $path"; continue; fi
    if [ -z "$br" ]; then br="$(repo_default "$path")"; fi
    git -C "$path" fetch -q origin "+refs/heads/$br:refs/remotes/origin/$br" 2>/dev/null || true
    hits="$(git -C "$path" log "origin/$br" --oneline -n 5 -E -i --grep="(^|[^A-Za-z0-9])$key([^0-9]|\$)" 2>/dev/null || true)"
    if [ -n "$hits" ]; then
      echo "$name: commits on $br that mention $key:"; printf '%s\n' "$hits" | sed 's/^/    /'
      found=$(( found + 1 ))
    else
      echo "$name: no commits on $br mention $key"
    fi
    hits="$(git -C "$path" ls-remote origin "refs/heads/*$key*" 2>/dev/null | awk '{ sub("refs/heads/", "", $2); print $2 }')"
    if [ -n "$hits" ]; then echo "$name: remote branches for $key:"; printf '%s\n' "$hits" | sed 's/^/    /'; found=$(( found + 1 )); fi
  done
  echo "== atlas =="
  atlas="$(yget2 "$CONFIG" atlas path)"
  if [ -n "$atlas" ] && [ -d "$atlas" ]; then
    hits="$(grep -rIlE --exclude-dir=.git -- "(^|[^A-Za-z0-9])$key([^0-9]|\$)" "$atlas" 2>/dev/null | head -n 10 || true)"
    if [ -n "$hits" ]; then echo "pages that mention $key:"; printf '%s\n' "$hits" | sed 's/^/    /'; found=$(( found + 1 )); else echo "no page mentions $key"; fi
  else
    echo "(atlas.path is not set in the config)"
  fi
  echo "== still for you to check =="
  echo "- Jira: status, resolution, linked and duplicate issues"
  echo "- Near-duplicates: the same work under another key (search Jira, the board, git log by keyword)"
  echo "- Atlas: a decision or agreed flow that already describes the behaviour"
  echo "- The product: drive the flow in a spotlight and see whether it already behaves as asked"
  echo "FINDINGS=$found"
}

cmd_overlap() {
  local key="${1:-}" repo="${2:-}"
  valid_key "$key"
  [ -n "$repo" ] || die "usage: dq overlap KEY REPO_PATH [OTHER_KEY...]"
  shift 2
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $repo"
  local br mine minefiles others other ref base files common any=0
  br="$(repo_default "$repo")"
  git -C "$repo" fetch -q origin "+refs/heads/$br:refs/remotes/origin/$br" 2>/dev/null || true
  if git -C "$repo" show-ref -q --verify "refs/heads/item/$key"; then mine="item/$key"
  elif git -C "$repo" show-ref -q --verify "refs/remotes/origin/item/$key"; then mine="origin/item/$key"
  else die "no item/$key branch in $repo"; fi
  minefiles="$(mktemp)"; files="$(mktemp)"
  git -C "$repo" diff --name-only "$(git -C "$repo" merge-base "origin/$br" "$mine")" "$mine" | sort -u > "$minefiles"
  echo "YOUR_FILES=$(wc -l < "$minefiles" | tr -d ' ')"
  if [ $# -gt 0 ]; then others="$*"
  else others="$(git -C "$repo" ls-remote origin 'refs/heads/item/*' 2>/dev/null | awk '{ sub("refs/heads/item/", "", $2); print $2 }')"; fi
  for other in $others; do
    if [ "$other" = "$key" ]; then continue; fi
    ref="refs/remotes/origin/item/$other"
    git -C "$repo" fetch -q origin "+refs/heads/item/$other:$ref" 2>/dev/null || continue
    if git -C "$repo" merge-base --is-ancestor "$ref" "origin/$br" 2>/dev/null; then continue; fi
    base="$(git -C "$repo" merge-base "origin/$br" "$ref" 2>/dev/null || true)"
    if [ -z "$base" ]; then continue; fi
    git -C "$repo" diff --name-only "$base" "$ref" | sort -u > "$files"
    common="$(comm -12 "$minefiles" "$files")"
    if [ -n "$common" ]; then
      any=1
      echo "OVERLAP_WITH=$other"
      printf '%s\n' "$common" | sed 's/^/    /'
    fi
  done
  rm -f "$minefiles" "$files"
  if [ "$any" = 0 ]; then echo "OVERLAP=none"; else
    note "Talk to the owners of those items before a track run. Record the dependency:"
    note "  dq beat $key -s SESSION --set depends_on=OTHERKEY   (or blocks=OTHERKEY)"
  fi
}

# ------------------------------------------------------------------ leases

L_TIP=""; L_HOLDER=""; L_SESSION=""; L_ENGINEER=""; L_EXPIRES=""
lease_read() { # TRACK
  local c=""
  L_TIP="$(remote_tip "lease/$1")"; L_HOLDER=""; L_SESSION=""; L_ENGINEER=""; L_EXPIRES=""
  if [ -n "$L_TIP" ]; then
    fetch_branch "lease/$1" || die "cannot fetch lease/$1"
    c="$(Q show "$L_TIP:lease.yaml" 2>/dev/null || true)"
    L_HOLDER="$(fget_str "$c" holder)"; L_SESSION="$(fget_str "$c" session)"
    L_ENGINEER="$(fget_str "$c" engineer)"; L_EXPIRES="$(fget_str "$c" expires_at)"
  fi
}
lease_is_free() { # after lease_read
  if [ -z "$L_HOLDER" ] || [ "$L_HOLDER" = none ]; then return 0; fi
  if [ "$(age_sec "$L_EXPIRES")" -gt 0 ]; then return 0; fi
  return 1
}
active_session_of() { # KEY -> the active session on the item's card, or empty
  local tip
  tip="$(remote_tip "claim/$1")"
  if [ -z "$tip" ]; then return 0; fi
  fetch_branch "claim/$1" || return 0
  Q show "$tip:items/$1/claim.yaml" 2>/dev/null | sed -n 's/^active_session:[ \t]*//p' | head -n1
}
# A lease belongs to its item. The session that took it may act on it, and
# so may whichever session is now active on that item.
lease_is_mine() { # KEY SESSION (after lease_read)
  if [ -n "$L_SESSION" ] && [ "$L_SESSION" = "$2" ]; then return 0; fi
  if [ -n "$L_HOLDER" ] && [ "$L_HOLDER" != none ] && [ "$L_HOLDER" = "$1" ] && [ "$(active_session_of "$1")" = "$2" ]; then return 0; fi
  return 1
}
lease_tracks() { # configured names plus any lease branch on the remote
  { csv_norm "$(setting tracks names "" DQ_TRACKS)"
    Q ls-remote origin 'refs/heads/lease/*' 2>/dev/null | awk '{ sub("refs/heads/lease/", "", $2); print $2 }'
  } | sort -u
}
lease_list() { # [brief]
  local t st any=0
  echo "TRACKS:"
  { printf 'TRACK\tSTATUS\tITEM\tENGINEER\tSESSION\tEXPIRES\n'
    for t in $(lease_tracks); do
      any=1; lease_read "$t"
      if [ -z "$L_HOLDER" ] || [ "$L_HOLDER" = none ]; then st=free
      elif [ "$(age_sec "$L_EXPIRES")" -gt 0 ]; then st=expired
      else st=held; fi
      if [ "$st" = free ]; then printf '%s\tfree\t-\t-\t-\t-\n' "$t"
      else printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$st" "${L_HOLDER:--}" "${L_ENGINEER:--}" "${L_SESSION:--}" "${L_EXPIRES:--}"; fi
    done
    if [ "$any" = 0 ]; then printf '(none configured: set tracks.names)\t\t\t\t\t\n'; fi
  } | fmt_table
  if [ "${1:-}" != brief ] && [ -n "$ROWS" ]; then
    local w; w="$(printf '%s\n' "$ROWS" | awk -F'\t' 'NF && $4 == "waiting-track" { print $18 "\t" $1 "\t" $5 }' | sort)"
    if [ -n "$w" ]; then echo "WAITING FOR A TRACK (longest first):"; { printf 'SINCE\tITEM\tENGINEER\n'; printf '%s\n' "$w"; } | fmt_table; fi
  fi
}
cmd_lease() {
  local sub="${1:-list}"; if [ $# -ge 1 ]; then shift; fi
  need_queue
  local method track key sess minutes t tmp commit exp
  case "$sub" in
    list) load_rows "" 2>/dev/null || true; lease_list ;;
    take)
      track="${1:-}"; key="${2:-}"; if [ $# -ge 2 ]; then shift 2; else shift $#; fi
      sess=""; minutes="$(setting tracks lease_minutes 90 DQ_LEASE_MINUTES)"
      while [ $# -gt 0 ]; do
        case "$1" in -s|--session) sess="$2"; shift 2 ;; --minutes) minutes="$2"; shift 2 ;; *) die "lease take: unknown option $1" ;; esac
      done
      [ -n "$track" ] && [ -n "$key" ] && [ -n "$sess" ] || die "usage: dq lease take TRACK|any KEY -s SESSION [--minutes N]"
      valid_key "$key"; need_me; ensure_identity
      method="$(setting tracks lease_method branch DQ_LEASE_METHOD)"
      if [ "$method" != branch ]; then
        echo "LEASE=not-available"
        note "Tracks here are leased by '$method', not by branch. Ask the engineer or the track"
        note "coordinator for a track, and write the answer in the journal. See COORDINATE.txt, 'Tracks'."
        exit 5
      fi
      if [ "$track" = any ]; then track="$(lease_tracks)"; [ -n "$track" ] || die "no tracks are configured (tracks.names)"; fi
      tmp="$(mktemp)"
      for t in $track; do
        lease_read "$t"
        if lease_is_free || lease_is_mine "$key" "$sess"; then
          exp="$(from_epoch $(( $(date -u +%s) + minutes * 60 )))"
          printf 'track: %s\nholder: %s\nsession: %s\nengineer: %s\ntaken_at: %s\nexpires_at: %s\n' \
            "$t" "$key" "$sess" "$ENGINEER" "$(now)" "$exp" > "$tmp"
          commit="$(commit_files "$L_TIP" "lease $t for $key" lease.yaml "$tmp")"
          if push_commit "$commit" "lease/$t"; then
            rm -f "$tmp"
            echo "LEASE=$t"; echo "EXPIRES_AT=$exp"
            note "Release it the moment you have results: dq lease release $t -s $sess"
            return 0
          fi
        fi
      done
      rm -f "$tmp"
      echo "LEASE=none-free"
      lease_list brief
      note "No track is free. Mark the item as waiting so others can see the queue:"
      note "  dq beat $key -s $sess --hold waiting-track --reason \"no free track\""
      exit 3
      ;;
    release)
      track="${1:-}"; if [ $# -ge 1 ]; then shift; fi
      sess=""
      while [ $# -gt 0 ]; do case "$1" in -s|--session) sess="$2"; shift 2 ;; *) die "lease release: unknown option $1" ;; esac; done
      [ -n "$track" ] && [ -n "$sess" ] || die "usage: dq lease release TRACK -s SESSION"
      need_me; ensure_identity
      lease_read "$track"
      if lease_is_free; then echo "LEASE=already-free"; return 0; fi
      if ! lease_is_mine "$L_HOLDER" "$sess"; then echo "NOT_YOURS=$track"; echo "HELD_BY=$L_SESSION"; echo "ITEM=$L_HOLDER"; exit 4; fi
      tmp="$(mktemp)"
      printf 'track: %s\nholder: none\nsession:\nengineer:\nlast_holder: %s (%s)\nreleased_at: %s\nexpires_at:\n' \
        "$track" "$L_HOLDER" "$sess" "$(now)" > "$tmp"
      commit="$(commit_files "$L_TIP" "release $track" lease.yaml "$tmp")"
      rm -f "$tmp"
      push_commit "$commit" "lease/$track" || die "could not release $track: $(head -n1 "$TMPERR")"
      echo "LEASE=released $track"
      ;;
    *) die "usage: dq lease list | take TRACK|any KEY -s SESSION [--minutes N] | release TRACK -s SESSION" ;;
  esac
}

# One spotlight fits in a workspace, so sessions on one machine take turns.
cmd_spot() {
  local sub="${1:-status}"; if [ $# -ge 1 ]; then shift; fi
  local lock="$STATE_DIR/locks/spotlight" key="" sess="" stale hs hk
  while [ $# -gt 0 ]; do
    case "$1" in -s|--session) sess="$2"; shift 2 ;; -*) die "spot: unknown option $1" ;; *) key="$1"; shift ;; esac
  done
  stale=$(( $(setting coordination spot_stale_minutes 60 DQ_SPOT_STALE_MINUTES) * 60 ))
  hs="$(sed -n 's/^session: //p' "$lock/info" 2>/dev/null || true)"
  hk="$(sed -n 's/^item: //p' "$lock/info" 2>/dev/null || true)"
  case "$sub" in
    status)
      if [ -d "$lock" ]; then echo "SPOTLIGHT=busy"; echo "HELD_BY=$hs"; echo "ITEM=$hk"; echo "IDLE_MIN=$(( $(file_age_sec "$lock/info") / 60 ))"
      else echo "SPOTLIGHT=free"; fi ;;
    take)
      [ -n "$key" ] && [ -n "$sess" ] || die "usage: dq spot take KEY -s SESSION"
      mkdir -p "$STATE_DIR/locks"
      if ! mkdir "$lock" 2>/dev/null; then
        if [ "$hs" = "$sess" ]; then :
        elif [ "$(file_age_sec "$lock/info")" -gt "$stale" ] && mv "$lock" "$lock.old.$$" 2>/dev/null && mkdir "$lock" 2>/dev/null; then
          rm -rf "$lock.old.$$"; note "took over a spotlight lock that $hs left idle"
        else
          echo "SPOTLIGHT=busy"; echo "HELD_BY=$hs"; echo "ITEM=$hk"
          note "Another session on this machine is using the spotlight. Do work that does not need it, then try again."
          exit 3
        fi
      fi
      printf 'session: %s\nitem: %s\nsince: %s\n' "$sess" "$key" "$(now)" > "$lock/info"
      echo "SPOTLIGHT=yours" ;;
    release)
      [ -n "$sess" ] || die "usage: dq spot release -s SESSION"
      if [ ! -d "$lock" ]; then echo "SPOTLIGHT=free"; return 0; fi
      if [ "$hs" != "$sess" ]; then echo "NOT_YOURS=spotlight"; echo "HELD_BY=$hs"; exit 4; fi
      rm -rf "$lock"; echo "SPOTLIGHT=free" ;;
    *) die "usage: dq spot status | take KEY -s SESSION | release -s SESSION" ;;
  esac
}

# ------------------------------------------------------------------ system

# Scripts are not kept in git. Each lives as a code block under a "## <path>"
# heading in script-instructions/*.md, and this writes them out. Each file is
# written beside its target and moved into place, so a running dq is not
# overwritten under itself.
cmd_generate() {
  local tmp f n=0 prog
  [ -d "$SYSTEM_DIR/script-instructions" ] || die "no script-instructions directory in $SYSTEM_DIR"
  prog="$(cat <<'AWK'
/^## / && !f { n = split(substr($0, 4), P, " "); next }
/^````/ { if (f) { f = 0; for (i = 1; i <= n; i++) close(P[i]); n = 0 }
          else if (n) { f = 1; for (i = 1; i <= n; i++) { system("mkdir -p \"$(dirname " P[i] ")\""); printf "" > P[i] } }
          next }
f { for (i = 1; i <= n; i++) print > P[i] }
AWK
)"
  tmp="$(mktemp -d)"
  ( cd "$tmp" && awk "$prog" "$SYSTEM_DIR"/script-instructions/*.md ) || { rm -rf "$tmp"; die "could not generate the scripts"; }
  while IFS= read -r f; do
    f="${f#./}"
    mkdir -p "$SYSTEM_DIR/$(dirname "$f")"
    chmod +x "$tmp/$f"
    mv -f "$tmp/$f" "$SYSTEM_DIR/$f.new.$$" && mv -f "$SYSTEM_DIR/$f.new.$$" "$SYSTEM_DIR/$f"
    echo "GENERATED=$f"
    n=$(( n + 1 ))
  done < <(cd "$tmp" && find . -type f | sort)
  rm -rf "$tmp"
  echo "SCRIPTS=$n"
}

cmd_version() {
  local check=0 pull=0 a v top b rel latest
  for a in "$@"; do case "$a" in --check) check=1 ;; --pull) check=1; pull=1 ;; *) die "version: unknown option $a" ;; esac; done
  v="$(cat "$SYSTEM_DIR/VERSION" 2>/dev/null || echo unknown)"
  echo "DQ=$DQ_VERSION"
  echo "VERSION=$v"
  if [ "$v" != unknown ] && [ "$v" != "$DQ_VERSION" ]; then
    echo "TOOL=stale"
    note "This dq ($DQ_VERSION) does not match the manual ($v). Run: dq generate"
  fi
  if [ "$check" = 0 ]; then return 0; fi
  top="$(git -C "$SYSTEM_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$top" ]; then
    echo "STATUS=unmanaged"
    note "This copy of the delivery system is not a git checkout, so it cannot be checked for updates."
    note "Use the copy in the shared repo, so every session reads the same manual."
    return 0
  fi
  b="$(git -C "$top" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null | sed 's#^origin/##' || true)"
  if [ -z "$b" ]; then b="$(git -C "$top" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"; fi
  if [ -z "$b" ]; then b="main"; fi
  if ! git -C "$top" fetch -q origin "+refs/heads/$b:refs/remotes/origin/$b" 2>"$TMPERR"; then
    echo "STATUS=unknown"; note "could not reach the remote to look for a newer version"; return 0
  fi
  rel="$(git -C "$SYSTEM_DIR" rev-parse --show-prefix)"
  latest="$(git -C "$top" show "origin/$b:${rel}VERSION" 2>/dev/null || true)"
  echo "LATEST=${latest:-unknown}"
  if [ -z "$latest" ] || [ "$latest" = "$v" ]; then echo "STATUS=current"; return 0; fi
  echo "STATUS=behind"
  if [ "$pull" = 1 ]; then
    if git -C "$top" merge -q --ff-only "origin/$b" 2>"$TMPERR"; then
      echo "UPDATED_TO=$(cat "$SYSTEM_DIR/VERSION" 2>/dev/null || echo unknown)"
      if [ -d "$SYSTEM_DIR/script-instructions" ]; then cmd_generate; fi
      note "Read $SYSTEM_DIR/CHANGELOG.txt for what changed, then re-read the parts it names."
    else
      note "could not fast-forward: $(head -n1 "$TMPERR"). Tell the engineer."
    fi
  else
    note "A newer manual exists ($latest). Run: dq version --pull"
  fi
}

cmd_doctor() {
  local ok=1 v
  echo "system dir:   $SYSTEM_DIR (version $(cat "$SYSTEM_DIR/VERSION" 2>/dev/null || echo unknown))"
  echo "bash:         ${BASH_VERSION}"
  echo "git:          $(git --version | awk '{ print $3 }')"
  if have_py; then echo "python3:      $(python3 --version 2>&1 | awk '{ print $2 }')"; else echo "python3:      MISSING (proof checks, hooks and settings merge are limited)"; fi
  echo "config:       ${CONFIG:-NOT FOUND (run setup: manual/SETUP.txt)}"
  echo "environment:  $(if [ -f "$ENVFILE" ]; then echo "$ENVFILE"; else echo "NOT FOUND ($ENVFILE)"; fi)"
  echo "workspace:    $WORKSPACE"
  echo "engineer:     ${ENGINEER:-NOT SET}"
  echo "machine:      $MACHINE"
  if [ -z "$ENGINEER" ]; then ok=0; fi
  if [ -n "$QUEUE" ] && git -C "$QUEUE" rev-parse --git-dir >/dev/null 2>&1; then
    need_queue
    if Q ls-remote origin "refs/heads/$DEFAULT" >/dev/null 2>&1; then echo "queue:        $QUEUE (remote reachable, default branch $DEFAULT)"
    else echo "queue:        $QUEUE (REMOTE NOT REACHABLE)"; ok=0; fi
    if [ -n "$(Q ls-remote origin refs/heads/board 2>/dev/null)" ]; then echo "board:        yes"; else echo "board:        none yet (dq look reads claims directly)"; fi
    v="$(setting tracks names "" DQ_TRACKS)"; echo "tracks:       ${v:-none configured} (lease method: $(setting tracks lease_method branch DQ_LEASE_METHOD))"
  else
    echo "queue:        NOT SET or not a git repo (${QUEUE:-empty})"; ok=0
  fi
  if [ "$ok" = 1 ]; then echo "DOCTOR=ok"; else echo "DOCTOR=problems"; exit 1; fi
}

cmd_protect_check() {
  need_queue; need_me; ensure_identity
  local br="claim/_smoke-$ENGINEER" tip a b f
  f="$(mktemp)"
  tip="$(remote_tip "$br")"
  if [ -n "$tip" ]; then fetch_branch "$br" || die "cannot fetch $br"; fi
  printf 'smoke %s %s\n' "$(now)" "$RANDOM$RANDOM" > "$f"
  a="$(commit_files "$tip" "protect-check: first writer" smoke.txt "$f")"
  if ! push_commit "$a" "$br"; then
    rm -f "$f"; echo "CREATE=refused"; echo "RESULT=fail"
    note "This account cannot push $br: $(head -n1 "$TMPERR")"
    note "Sessions cannot claim work until they may push to claim/*. Ask the repo admin."
    exit 1
  fi
  echo "CREATE=ok"
  printf 'smoke sibling %s %s\n' "$(now)" "$RANDOM$RANDOM" > "$f"
  b="$(commit_files "$tip" "protect-check: second writer" smoke.txt "$f")"
  rm -f "$f"
  if push_commit "$b" "$br"; then
    echo "SECOND_PUSH=accepted"; echo "RESULT=fail"
    note "The server accepted a second, conflicting push. Claims are not safe here."
    exit 1
  fi
  echo "SECOND_PUSH=rejected"
  # The only force-push dq ever attempts: a deliberate test on a throwaway branch.
  if Q push -q --force origin "$b:refs/heads/$br" 2>"$TMPERR"; then
    echo "FORCE_PUSH=accepted"; echo "RESULT=warn"
    note "The server let a force-push overwrite $br, so a claim could be overwritten."
    note "Ask the repo admin to protect claim/* and lease/* : allow push, forbid force-push."
    return 0
  fi
  echo "FORCE_PUSH=rejected"; echo "RESULT=pass"
}

push_one_file() { # BRANCH PATH LOCALFILE MSG : create or fast-forward a small branch
  local br="$1" path="$2" file="$3" msg="$4" tip commit try
  for try in 1 2 3; do
    tip="$(remote_tip "$br")"
    if [ -n "$tip" ]; then fetch_branch "$br" || die "cannot fetch $br"; fi
    commit="$(commit_files "$tip" "$msg" "$path" "$file")"
    if [ "$commit" = "$tip" ] || push_commit "$commit" "$br"; then return 0; fi
    sleep 1
  done
  die "could not push $br: $(head -n1 "$TMPERR")"
}
cmd_publish_config() {
  need_queue; need_me; ensure_identity
  [ -n "$CONFIG" ] && [ -f "$CONFIG" ] || die "no delivery.config.yaml found"
  push_one_file "config/$ENGINEER/$MACHINE" "configs/$ENGINEER/$MACHINE/delivery.config.yaml" "$CONFIG" "config of $ENGINEER on $MACHINE"
  echo "PUBLISHED=config/$ENGINEER/$MACHINE"
}
cmd_configs() {
  need_queue
  local which="${1:-}"
  if [ -z "$which" ]; then
    Q ls-remote origin 'refs/heads/config/*' 2>/dev/null | awk '{ sub("refs/heads/config/", "", $2); print $2 }'
    return 0
  fi
  fetch_branch "config/$which" || die "no published config for $which"
  Q show "refs/remotes/origin/config/$which:configs/$which/delivery.config.yaml"
}
cmd_request() {
  local name="${1:-}" file="${2:-}"
  [ -n "$name" ] && [ -f "${file:-/nonexistent}" ] || die "usage: dq request SLUG FILE   (start FILE from templates/request.md)"
  need_queue; need_me; ensure_identity
  name="$ENGINEER-$(slug "$name")"
  push_one_file "request/$name" "requests/$name.md" "$file" "request: $name"
  echo "REQUESTED=request/$name"
  note "The harness team sees it on the board. Carry on with what you can do meanwhile."
}

cmd_board() {
  local publish=0 out="" d f tip commit t
  while [ $# -gt 0 ]; do
    case "$1" in --publish) publish=1; shift ;; --out) out="$2"; shift 2 ;; *) die "board: unknown option $1" ;; esac
  done
  need_queue; ensure_identity
  Q fetch -q --prune origin '+refs/heads/claim/*:refs/remotes/origin/claim/*' \
    '+refs/heads/request/*:refs/remotes/origin/request/*' 2>"$TMPERR" || die "cannot fetch claims: $(head -n1 "$TMPERR")"
  LOOKGIT=(git -C "$QUEUE")
  d="$(mktemp -d)"
  { printf '# generated_at: %s\n' "$(now)"; printf '%s\n' "$BOARD_HEADER"; claim_rows refs/remotes/origin/claim/ | open_only | sort; } > "$d/BOARD.tsv"
  { printf 'key\tfile\tto\tblocking\tasked_by\tasked\n'; question_rows refs/remotes/origin/claim/ | of_open_items "$(sed '1,2d' "$d/BOARD.tsv")"; } > "$d/QUESTIONS.tsv"
  { printf 'request\tstatus\tfrom\tdate\ttitle\n'; request_rows refs/remotes/origin/request/; } > "$d/REQUESTS.tsv"
  { printf 'track\tholder\tengineer\tsession\texpires_at\n'
    for t in $(lease_tracks); do lease_read "$t"; printf '%s\t%s\t%s\t%s\t%s\n' "$t" "${L_HOLDER:-none}" "$L_ENGINEER" "$L_SESSION" "$L_EXPIRES"; done
  } > "$d/LEASES.tsv"
  { echo "# Delivery board"; echo
    echo "Generated $(now). $(sed '1,2d' "$d/BOARD.tsv" | awk 'NF' | wc -l | tr -d ' ') open items."; echo
    echo "| Item | State | Hold | Engineer | Active session | Last heartbeat | Repos | Flows | Flag |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    sed '1,2d' "$d/BOARD.tsv" | awk -F'\t' 'NF { printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $3, $4, $5, $6, $8, $12, $14, $17 }'
    echo; echo "## Quiet claims"; echo
    echo "No active session and no save for $(setting coordination claim_quiet_days 3 DQ_QUIET_DAYS) days or more. The remit lead decides who takes each one over."; echo
    echo "| Item | State | Hold | Engineer | Last heartbeat | Remit |"; echo "| --- | --- | --- | --- | --- | --- |"
    sed '1,2d' "$d/BOARD.tsv" | quiet_rows | awk -F'\t' 'NF { printf "| %s | %s | %s | %s | %s | %s |\n", $1, $3, $4, $5, $8, $10 }'
    echo; echo "## Open questions"; echo
    echo "| Item | File | To | Blocking | Asked by | Asked |"; echo "| --- | --- | --- | --- | --- | --- |"
    sed '1d' "$d/QUESTIONS.tsv" | awk -F'\t' 'NF { printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6 }'
    echo; echo "## Tracks"; echo
    echo "| Track | Item | Engineer | Expires |"; echo "| --- | --- | --- | --- |"
    sed '1d' "$d/LEASES.tsv" | awk -F'\t' 'NF { printf "| %s | %s | %s | %s |\n", $1, $2, $3, $5 }'
    echo; echo "## Requests to the harness team"; echo
    echo "| Request | Status | From | Date | Title |"; echo "| --- | --- | --- | --- | --- |"
    sed '1d' "$d/REQUESTS.tsv" | awk -F'\t' 'NF { printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5 }'
  } > "$d/BOARD.md"
  if [ -n "$out" ]; then mkdir -p "$out"; cp "$d"/BOARD.tsv "$d"/QUESTIONS.tsv "$d"/REQUESTS.tsv "$d"/LEASES.tsv "$d"/BOARD.md "$out/"; echo "WRITTEN=$out"; fi
  if [ "$publish" = 1 ]; then
    tip="$(remote_tip board)"
    if [ -n "$tip" ]; then fetch_branch board || die "cannot fetch board"; fi
    commit="$(commit_files "$tip" "board $(now)" BOARD.tsv "$d/BOARD.tsv" QUESTIONS.tsv "$d/QUESTIONS.tsv" \
      REQUESTS.tsv "$d/REQUESTS.tsv" LEASES.tsv "$d/LEASES.tsv" BOARD.md "$d/BOARD.md")"
    push_commit "$commit" board || die "could not publish the board: $(head -n1 "$TMPERR")"
    echo "PUBLISHED=board"
  elif [ -z "$out" ]; then
    cat "$d/BOARD.md"
  fi
  rm -rf "$d"
}

cmd_install() {
  local ws="" a f name dest block tmp
  while [ $# -gt 0 ]; do case "$1" in --workspace) ws="$2"; shift 2 ;; *) die "install: unknown option $1" ;; esac; done
  if [ -z "$ws" ]; then ws="$WORKSPACE"; fi
  [ -d "$ws" ] || die "workspace not found: $ws"
  ws="$(cd "$ws" && pwd)"
  # 1. the always-loaded block, kept short
  block="$(sed "s#{{SYSTEM_DIR}}#$SYSTEM_DIR#g" "$SYSTEM_DIR/bootstrap/CLAUDE-block.md")"
  f="$ws/CLAUDE.md"; tmp="$(mktemp)"
  if [ -f "$f" ] && grep -q 'delivery-system:start' "$f"; then
    BLOCK="$block" awk '
      /delivery-system:start/ { print ENVIRON["BLOCK"]; skip = 1; next }
      /delivery-system:end/ { skip = 0; next }
      !skip { print }' "$f" > "$tmp"
  else
    { if [ -f "$f" ]; then cat "$f"; echo; fi; printf '%s\n' "$block"; } > "$tmp"
  fi
  cat "$tmp" > "$f"; rm -f "$tmp"
  echo "INSTALLED=$f (delivery block)"
  # 2. skills: thin pointers to the manual parts, loaded on demand
  for a in "$SYSTEM_DIR"/skills/*/SKILL.md; do
    if [ ! -f "$a" ]; then continue; fi
    name="$(basename "$(dirname "$a")")"; dest="$ws/.claude/skills/$name"
    mkdir -p "$dest"
    sed "s#{{SYSTEM_DIR}}#$SYSTEM_DIR#g" "$a" > "$dest/SKILL.md"
    echo "INSTALLED=$dest/SKILL.md"
  done
  # 3. hooks and permissions
  mkdir -p "$ws/.claude"
  if have_py; then
    python3 - "$ws/.claude/settings.json" "$SELF_DIR/dq" <<'PY'
import json, os, sys
path, dq = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        settings = json.load(fh)
except Exception:
    settings = {}
hooks = settings.setdefault("hooks", {})
def ensure(event, matcher, command):
    groups = hooks.setdefault(event, [])
    for group in groups:
        for hook in group.get("hooks", []):
            if hook.get("command") == command:
                return
    group = {"hooks": [{"type": "command", "command": command}]}
    if matcher:
        group["matcher"] = matcher
    groups.append(group)
ensure("PreToolUse", "Bash|Edit|Write", '"%s" hook-pretool' % dq)
ensure("Stop", None, '"%s" hook-stop' % dq)
perms = settings.setdefault("permissions", {})
def union(key, rules):
    current = perms.setdefault(key, [])
    for rule in rules:
        if rule not in current:
            current.append(rule)
union("allow", ["Bash(%s *)" % dq])
union("deny", [
    "Bash(git push --force*)", "Bash(git push -f *)", "Bash(git push * --force*)",
    "Bash(git push * -f)", "Bash(git push * -f *)", "Bash(git push --delete *)",
    "Bash(git push * --delete *)", "Bash(git push --mirror*)", "Bash(git push * --mirror*)",
])
with open(path, "w") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
print("INSTALLED=%s (hooks and permission rules)" % path)
PY
  else
    note "python3 is missing, so .claude/settings.json was not changed."
    note "Add the hooks and rules by hand from: $SYSTEM_DIR/bootstrap/settings.example.json"
  fi
  # 4. a config to fill in
  if [ ! -f "$ws/delivery.config.yaml" ] && [ -f "$SYSTEM_DIR/templates/delivery.config.yaml" ]; then
    cp "$SYSTEM_DIR/templates/delivery.config.yaml" "$ws/delivery.config.yaml"
    echo "INSTALLED=$ws/delivery.config.yaml (empty; setup fills it in)"
  fi
  note "Next: start Claude Code in $ws and say: start"
}

# Hooks. Claude Code passes the event as JSON on stdin. Exit 2 blocks, and
# the text on stderr is what Claude is told.
hook_block() { printf 'Blocked by the delivery rules: %s\n' "$1" >&2; exit 2; }
hook_ask() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
    "$(printf '%s' "$1" | sed 's/["\\]/\\&/g')"
  exit 0
}
cmd_hook_pretool() {
  local payload tool="" cmd="" path="" seg defaults pat b
  payload="$(cat)"
  if have_py; then
    { IFS= read -r -d '' tool; IFS= read -r -d '' cmd; IFS= read -r -d '' path; } < <(PAYLOAD="$payload" python3 -c 'import json, os, sys
try:
    data = json.loads(os.environ["PAYLOAD"])
except Exception:
    data = {}
tool_input = data.get("tool_input") or {}
sys.stdout.write("%s\0%s\0%s\0" % (data.get("tool_name", ""), tool_input.get("command", ""), tool_input.get("file_path", "")))') || true
  else
    cmd="$payload"
  fi
  if [ -n "$cmd" ]; then
    defaults="main|master"
    for b in "$DEFAULT" $(config_repos | cut -f3); do
      if [ -n "$b" ]; then defaults="$defaults|$(printf '%s' "$b" | sed 's/[.[\*^$()+?{|]/\\&/g')"; fi
    done
    while IFS= read -r seg; do
      if ! printf '%s' "$seg" | grep -Eq '(^|[^[:alnum:]_/.-])git([[:space:]]|$)'; then continue; fi
      if ! printf '%s' "$seg" | grep -Eq '[[:space:]]push([[:space:]]|$)'; then continue; fi
      if printf '%s' "$seg" | grep -Eq '[[:space:]](--force|--force-with-lease|--force-if-includes|-f|--mirror|--delete|-d)([[:space:]=]|$)'; then
        hook_block "a push that forces or deletes is never allowed (rule 10). If the remote moved, merge it in and push again."
      fi
      if printf '%s' "$seg" | grep -Eq '[[:space:]]\+[^[:space:]]'; then hook_block "a refspec starting with + is a force-push (rule 10)."; fi
      if printf '%s' "$seg" | grep -Eq '[[:space:]]:[^[:space:]]'; then hook_block "a refspec starting with : deletes a remote branch (rule 10)."; fi
      if printf '%s' "$seg" | grep -Eq "[[:space:]]([^[:space:]]*:)?(refs/heads/)?($defaults)([[:space:]]|\$)"; then
        hook_block "that pushes to a default branch (rule 10). Push your item/KEY branch and open a merge request."
      fi
    done < <(printf '%s\n' "$cmd" | sed -E 's/(&&|\|\||;|\|)/\n/g')
  fi
  if [ -n "$path" ] && [ "$tool" != Bash ]; then
    for pat in "$SYSTEM_DIR/*" "*/.gitlab-ci.yml" "*/.github/workflows/*" "*/Jenkinsfile" \
               $(csv_norm "$(setting guardrails protected_paths "" DQ_PROTECTED_PATHS)"); do
      # shellcheck disable=SC2254
      case "$path" in $pat) hook_ask "Protected path (rule 11): $path. Changing it needs the engineer's approval." ;; esac
    done
  fi
  exit 0
}
cmd_hook_stop() {
  local payload d key sess out w n br problems=""
  payload="$(cat)"
  case "$payload" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac
  if [ ! -d "$ITEMS_DIR" ]; then exit 0; fi
  for d in "$ITEMS_DIR"/*/; do
    if [ ! -f "${d}.dq/session" ]; then continue; fi
    key="$(basename "$d")"; sess="$(cat "${d}.dq/session")"
    if [ -f "${d}.dq/base" ] && [ -n "$(find "$d" -type f -newer "${d}.dq/base" ! -path '*/.dq/*' ! -name '*.remote' -print -quit 2>/dev/null)" ]; then
      problems="$problems
- $key: item files changed since the last save. Run: \"$SELF_DIR/dq\" beat $key -s $sess"
    fi
    if [ -f "${d}proofs.json" ] && have_py; then
      if ! out="$(proofs_py "${d}proofs.json" static all "${d%/}" 2>&1)"; then
        problems="$problems
- $key: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"
      fi
    fi
    for w in "$STATE_DIR/work/$key"/*/; do
      if [ ! -e "${w}.git" ]; then continue; fi
      if git -C "$w" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
        n="$(git -C "$w" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
      else
        br="$(repo_default "$w")"
        n="$(git -C "$w" rev-list --count "origin/$br..HEAD" 2>/dev/null || echo 0)"
      fi
      if [ "${n:-0}" -gt 0 ]; then
        problems="$problems
- $key: $n commit(s) in $(basename "$w") are not pushed. Run: \"$SELF_DIR/dq\" push $key -s $sess"
      fi
    done
  done
  if [ -z "$problems" ]; then exit 0; fi
  printf 'Before you stop, finish these (delivery rules 4 and 7):%s\n' "$problems" >&2
  exit 2
}

# -------------------------------------------------------------------- main

main() {
  local cmd="${1:-help}"
  if [ $# -ge 1 ]; then shift; fi
  case "$cmd" in help|-h|--help) usage; exit 0 ;; esac
  load_context
  case "$cmd" in
    look) cmd_look "$@" ;;
    whois) cmd_whois "$@" ;;
    show) cmd_show "$@" ;;
    done-check) cmd_done_check "$@" ;;
    overlap) cmd_overlap "$@" ;;
    inbox) cmd_inbox "$@" ;;
    configs) cmd_configs "$@" ;;
    claim) cmd_claim "$@" ;;
    take) cmd_take "$@" ;;
    beat) cmd_beat "$@" ;;
    push) cmd_push "$@" ;;
    release) cmd_release "$@" ;;
    state) cmd_state "$@" ;;
    freeze) cmd_freeze "$@" ;;
    path) cmd_path "$@" ;;
    new) cmd_new "$@" ;;
    check-proofs) cmd_check_proofs "$@" ;;
    evidence) cmd_evidence "$@" ;;
    work) cmd_work "$@" ;;
    lease) cmd_lease "$@" ;;
    spot) cmd_spot "$@" ;;
    version) cmd_version "$@" ;;
    generate) cmd_generate "$@" ;;
    doctor) cmd_doctor "$@" ;;
    install) cmd_install "$@" ;;
    protect-check) cmd_protect_check "$@" ;;
    publish-config) cmd_publish_config "$@" ;;
    request) cmd_request "$@" ;;
    board) cmd_board "$@" ;;
    hook-pretool) cmd_hook_pretool "$@" ;;
    hook-stop) cmd_hook_stop "$@" ;;
    *) die "unknown command: $cmd (try: dq help)" ;;
  esac
}
main "$@"
````
