#!/usr/bin/env bash
# walkthrough.sh - one delivery, command by command, in a throwaway world.
#
# It installs into a pretend workspace, then follows manual/DELIVER.txt for
# one tier 1 story from the claim to Regressed, printing every dq command
# and what it answered. Three refusals are deliberate: they show a state
# that will not move without its evidence. Nothing outside a temporary
# directory is touched. The force-push warning from protect-check is
# expected here: a bare local repo has no branch protection.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=walk GIT_AUTHOR_EMAIL=walk@example.invalid GIT_COMMITTER_NAME=walk GIT_COMMITTER_EMAIL=walk@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset DELIVERY_CONFIG DQ_QUEUE DQ_ENGINEER DQ_MACHINE DQ_WORKSPACE CLAUDE_PROJECT_DIR 2>/dev/null || true
step() { printf '\n\033[1m### %s\033[0m\n' "$*"; }
say()  { printf '$ dq %s\n' "$*"; }
mkdir -p "$T/server"
for r in queue app system; do git init -q --bare "$T/server/$r.git"; git -C "$T/server/$r.git" symbolic-ref HEAD refs/heads/main; done
git clone -q "$T/server/system.git" "$T/seed-system" 2>/dev/null
mkdir -p "$T/seed-system/system"; cp -R "$SRC"/. "$T/seed-system/system/"
sed -e "s#^  names:.*#  names: track-01, track-02#" "$SRC/environment.example.yaml" > "$T/seed-system/system/environment.yaml"
( cd "$T/seed-system" && git checkout -q -b main 2>/dev/null; git add -A && git commit -q -m system && git push -q origin main )
git clone -q "$T/server/queue.git" "$T/seed-queue" 2>/dev/null
( cd "$T/seed-queue" && git checkout -q -b main 2>/dev/null; echo queue > README.md; git add -A; git commit -q -m seed; git push -q origin main )
git clone -q "$T/server/app.git" "$T/seed-app" 2>/dev/null
( cd "$T/seed-app" && git checkout -q -b main 2>/dev/null; mkdir src; echo one > src/a.txt; git add -A; git commit -q -m seed; git push -q origin main )

# --- the engineer's workspace, before any session
W="$T/ws"; mkdir -p "$W"
git clone -q "$T/server/system.git" "$W/shared"
DQ="$W/shared/system/tools/dq"; chmod +x "$DQ"
dq() { say "$*"; ( cd "$W" && "$DQ" "$@" ); local rc=$?; [ $rc -eq 0 ] || echo "(exit $rc)"; return $rc; }

step "README: once per workspace"
dq install --workspace "$W"
echo "--- CLAUDE.md"; cat "$W/CLAUDE.md"
echo "--- skills"; ls "$W/.claude/skills"
echo "--- config skeleton"; head -12 "$W/delivery.config.yaml"

step "CORE 4.1-4.2 on a workspace that is not set up"
dq version --check
dq doctor

step "SETUP steps 2 and 5: clone, write the config"
git clone -q --single-branch "$T/server/queue.git" "$W/queue"
git clone -q "$T/server/app.git" "$W/app"
mkdir -p "$W/atlas"
cat > "$W/delivery.config.yaml" <<CFG
setup_complete: true
level: 2
engineer:
  name: dana
workspace:
  root: $W
  machine: ws-dana-1
remit:
  name: payments
queue:
  path: $W/queue
atlas:
  path: $W/atlas
repos:
  - name: app
    path: $W/app
    default_branch: main
CFG
dq doctor
dq protect-check
dq publish-config
dq configs

step "CORE 4.4: look around"
dq look

step "DELIVER step 1: claim"
out="$(cd "$W" && "$DQ" claim WALK-1 --kind story --remit payments)"; echo "$out"
S="$(printf '%s\n' "$out" | sed -n 's/^SESSION=//p')"; D="$(printf '%s\n' "$out" | sed -n 's/^ITEM_DIR=//p')"
dq beat WALK-1 -s "$S" --set repos=app --set services=ledger --set flows=refund
dq look --near WALK-1

step "DELIVER step 2: already done?"
dq done-check WALK-1

step "DELIVER step 5: a challenge (to see where it lands)"
dq new WALK-1 challenge
dq beat WALK-1 -s "$S" --hold challenge --reason "no North Star line found"
dq inbox --to product
dq beat WALK-1 -s "$S" --hold none

step "DELIVER steps 6-8: contract and proofs"
dq new WALK-1 contract
dq new WALK-1 proofs
sed -i -e 's/^approved_by:.*/approved_by: dana 2026-11-15/' -e 's/^tier:.*/tier: 1/' "$D/contract.yaml"
dq state WALK-1 -s "$S" Claimed     # must refuse: proofs not frozen yet

step "DELIVER step 9: worktrees"
dq work WALK-1 "$W/app"
WT="$W/.delivery/work/WALK-1/app"; ls -d "$WT" && git -C "$WT" branch --show-current

step "DELIVER step 10: failing proofs, freeze"
cat > "$D/proofs.json" <<'PJ'
[
  {"id":"P1","scenario":"S1","rung":"local","description":"file says done","command":"grep -q done src/a.txt","cwd":".delivery/work/WALK-1/app","timeout_s":30,"evidence":"bundle/rung1/P1.txt","passes":false},
  {"id":"P2","scenario":"S1","rung":"track","description":"same on a track","command":"true","cwd":"","timeout_s":30,"evidence":"bundle/rung2/P2.txt","passes":false}
]
PJ
mkdir -p "$D/bundle/rung1/failing-first"; echo "grep: no match (expected failure)" > "$D/bundle/rung1/failing-first/P1.txt"
dq freeze WALK-1 -s "$S"
dq state WALK-1 -s "$S" Claimed

step "DELIVER step 11: implement, save, evidence"
dq spot take WALK-1 -s "$S"
( cd "$WT" && echo done >> src/a.txt && git commit -q -am "WALK-1 make it done" )
dq push WALK-1 -s "$S"
dq spot release -s "$S"
echo "PASS: grep found 'done'" > "$D/bundle/rung1/P1.txt"
python3 - "$D/proofs.json" P1 <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
for x in p:
    if x["id"] == sys.argv[2]: x["passes"] = True
json.dump(p, open(sys.argv[1], "w"), indent=2)
PY
head -c 300000 /dev/urandom > "$T/shot.png"
dq evidence WALK-1 -s "$S" "$T/shot.png"

step "DELIVER step 12: fresh eyes, Local-proven"
dq state WALK-1 -s "$S" Local-proven    # must refuse: no verification yet
dq new WALK-1 verification
dq state WALK-1 -s "$S" Local-proven

step "DELIVER step 13: catch up and re-prove"
( cd "$T/seed-app" && echo other >> src/b.txt && git add -A && git commit -q -m "someone else lands" && git push -q origin main )
( cd "$WT" && git fetch -q origin main && git merge -q --no-edit FETCH_HEAD )
dq check-proofs WALK-1 --rung local
dq push WALK-1 -s "$S"
dq overlap WALK-1 "$WT"

step "DELIVER step 14: track"
dq lease list
dq lease take any WALK-1 -s "$S"
mkdir -p "$D/bundle/rung2"; echo "track results: PASS" > "$D/bundle/rung2/P2.txt"
python3 - "$D/proofs.json" P2 <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
for x in p:
    if x["id"] == sys.argv[2]: x["passes"] = True
json.dump(p, open(sys.argv[1], "w"), indent=2)
PY
dq lease release track-01 -s "$S"

step "DELIVER step 15: bundle"
dq state WALK-1 -s "$S" Track-proven    # must refuse: no summary or Jira update yet
dq new WALK-1 summary
dq new WALK-1 jira
dq state WALK-1 -s "$S" Track-proven

step "DELIVER step 18: release"
dq release WALK-1 -s "$S" --hold waiting-approval --reason "in review"
dq whois WALK-1

step "DELIVER step 19: a later session records what people confirmed"
out="$(cd "$W" && "$DQ" take WALK-1)"; echo "$out"; S2="$(printf '%s\n' "$out" | sed -n 's/^SESSION=//p')"
dq state WALK-1 -s "$S2" UAT-proven --by product-kim
dq state WALK-1 -s "$S2" Live --by dana
dq state WALK-1 -s "$S2" Confirmed --by dana
dq state WALK-1 -s "$S2" Regressed --by dana
dq release WALK-1 -s "$S2"
dq show WALK-1
dq show WALK-1 history.log
dq look
dq board | head -12
