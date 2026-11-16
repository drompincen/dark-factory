#!/usr/bin/env bash
# selftest.sh - exercises dq against throwaway local repositories.
#
# It builds a pretend server (bare repos) and three pretend machines in a
# temporary directory, then walks through claims, heartbeats, takeovers,
# leases, the board and the hooks. Nothing outside the temporary directory
# is touched. Run it once in a new environment to check that this git and
# this bash behave the way dq expects:
#
#     tools/selftest.sh          # prints one line per check
#     KEEP=1 tools/selftest.sh   # keep the temporary directory afterwards

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
if [ "${KEEP:-0}" = 1 ]; then echo "working in $T"; else trap 'rm -rf "$T"' EXIT; fi

export GIT_AUTHOR_NAME="selftest" GIT_AUTHOR_EMAIL="selftest@example.invalid"
export GIT_COMMITTER_NAME="selftest" GIT_COMMITTER_EMAIL="selftest@example.invalid"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset DELIVERY_CONFIG DQ_QUEUE DQ_ENGINEER DQ_MACHINE DQ_WORKSPACE DQ_STATE_DIR CLAUDE_PROJECT_DIR 2>/dev/null || true

PASS=0; FAIL=0; OUT=""; RC=0
ok()  { PASS=$(( PASS + 1 )); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$(( FAIL + 1 )); printf '  FAIL %s\n' "$1"; if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/       | /'; fi; }
run() { OUT="$("$@" 2>&1)"; RC=$?; }
want_rc()  { if [ "$RC" = "$2" ]; then ok "$1"; else bad "$1 (exit $RC, wanted $2)" "$OUT"; fi; }
want_out() { if printf '%s\n' "$OUT" | grep -Eq -- "$2"; then ok "$1"; else bad "$1 (no match for: $2)" "$OUT"; fi; }
want_no()  { if printf '%s\n' "$OUT" | grep -Eq -- "$2"; then bad "$1 (unexpected match for: $2)" "$OUT"; else ok "$1"; fi; }
want_file() { if [ -e "$2" ]; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
want_grep() { if grep -Eq -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 (no '$3' in $2)" "$(cat "$2" 2>/dev/null | head -n 20)"; fi; }
val() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -n1; }
section() { printf '\n%s\n' "$1"; }

# ----------------------------------------------------------- the pretend world

mkdir -p "$T/server"
for r in queue app system; do
  git init -q --bare "$T/server/$r.git"
  git -C "$T/server/$r.git" symbolic-ref HEAD refs/heads/main
done

# the shared system repo holds the delivery system under system/
git clone -q "$T/server/system.git" "$T/seed-system" 2>/dev/null
mkdir -p "$T/seed-system/system"
cp -R "$SRC"/. "$T/seed-system/system/"
cp "$SRC/environment.example.yaml" "$T/seed-system/system/environment.yaml"
( cd "$T/seed-system" && git checkout -q -b main 2>/dev/null; git add -A && git commit -q -m "delivery system" && git push -q origin main )

git clone -q "$T/server/queue.git" "$T/seed-queue" 2>/dev/null
( cd "$T/seed-queue" && git checkout -q -b main 2>/dev/null
  mkdir -p ready && printf 'key: PAY-2\ntitle: ready contract\n' > ready/PAY-2.yaml
  echo "queue" > README.md && git add -A && git commit -q -m "seed queue" && git push -q origin main )

git clone -q "$T/server/app.git" "$T/seed-app" 2>/dev/null
( cd "$T/seed-app" && git checkout -q -b main 2>/dev/null
  mkdir -p src && echo one > src/a.txt && echo two > src/b.txt
  git add -A && git commit -q -m "seed app" && git push -q origin main )

git clone -q "$T/server/system.git" "$T/sys"
DQ="$T/sys/system/tools/dq"
chmod +x "$DQ"

mk_machine() { # DIR ENGINEER MACHINE [EXTRA_YAML]
  local m="$T/$1"
  mkdir -p "$m"
  git clone -q --single-branch "$T/server/queue.git" "$m/queue"
  git clone -q "$T/server/app.git" "$m/app"
  mkdir -p "$m/atlas"
  cat > "$m/delivery.config.yaml" <<EOF
setup_complete: true
engineer:
  name: $2
workspace:
  root: $m
  machine: $3
queue:
  path: $m/queue
  default_branch: main
atlas:
  path: $m/atlas
repos:
  - name: app
    path: $m/app
    default_branch: main
tracks:
  names: track-01, track-02
  lease_method: ${4:-branch}
EOF
}
mk_machine m1 dana ws1
mk_machine m2 dana ws2
mk_machine m3 omar ws3
mk_machine m4 lena ws4 assigned

dq_m() { local m="$1"; shift; ( cd "$T/$m" && DELIVERY_CONFIG="$T/$m/delivery.config.yaml" "$DQ" "$@" ); }
item() { printf '%s/%s/.delivery/items/%s' "$T" "$1" "$2"; }
remote_card() { git -C "$T/server/queue.git" show "claim/$1:items/$1/claim.yaml" 2>/dev/null; }

# a person editing a claim branch from their own clone (an answer, a review)
person_edit() { # KEY FILE_IN_ITEM  (new content on stdin; "-a" as $3 appends)
  local key="$1" file="$2" mode="${3:-}" d="$T/person-$RANDOM"
  git clone -q --single-branch --branch "claim/$key" "$T/server/queue.git" "$d"
  mkdir -p "$(dirname "$d/items/$key/$file")"
  if [ "$mode" = "-a" ]; then cat >> "$d/items/$key/$file"; else cat > "$d/items/$key/$file"; fi
  ( cd "$d" && git add -A && git commit -q -m "person edits $file" && git push -q origin "claim/$key" )
  rm -rf "$d"
}

# --------------------------------------------------------------------- checks

section "environment"
run dq_m m1 doctor;                 want_rc "doctor passes on a configured workspace" 0
want_out "doctor reports the queue remote" 'remote reachable'
run dq_m m1 version;                want_out "version prints the manual version" '^VERSION=[0-9]'

section "claim first"
run dq_m m1 claim PAY-1 --kind story --epic PAY-100
want_rc "a free key can be claimed" 0
S1="$(val SESSION)"
want_out "claim prints a session id naming engineer and machine" '^SESSION=dana@ws1#[0-9a-f]{4}$'
want_file "claim creates the card" "$(item m1 PAY-1)/claim.yaml"
want_file "claim creates the journal from the template" "$(item m1 PAY-1)/journal.md"
want_grep "journal records who claimed" "$(item m1 PAY-1)/journal.md" 'Claimed by dana@ws1#'
OUT="$(remote_card PAY-1)"
want_out "the card on the server names the engineer" '^engineer: dana$'
want_out "the card names the machine" '^active_machine: ws1$'
want_out "the card has a heartbeat" '^heartbeat_at: 20[0-9-]+T[0-9:]+Z$'
want_out "the card starts at Draft" '^state: Draft$'
run dq_m m3 claim PAY-1;            want_rc "a second claim on the same key is refused" 3
want_out "the refusal names the holder" '^HELD_BY=dana$'
want_out "the refusal names the active session" '^ACTIVE_SESSION=dana@ws1#'

( dq_m m1 claim PAY-9 > "$T/race1.out" 2>&1 ) &
( dq_m m3 claim PAY-9 > "$T/race2.out" 2>&1 ) &
wait
n="$(cat "$T/race1.out" "$T/race2.out" | grep -c '^CLAIMED=PAY-9$')"
if [ "$n" = 1 ]; then ok "two sessions racing for one key: exactly one wins"; else bad "race produced $n winners" "$(cat "$T/race1.out" "$T/race2.out")"; fi
n="$(cat "$T/race1.out" "$T/race2.out" | grep -c '^TAKEN=PAY-9$')"
if [ "$n" = 1 ]; then ok "the loser of the race is told who holds it"; else bad "race produced $n losers" "$(cat "$T/race1.out" "$T/race2.out")"; fi

run dq_m m1 claim PAY-2;            want_out "a ready contract is copied into a new claim" '^CONTRACT=found'
S2="$(val SESSION)"
want_grep "the copied contract is the ready one" "$(item m1 PAY-2)/contract.yaml" 'ready contract'
run dq_m m1 claim 'bad key';        want_rc "a malformed key is refused" 1

section "heartbeat and saving"
run dq_m m3 whois PAY-1;            want_out "whois shows an active session" '^ACTIVE=yes$'
want_out "whois says another engineer may not take it" '^CAN_TAKE=no'
run dq_m m1 beat PAY-1 -s "dana@ws1#zzzz"; want_rc "a beat from the wrong session is refused" 4
run dq_m m1 beat PAY-1;             want_rc "a beat without a session is refused" 1
echo "2026 a line of journal" >> "$(item m1 PAY-1)/journal.md"
run dq_m m1 beat PAY-1 -s "$S1" --set repos=app --set flows=refund --set services=payments-api
want_rc "a beat saves and pushes" 0
want_out "beat reports the save" '^SAVED=PAY-1$'
OUT="$(remote_card PAY-1)"
want_out "scope set on the card reaches the server" '^repos: app$'
OUT="$(git -C "$T/server/queue.git" show claim/PAY-1:items/PAY-1/journal.md)"
want_out "journal changes reach the server" 'a line of journal'
run dq_m m1 beat PAY-1 -s "$S1" --set owner=someone; want_rc "only scope fields may be set by hand" 1

section "answers and conflicts"
run dq_m m1 new PAY-1 escalation --to "remit lead"
want_rc "an escalation file is created from its template" 0
want_file "escalations are numbered" "$(item m1 PAY-1)/escalations/PAY-1-1.md"
want_grep "the escalation is addressed" "$(item m1 PAY-1)/escalations/PAY-1-1.md" '^To: remit lead$'
run dq_m m1 beat PAY-1 -s "$S1";    want_rc "the question is pushed" 0
printf 'Use option B.\n' | person_edit PAY-1 escalations/PAY-1-1.md -a
echo "2026 another journal line" >> "$(item m1 PAY-1)/journal.md"
run dq_m m1 beat PAY-1 -s "$S1"
want_out "an answer committed by a person is merged into the local copy" '^MERGED_FROM_REMOTE=.*escalations/PAY-1-1.md'
want_grep "the answer text is now local" "$(item m1 PAY-1)/escalations/PAY-1-1.md" 'Use option B'
OUT="$(git -C "$T/server/queue.git" show claim/PAY-1:items/PAY-1/journal.md)"
want_out "the session's own change survives the merge" 'another journal line'
printf '# rewritten by a person\n' | person_edit PAY-1 journal.md
echo "2026 a third local line" >> "$(item m1 PAY-1)/journal.md"
run dq_m m1 beat PAY-1 -s "$S1"
want_out "a file changed on both sides is reported as a conflict" '^CONFLICTS=journal.md$'
want_file "the other version is kept beside the local one" "$(item m1 PAY-1)/journal.md.remote"
OUT="$(git -C "$T/server/queue.git" show claim/PAY-1:items/PAY-1/journal.md)"
want_out "the local version is the one that is pushed" 'a third local line'
OUT="$(git -C "$T/server/queue.git" ls-tree -r --name-only claim/PAY-1)"
want_no "conflict copies are never pushed" '\.remote$'
want_no "local bookkeeping is never pushed" '\.dq/'
rm -f "$(item m1 PAY-1)/journal.md.remote"

section "active session, takeover and handover"
run dq_m m2 take PAY-1;             want_rc "a second machine cannot take an item with a live session" 3
want_out "the refusal says it is active elsewhere" '^ACTIVE_ELSEWHERE=PAY-1$'
run dq_m m3 take PAY-1 --from dana --reason "trying"; want_rc "another engineer cannot take a live session either" 3
run dq_m m2 take PAY-1 --replace-mine "ws1 was rebuilt"
want_rc "the same engineer can replace their own lost session" 0
S1B="$(val SESSION)"
want_out "the new session is on the second machine" '^SESSION=dana@ws2#'
want_file "the item's files are rebuilt on the second machine" "$(item m2 PAY-1)/journal.md"
want_grep "the rebuilt journal has the latest content" "$(item m2 PAY-1)/journal.md" 'a third local line'
run dq_m m1 beat PAY-1 -s "$S1";    want_rc "the replaced session is stopped at its next beat" 4
want_out "it is told it is no longer active" '^NOT_ACTIVE=PAY-1$'
run dq_m m2 release PAY-1 -s "$S1B" --hold parked --reason "waiting for an answer"
want_rc "the active session can release" 0
OUT="$(remote_card PAY-1)"
want_out "release clears the active session" '^active_session:$'
want_out "release records the hold" '^hold: parked$'
want_out "release keeps the claim with its engineer" '^engineer: dana$'
run dq_m m3 whois PAY-1;            want_out "whois shows no active session after release" '^ACTIVE=no$'
run dq_m m3 take PAY-1;             want_rc "another engineer needs a handover to take it" 3
want_out "the refusal names the owner" '^OWNED_BY=dana$'
run dq_m m3 take PAY-1 --from dana --reason "dana is out; lead agreed"
want_rc "a handover with a reason succeeds" 0
S1C="$(val SESSION)"
OUT="$(remote_card PAY-1)"
want_out "the handover changes the engineer" '^engineer: omar$'
want_out "the handover records the previous holder" '^previous_holders: dana until .*lead agreed'
want_grep "the handover is in the item history" "$(item m3 PAY-1)/history.log" 'handover from dana to omar'

run dq_m m1 claim PAY-3;            S3="$(val SESSION)"
run env DQ_STALE_MINUTES=0 bash -c "cd '$T/m2' && DELIVERY_CONFIG='$T/m2/delivery.config.yaml' '$DQ' take PAY-3"
want_rc "a silent session can be taken over by the same engineer" 0
S3B="$(val SESSION)"
run dq_m m1 claim PAY-5;            S5="$(val SESSION)"
run env DQ_STALE_MINUTES=0 bash -c "cd '$T/m3' && DELIVERY_CONFIG='$T/m3/delivery.config.yaml' '$DQ' take PAY-5"
want_rc "a silent session still needs a handover for another engineer" 3

section "states need evidence"
D3="$(item m2 PAY-3)"
run dq_m m2 state PAY-3 -s "$S3B" Claimed;      want_rc "Claimed is refused without a contract" 6
run dq_m m2 new PAY-3 contract;                 want_rc "a contract is created from its template" 0
run dq_m m2 new PAY-3 contract;                 want_rc "an existing contract is not overwritten" 1
run dq_m m2 new PAY-3 proofs;                   want_rc "a proof list is created from its template" 0
run dq_m m2 freeze PAY-3 -s "$S3B";             want_rc "proofs cannot be frozen before the tier is set" 1
sed -i -e 's/^tier:.*/tier: 2/' -e 's/^approved_by:.*/approved_by: dana 2026-11-15/' "$D3/contract.yaml"
python3 - "$D3/proofs.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p[0]["command"] = "true"
p.append({"id": "P2", "scenario": "S1", "rung": "track", "description": "", "command": "true",
          "evidence": "bundle/rung2/P2.txt", "passes": False})
json.dump(p, open(sys.argv[1], "w"), indent=2)
PY
run dq_m m2 freeze PAY-3 -s "$S3B";             want_rc "tier 2 proofs need the remit lead's approval to freeze" 6
run dq_m m2 freeze PAY-3 -s "$S3B" --by "lead-ana"; want_rc "with approval the proofs freeze" 0
OUT="$(remote_card PAY-3)"
want_out "the card records who approved the proofs" '^proofs_approved_by: lead-ana$'
run dq_m m2 state PAY-3 -s "$S3B" Claimed;      want_rc "Claimed is accepted once contract and frozen proofs exist" 0
run dq_m m2 state PAY-3 -s "$S3B" Local-proven; want_rc "Local-proven is refused while a proof is not passing" 6
sed -i '0,/"passes": false/s//"passes": true/' "$D3/proofs.json"
run dq_m m2 state PAY-3 -s "$S3B" Local-proven; want_rc "a proof marked passing without evidence is refused" 6
want_out "the refusal names the missing evidence" 'evidence file is missing'
mkdir -p "$D3/bundle/rung1" && echo "ran ok" > "$D3/bundle/rung1/P1.txt"
run dq_m m2 state PAY-3 -s "$S3B" Local-proven; want_rc "Local-proven still needs the fresh-eyes record" 6
run dq_m m2 new PAY-3 verification;             want_rc "the verification record is created from its template" 0
run dq_m m2 state PAY-3 -s "$S3B" Local-proven; want_rc "with evidence, Local-proven is recorded" 0
want_out "the local proofs are re-run at the gate" 'P1: PASS'
OUT="$(remote_card PAY-3)"
want_out "the state reaches the server" '^state: Local-proven$'
want_grep "state changes are logged" "$D3/history.log" 'Local-proven'
run dq_m m2 state PAY-3 -s "$S3B" Track-proven; want_rc "Track-proven is refused without track proofs" 6
run dq_m m2 state PAY-3 -s "$S3B" Regressed;    want_rc "a human-confirmed state needs --by" 6
python3 - "$D3/proofs.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p[0]["command"] = "exit 0  # weakened"
json.dump(p, open(sys.argv[1], "w"), indent=2)
PY
run dq_m m2 beat PAY-3 -s "$S3B"
want_out "changing a frozen proof raises a flag" '^PROOFS_FLAG=changed-after-freeze$'
OUT="$(remote_card PAY-3)"
want_out "the flag is on the card for the remit lead to see" '^proofs_flag: changed-after-freeze'
python3 - "$D3/proofs.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p[0]["command"] = "false"
json.dump(p, open(sys.argv[1], "w"), indent=2)
PY
run dq_m m2 check-proofs PAY-3 --rung local;    want_rc "check-proofs fails when a passing proof no longer passes" 6
want_out "check-proofs names the failing proof" 'P1: FAIL'
run dq_m m2 check-proofs PAY-3 --static;        want_rc "the static check passes when evidence files exist" 0

section "budgets"
printf 'budget:\n  hours: 0.0001\n  iterations: 1\n' >> "$(item m1 PAY-2)/contract.yaml"
printf '\n### Attempt 1\nx\n\n### Attempt 2\ny\n' >> "$(item m1 PAY-2)/journal.md"
sleep 2
run dq_m m1 beat PAY-2 -s "$S2"
want_out "a spent hours budget is announced" '^BUDGET=hours-spent$'
want_out "a spent iterations budget is announced" '^BUDGET=iterations-spent$'

section "look around"
run dq_m m3 claim PAY-4;            S4="$(val SESSION)"
run dq_m m3 beat PAY-4 -s "$S4" --set repos=app --set depends_on=PAY-3 --set flows=checkout
run dq_m m3 beat PAY-1 -s "$S1C" --set epic=PAY-100
run dq_m m3 new PAY-4 escalation --to "product owner"
run dq_m m3 beat PAY-4 -s "$S4"
run dq_m m3 look --near PAY-4
want_rc "look works without a board" 0
want_out "look says where its data came from" '^SOURCE=claim branches read directly'
want_out "look counts the open claims" '^OPEN_CLAIMS=[6-9]$'
want_out "look lists items sharing a repo" 'PAY-1[[:space:]].*same-repo'
want_out "look lists items this one depends on" 'PAY-3[[:space:]].*you-depend-on-it'
want_out "look lists the engineer's own items" 'YOURS \(omar\)'
run dq_m m3 look --to "product owner"
want_out "look shows open questions for a role" 'PAY-4[[:space:]]+PAY-4-1.md[[:space:]]+product owner'
want_no "answered questions are not shown as open" 'PAY-1-1.md'
run dq_m m1 look --prefix PAY-9;    want_out "look can be narrowed by key prefix" '^OPEN_CLAIMS=1$'

run dq_m m1 board --publish;        want_rc "the board can be built and published" 0
OUT="$(git -C "$T/server/queue.git" show board:BOARD.tsv)"
want_out "the board file has a generation time" '^# generated_at: 20'
want_out "the board file lists items with their sessions" '^PAY-4	story	Draft	none	omar	omar@ws3#'
OUT="$(git -C "$T/server/queue.git" show board:QUESTIONS.tsv)"
want_out "the board lists open questions" '^PAY-4	PAY-4-1.md	product owner'
OUT="$(git -C "$T/server/queue.git" show board:BOARD.md)"
want_out "the board has a page people can read" '^\| PAY-4 \| Draft'
run dq_m m3 look --near PAY-4;      want_out "look reads the board once it exists" '^SOURCE=board, generated'
want_out "look gives the same neighbours from the board" 'PAY-1[[:space:]].*same-repo'
run dq_m m1 board --publish;        want_rc "the board can be republished" 0
run dq_m m3 inbox --to "product owner"; want_out "inbox lists questions for a role" 'PAY-4-1.md'
run dq_m m1 inbox --to nobody;      want_out "an empty inbox says so" '^INBOX=empty$'

section "tracks"
run dq_m m1 lease list;             want_out "lease list shows configured tracks as free" 'track-01[[:space:]]+free'
run dq_m m2 lease take any PAY-3 -s "$S3B"
want_out "a free track can be leased" '^LEASE=track-01$'
run dq_m m3 lease take track-01 PAY-4 -s "$S4"; want_rc "a held track cannot be leased again" 3
run dq_m m3 lease take any PAY-4 -s "$S4";      want_out "the next free track is found" '^LEASE=track-02$'
run dq_m m1 lease take any PAY-2 -s "$S2";      want_rc "no free track means waiting" 3
want_out "the refusal shows who holds the tracks" 'track-01[[:space:]]+held[[:space:]]+PAY-3'
run dq_m m3 lease release track-01 -s "$S4";    want_rc "only the holder can release a track" 4
run dq_m m2 lease release track-01 -s "$S3B";   want_rc "the holder releases its track" 0
run dq_m m1 lease take track-01 PAY-2 -s "$S2" --minutes 0; want_rc "a released track can be leased" 0
sleep 1
run dq_m m2 lease take track-01 PAY-3 -s "$S3B"; want_rc "an expired lease can be taken over" 0
run dq_m m2 lease release track-01 -s "$S3B"
( dq_m m1 lease take track-01 PAY-2 -s "$S2" > "$T/lr1.out" 2>&1 ) &
( dq_m m2 lease take track-01 PAY-3 -s "$S3B" > "$T/lr2.out" 2>&1 ) &
wait
n="$(cat "$T/lr1.out" "$T/lr2.out" | grep -c '^LEASE=track-01$')"
if [ "$n" = 1 ]; then ok "two sessions racing for one track: exactly one wins"; else bad "lease race produced $n winners" "$(cat "$T/lr1.out" "$T/lr2.out")"; fi
OUT="$(git -C "$T/server/queue.git" for-each-ref --format='%(refname)' refs/heads/lease/)"
want_out "lease branches persist; nothing is deleted" 'refs/heads/lease/track-01'
run dq_m m3 lease release track-02 -s "$S4"
run dq_m m1 claim PAY-10;           S10="$(val SESSION)"
run dq_m m1 lease take track-02 PAY-10 -s "$S10"; want_out "an item leases a track for a run" '^LEASE=track-02$'
run dq_m m1 release PAY-10 -s "$S10" --hold waiting-results --reason "run in flight on track-02"
want_rc "a session can park while a run is in flight" 0
run dq_m m2 take PAY-10;            S10B="$(val SESSION)"
run dq_m m3 lease release track-02 -s "$S4";    want_rc "a stranger cannot release the item's track" 4
run dq_m m2 lease release track-02 -s "$S10B";  want_rc "the item's next session can release its track" 0
run dq_m m2 beat PAY-10 -s "$S10B" --hold bogus; want_rc "an unknown hold is refused" 1
run dq_m m4 claim PAY-6;            S6="$(val SESSION)"
run dq_m m4 lease take any PAY-6 -s "$S6"; want_rc "where a person assigns tracks, dq says so" 5
run dq_m m4 beat PAY-6 -s "$S6" --hold waiting-track --reason "no free track"
OUT="$(remote_card PAY-6)"
want_out "a waiting item is marked on its card" '^hold: waiting-track$'
want_out "the wait has a start time" '^hold_since: 20'

section "one spotlight per workspace"
run dq_m m1 spot take PAY-2 -s "$S2";           want_out "the spotlight lock is taken" '^SPOTLIGHT=yours$'
run dq_m m1 spot take PAY-5 -s "$S5";           want_rc "a second session on the machine must wait" 3
run dq_m m1 spot release -s "$S5";              want_rc "only the holder releases the spotlight" 4
run dq_m m1 spot release -s "$S2";              want_out "the holder releases the spotlight" '^SPOTLIGHT=free$'
run dq_m m1 spot take PAY-2 -s "$S2"
sleep 2
run env DQ_SPOT_STALE_MINUTES=0 bash -c "cd '$T/m1' && DELIVERY_CONFIG='$T/m1/delivery.config.yaml' '$DQ' spot take PAY-5 -s '$S5'"
want_out "an idle spotlight lock can be taken over" '^SPOTLIGHT=yours$'
run dq_m m1 spot release -s "$S5"

section "evidence"
head -c 5000 /dev/urandom > "$(item m1 PAY-2)/bundle-shot.png"
run env DQ_MAX_FILE_KB=1 bash -c "cd '$T/m1' && DELIVERY_CONFIG='$T/m1/delivery.config.yaml' '$DQ' beat PAY-2 -s '$S2'"
want_out "a large file is kept off the claim branch" 'not saved to the claim'
OUT="$(git -C "$T/server/queue.git" ls-tree -r --name-only claim/PAY-2)"
want_no "the large file is not on the claim branch" 'bundle-shot.png'
run dq_m m1 evidence PAY-2 -s "$S2" "$(item m1 PAY-2)/bundle-shot.png"
want_out "large evidence goes to its own branch" '^EVIDENCE_BRANCH=evidence/PAY-2$'
OUT="$(git -C "$T/server/queue.git" ls-tree -r --name-only evidence/PAY-2)"
want_out "the evidence branch holds the file" '^PAY-2/bundle-shot.png$'
rm -f "$(item m1 PAY-2)/bundle-shot.png"

section "code branches"
run dq_m m1 work PAY-2 "$T/m1/app"
want_out "a worktree is made for the item" '^WORKTREE=.*/work/PAY-2/app$'
W="$T/m1/.delivery/work/PAY-2/app"
OUT="$(git -C "$W" rev-parse --abbrev-ref HEAD)"; want_out "the worktree is on the item branch" '^item/PAY-2$'
( cd "$W" && echo changed >> src/a.txt && git commit -q -am "PAY-2 change a" )
run dq_m m1 push PAY-2 -s "$S2";   want_out "push sends the item branch" '^PUSHED=app item/PAY-2$'
OUT="$(git -C "$T/server/app.git" for-each-ref --format='%(refname)' refs/heads/item/)"
want_out "the item branch is on the server" 'refs/heads/item/PAY-2'
run dq_m m1 release PAY-2 -s "$S2"
run dq_m m2 take PAY-2;             S2B="$(val SESSION)"
run dq_m m2 work PAY-2 "$T/m2/app"; want_out "another machine resumes the code branch" '^RESUMED=app item/PAY-2'
want_grep "the resumed worktree has the pushed change" "$T/m2/.delivery/work/PAY-2/app/src/a.txt" 'changed'
git -C "$T/m3/app" checkout -q -b item/PAY-4 origin/main
( cd "$T/m3/app" && echo other >> src/a.txt && echo more >> src/b.txt && git commit -q -am "PAY-4 change" && git push -q -u origin item/PAY-4 )
run dq_m m2 overlap PAY-2 "$T/m2/.delivery/work/PAY-2/app"
want_out "overlap names the other item" '^OVERLAP_WITH=PAY-4$'
want_out "overlap lists the shared file" 'src/a.txt'
want_no "overlap leaves out files only one side touched" 'src/b.txt'

section "already done?"
run dq_m m1 done-check PAY-77;      want_out "nothing found for an untouched key" '^FINDINGS=0$'
( cd "$T/seed-app" && git pull -q origin main && echo fix >> src/b.txt && git commit -q -am "PAY-77 fix the thing" && git push -q origin main )
echo "Decision for PAY-77" > "$T/m1/atlas/decision.md"
run dq_m m1 done-check PAY-77
want_out "done-check finds a commit that names the key" 'PAY-77 fix the thing'
want_out "done-check finds an Atlas page that names the key" 'decision.md'
want_out "done-check counts its findings" '^FINDINGS=2$'
run dq_m m1 done-check PAY-7;       want_out "a longer key does not match a shorter one" '^FINDINGS=0$'
run dq_m m4 done-check PAY-1;       want_out "done-check sees an open claim" 'open claim: yes'
( cd "$T/seed-queue" && git pull -q origin main && git fetch -q origin claim/PAY-9 && git merge -q --no-edit FETCH_HEAD && git push -q origin main )
git -C "$T/server/queue.git" update-ref -d refs/heads/claim/PAY-9
run dq_m m2 done-check PAY-9;       want_out "done-check sees an item closed on the default branch" 'closed item on main: yes'
run dq_m m2 claim PAY-9;            want_rc "a closed item is not silently claimed again" 3
want_out "the refusal says it is closed" '^CLOSED=PAY-9$'
run dq_m m2 claim PAY-9 --reopen;   want_rc "a closed item can be reopened on purpose" 0

section "server protection"
run dq_m m1 protect-check;          want_out "an unprotected server is reported as a warning" '^RESULT=warn$'
git -C "$T/server/queue.git" config receive.denyNonFastForwards true
run dq_m m1 protect-check;          want_out "a server that refuses force-pushes passes" '^RESULT=pass$'
want_out "the second writer is always refused" '^SECOND_PUSH=rejected$'
run dq_m m3 look;                   want_no "smoke branches stay off the board" '_smoke'

section "requests, configs, version"
cp "$T/sys/system/templates/request.md" "$T/req.md"
run dq_m m1 request "need refund spotlight" "$T/req.md"; want_out "a harness request gets its own branch" '^REQUESTED=request/dana-need-refund-spotlight$'
run dq_m m1 publish-config;         want_out "a workspace config can be published" '^PUBLISHED=config/dana/ws1$'
run dq_m m3 configs;                want_out "published configs can be listed" '^dana/ws1$'
run dq_m m3 configs dana/ws1;       want_out "a published config can be read" 'machine: ws1'
run dq_m m1 version --check;        want_out "an up-to-date manual says so" '^STATUS=current$'
( cd "$T/seed-system" && echo 9.9.9 > system/VERSION && git commit -q -am "new manual" && git push -q origin main )
run dq_m m1 version --check;        want_out "a newer manual in the shared repo is noticed" '^STATUS=behind$'
want_out "the newer version is named" '^LATEST=9.9.9$'
run dq_m m1 version --pull;         want_out "the manual updates itself from the shared repo" '^UPDATED_TO=9.9.9$'
cp -R "$T/sys/system" "$T/loose"
run env DELIVERY_CONFIG="$T/m1/delivery.config.yaml" "$T/loose/tools/dq" version --check
want_out "a copy outside git is reported as unmanaged" '^STATUS=unmanaged$'

section "install and hooks"
run dq_m m1 install --workspace "$T/m1"
want_rc "install runs" 0
want_grep "the workspace instruction file gets the block" "$T/m1/CLAUDE.md" 'delivery-system:start'
want_grep "the block names the real system path" "$T/m1/CLAUDE.md" "$T/sys/system/DELIVERY-AGENT.txt"
want_grep "skills are installed with the real path" "$T/m1/.claude/skills/deliver/SKILL.md" "$T/sys/system/manual/DELIVER.txt"
want_grep "the pre-tool hook is registered" "$T/m1/.claude/settings.json" 'hook-pretool'
want_grep "the stop hook is registered" "$T/m1/.claude/settings.json" 'hook-stop'
want_grep "force-push is denied by rule" "$T/m1/.claude/settings.json" 'git push --force'
echo "# my notes" > "$T/m3/CLAUDE.md"
run dq_m m3 install --workspace "$T/m3"; run dq_m m3 install --workspace "$T/m3"
n="$(grep -c 'delivery-system:start' "$T/m3/CLAUDE.md")"
if [ "$n" = 1 ]; then ok "installing twice leaves one block"; else bad "install is not idempotent ($n blocks)"; fi
want_grep "existing instructions are kept" "$T/m3/CLAUDE.md" '^# my notes$'
n="$(grep -c 'hook-stop' "$T/m3/.claude/settings.json")"
if [ "$n" = 1 ]; then ok "installing twice registers each hook once"; else bad "hooks duplicated ($n)"; fi
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$T/m3/.claude/settings.json" && ok "settings.json stays valid JSON" || bad "settings.json is not valid JSON"

hook() { printf '%s' "$1" | ( cd "$T/m1" && DELIVERY_CONFIG="$T/m1/delivery.config.yaml" "$DQ" hook-pretool ); }
bash_event() { python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }
blocked() { run hook "$(bash_event "$2")"; want_rc "hook blocks: $1" 2; }
allowed() { run hook "$(bash_event "$2")"; want_rc "hook allows: $1" 0; }
blocked "force-push"                      'git push --force origin item/PAY-1'
blocked "short force flag"                'git push -f origin item/PAY-1'
blocked "force-with-lease"                'git push --force-with-lease origin item/PAY-1'
blocked "force after other arguments"     'cd app && git push origin item/PAY-1 --force'
blocked "plus refspec"                    'git push origin +item/PAY-1'
blocked "deleting a remote branch"        'git push origin :item/PAY-1'
blocked "delete flag"                     'git push origin --delete item/PAY-1'
blocked "push to main"                    'git push origin main'
blocked "push HEAD to main"               'git -C app push origin HEAD:main'
blocked "push to main after another step" 'git add -A && git commit -m x && git push -u origin main'
allowed "pushing the item branch"         'git push -u origin item/PAY-1'
allowed "pushing after a commit"          'git commit -m "fix" && git push origin item/PAY-1'
allowed "a branch that only contains the word main" 'git push origin item/main-menu'
allowed "a commit message that mentions force"      'git commit -m "do not --force this"'
allowed "ordinary commands"               'npm test -- --force'
allowed "git log"                         'git log --oneline -5 main'
run hook '{"tool_name":"Edit","tool_input":{"file_path":"'"$T"'/m1/app/.gitlab-ci.yml"}}'
want_rc "an edit to pipeline config is not blocked outright" 0
want_out "it is sent to the engineer for approval instead" '"permissionDecision":"ask"'
run hook '{"tool_name":"Edit","tool_input":{"file_path":"'"$T"'/m1/app/src/a.txt"}}'
want_no "ordinary edits pass untouched" 'permissionDecision'

stop_hook() { printf '%s' "$1" | ( cd "$T/$2" && DELIVERY_CONFIG="$T/$2/delivery.config.yaml" "$DQ" hook-stop ); }
run stop_hook '{"hook_event_name":"Stop","stop_hook_active":false}' m3
want_rc "the stop hook lets a clean session stop" 0
sleep 1; echo "2026 unsaved line" >> "$(item m3 PAY-4)/journal.md"
run stop_hook '{"hook_event_name":"Stop","stop_hook_active":false}' m3
want_rc "the stop hook holds a session with unsaved item files" 2
want_out "it says which command saves them" 'beat PAY-4 -s omar@ws3#'
run stop_hook '{"hook_event_name":"Stop","stop_hook_active":true}' m3
want_rc "the stop hook never loops" 0
run dq_m m3 beat PAY-4 -s "$S4"
run stop_hook '{"hook_event_name":"Stop","stop_hook_active":false}' m3
want_rc "after a save the session may stop" 0
( cd "$T/m2/.delivery/work/PAY-2/app" && echo again >> src/a.txt && git commit -q -am "PAY-2 second change" )
run dq_m m2 beat PAY-2 -s "$S2B"
run stop_hook '{"hook_event_name":"Stop","stop_hook_active":false}' m2
want_rc "the stop hook holds a session with unpushed commits" 2
want_out "it says how to push them" 'push PAY-2 -s dana@ws2#'
run dq_m m2 push PAY-2 -s "$S2B"
run dq_m m2 beat PAY-3 -s "$S3B"
run stop_hook '{"hook_event_name":"Stop","stop_hook_active":false}' m2
want_rc "after the push the session may stop" 0

section "finding the config, and working without python3"
mkdir -p "$T/m1/app/src/deep"
OUT="$(cd "$T/m1/app/src/deep" && "$DQ" doctor 2>&1)"; RC=$?
want_rc "the config is found from a subdirectory of the workspace" 0
OUT="$(cd / && CLAUDE_PROJECT_DIR="$T/m1" "$DQ" doctor 2>&1)"; RC=$?
want_rc "the config is found through the project directory a hook is given" 0
run env DQ_STALE_MINUTES=0 bash -c "cd '$T/m1' && '$DQ' look"
want_out "look counts sessions that have gone silent" '^SILENT_SESSIONS=[1-9]'
nopy() { ( cd "$T/$1" && shift && DQ_NO_PYTHON=1 DELIVERY_CONFIG="$PWD/delivery.config.yaml" "$DQ" "$@" ); }
run nopy m1 claim PAY-8;            S8="$(val SESSION)"
want_rc "claims work without python3" 0
D8="$(item m1 PAY-8)"
run nopy m1 new PAY-8 contract; run nopy m1 new PAY-8 proofs
sed -i -e 's/^tier:.*/tier: 1/' -e 's/^approved_by:.*/approved_by: dana/' "$D8/contract.yaml"
run nopy m1 freeze PAY-8 -s "$S8";  want_rc "proofs freeze without python3" 0
want_out "the skipped machine check is announced, not hidden" '^PROOF_CHECK=skipped'
OUT="$(remote_card PAY-8)";         want_out "the fallback hash is marked as such" '^proofs_frozen: sh:'
sed -i 's/"command": ""/"command": "true"/' "$D8/proofs.json"
run nopy m1 beat PAY-8 -s "$S8";    want_out "a changed frozen proof is still flagged without python3" '^PROOFS_FLAG=changed-after-freeze$'
sed -i 's/"passes": false/"passes": true/' "$D8/proofs.json"
run nopy m1 beat PAY-8 -s "$S8";    want_no "changing only passes raises no new flag" 'NOT_ACTIVE'
OUT="$(printf '%s' "$(bash_event 'git push --force origin item/PAY-8')" | ( cd "$T/m1" && DQ_NO_PYTHON=1 DELIVERY_CONFIG="$T/m1/delivery.config.yaml" "$DQ" hook-pretool ) 2>&1)"; RC=$?
want_rc "the push guard still blocks a force-push without python3" 2
OUT="$(printf '%s' "$(bash_event 'git push -u origin item/PAY-8')" | ( cd "$T/m1" && DQ_NO_PYTHON=1 DELIVERY_CONFIG="$T/m1/delivery.config.yaml" "$DQ" hook-pretool ) 2>&1)"; RC=$?
want_rc "and still allows an ordinary push" 0
mkdir -p "$T/m4x" && cp "$T/m4/delivery.config.yaml" "$T/m4x/"
OUT="$(cd "$T/m4x" && DQ_NO_PYTHON=1 "$DQ" install --workspace "$T/m4x" 2>&1)"; RC=$?
want_out "install without python3 points to the settings example" 'settings.example.json'
want_file "install without python3 still writes the instruction block" "$T/m4x/CLAUDE.md"

section "small commands"
run dq_m m1 whois PAY-404;          want_out "whois reports a free key" '^FREE=PAY-404$'
run dq_m m1 path PAY-8;             want_out "path prints the item directory" '/\.delivery/items/PAY-8$'
for k in challenge summary jira decomposition handoff; do
  run dq_m m1 new PAY-8 "$k";       want_rc "template: $k" 0
done
want_grep "templates are filled with the key" "$D8/escalations/PAY-8-challenge.md" 'Challenge to PAY-8'
run dq_m m1 beat PAY-8 -s "$S8"
run dq_m m1 board --publish
run dq_m m3 inbox --to product;     want_out "a challenge shows up as an open question for product" 'PAY-8-challenge.md'
run dq_m m1 new PAY-8 escalation --to "omar (owner of PAY-4)"
want_grep "an escalation can be addressed to another item's owner" "$D8/escalations/PAY-8-1.md" '^To: omar \(owner of PAY-4\)$'
run dq_m m1 state PAY-8 -s "$S8" Satisfied; want_rc "Satisfied needs its summary and Jira update" 0
run dq_m m1 state PAY-8 -s "$S8" Cancelled --by "product-kim"; want_rc "a person-confirmed state is recorded with --by" 0
want_grep "the history names who confirmed it" "$D8/history.log" 'Cancelled by=product-kim'
run dq_m m1 help;                   want_out "help lists the commands" 'dq claim KEY'

section "closed items and quiet claims"
run dq_m m3 claim PAY-8;            want_rc "an item in a closed state is not claimed again" 3
want_out "the refusal says it is closed, and how" '^CLOSED=PAY-8$'
want_out "the refusal gives the closed state" '^STATE=Cancelled$'
run dq_m m3 claim PAY-8 --reopen;   want_rc "reopening waits until the claim is archived" 5
run dq_m m1 board --publish          # the board job runs again after the item closed
run dq_m m1 look --prefix PAY-8;    want_out "closed items leave the open count" '^OPEN_CLAIMS=0$'
run dq_m m3 done-check PAY-8;       want_out "done-check says the claim is closed" 'open claim: no \(closed, state Cancelled\)'
run dq_m m3 whois PAY-8;            want_out "whois marks a closed item" '^CLOSED=PAY-8$'
run dq_m m3 show PAY-8;             want_out "show lists another item's files" '^bundle/SUMMARY.md$'
run dq_m m3 show PAY-8 claim.yaml;  want_out "show prints one of them" '^state: Cancelled$'
run dq_m m3 show PAY-8 nope.md;     want_rc "show says when a file is not there" 1
run dq_m m2 show PAY-9 claim.yaml;  want_rc "show reads an open item too" 0
run dq_m m1 claim PAY-11;           S11="$(val SESSION)"
run dq_m m1 release PAY-11 -s "$S11" --hold parked --reason "nobody is on it"
run dq_m m1 board --publish          # the pipeline job would do this
run dq_m m1 look;                   want_out "a fresh release is not quiet yet" '^QUIET_CLAIMS=0$'
DQ_QUIET_DAYS=0 run dq_m m1 look --quiet
want_out "look counts claims nobody has touched for too long" '^QUIET_CLAIMS=[1-9]'
want_out "look --quiet lists them" 'PAY-11'
DQ_QUIET_DAYS=0 run dq_m m1 board
want_out "the board has a quiet-claims section" '^## Quiet claims$'
want_out "the board lists the quiet claim there" '^\| PAY-11 \| Draft \| parked '
want_no "the board leaves closed items out" '^\| PAY-8 '


section "the board job, and proofs that run anywhere"
git clone -q "$T/server/queue.git" "$T/ci-queue"
run env DQ_QUEUE="$T/ci-queue" DQ_ENGINEER=board-job DQ_MACHINE=ci DQ_WORKSPACE="$T/ci-ws" "$DQ" board --publish
want_out "a pipeline job can publish the board with no config file" '^PUBLISHED=board$'
run dq_m m1 claim PAY-12;           S12="$(val SESSION)"; D12="$(val ITEM_DIR)"
mkdir -p "$T/m1/app/sub" "$D12/bundle/rung1"; echo marker > "$T/m1/app/sub/here.txt"; echo out > "$D12/bundle/rung1/P1.txt"
printf '[{"id":"P1","scenario":"S1","rung":"local","description":"","command":"test -f here.txt","cwd":"app/sub","timeout_s":30,"evidence":"bundle/rung1/P1.txt","passes":true}]\n' > "$D12/proofs.json"
run dq_m m1 check-proofs PAY-12 --rung local
want_out "a proof's cwd is taken from the workspace root" '^P1: PASS'
run dq_m m1 done-check PAY-12;      want_out "done-check does not count your own claim" 'open claim: yours'
want_out "so a fresh ticket of your own has no findings" '^FINDINGS=0$'
run dq_m m3 done-check PAY-12;      want_out "another engineer still sees it as held" 'open claim: yes'
run dq_m m1 beat PAY-12 -s "$S12" --hold parked --reason "waiting on a question"
run dq_m m1 state PAY-12 -s "$S12" Cancelled --by product-kim
want_out "a recorded state change clears the old hold" '^HOLD=none$'
run dq_m m1 lease list;             want_no "a free track shows no holder" '[[:space:]]free[[:space:]]+none'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
