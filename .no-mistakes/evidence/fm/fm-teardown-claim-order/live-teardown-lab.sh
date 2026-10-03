#!/usr/bin/env bash
set -euo pipefail

# Drive the shipped CLI with a marked disposable FM_HOME, a real local Git
# remote, a real Treehouse pool and a private tmux socket. All fixture files
# live under the run worktree and are removed by the EXIT trap.
cd /home/agentuser/.no-mistakes/worktrees/2c673edc43e7/01M40E1Z9VMDDKFE4PVQKAAAK4
LABS=()
cleanup() {
  local lab
  for lab in "${LABS[@]}"; do
    tmux -S "$lab/s" kill-server >/dev/null 2>&1 || true
    rm -rf "$lab"
  done
}
trap cleanup EXIT

fixture() {
  LAB=$(mktemp -d "$PWD/.l.XXXXXX")
  LABS+=("$LAB")
  bin/fm-lab-home.sh create "$LAB" >/dev/null
  mkdir -p "$LAB/work"
  git init -q "$LAB/work"
  git -C "$LAB/work" -c user.name=lab -c user.email=lab@example.invalid commit --allow-empty -qm base
  git clone -q --bare "$LAB/work" "$LAB/origin.git"
  git clone -q "$LAB/origin.git" "$LAB/projects/project"
  WT=$(cd "$LAB/projects/project" && TREEHOUSE_ROOT="$LAB/pool" treehouse get --lease --no-fetch 2>/dev/null)
  SLOT=$(dirname "$WT")
  tmux -S "$LAB/s" new-session -d -s firstmate -n fm-stale-task sleep 300
  printf 'window=firstmate:fm-stale-task\nendpoint_task_id=stale-task\nworktree=%s\nproject=%s\nbranch=fm/stale-task\nkind=ship\n' \
    "$WT" "$LAB/projects/project" > "$LAB/state/stale-task.meta"
}
claim() { printf 'task=%s\nhome=%s\n' "$1" "$LAB" > "$SLOT/.fm-slot-owner"; }
run_teardown() {
  local rc=0
  FM_HOME="$LAB" TREEHOUSE_ROOT="$LAB/pool" TMUX="$LAB/s,0,0" \
    bin/fm-teardown.sh stale-task --force > "$LAB/stdout" 2> "$LAB/stderr" || rc=$?
  printf '%s\n' "$rc"
}
show_result() {
  local name=$1 rc=$2
  printf '\n=== %s: exit %s ===\n' "$name" "$rc"
  sed -n '/warning: task stale-task/p;/REFUSED:/p;/task record could not be removed/p' "$LAB/stderr"
  sed -n '/pruned /p;/teardown stale-task complete/p' "$LAB/stdout"
  printf 'record=%s claim=%s branch=%s\n' \
    "$([ -f "$LAB/state/stale-task.meta" ] && echo present || echo absent)" \
    "$([ -f "$SLOT/.fm-slot-owner" ] && echo present || echo absent)" \
    "$(git -C "$LAB/projects/project" show-ref --verify --quiet refs/heads/fm/stale-task && echo present || echo absent)"
}

fixture
claim live-task
rc=$(run_teardown)
show_result missing-branch "$rc"
test "$rc" -ne 0
test -f "$LAB/state/stale-task.meta"
test -f "$SLOT/.fm-slot-owner"
grep -q 'no preserved recorded branch' "$LAB/stderr"

fixture
printf 'task=stale-task\ntask=live-task\nhome=%s\n' "$LAB" > "$SLOT/.fm-slot-owner"
git -C "$LAB/projects/project" branch fm/stale-task
rc=$(run_teardown)
show_result ambiguous-claim "$rc"
test "$rc" -ne 0
test -f "$LAB/state/stale-task.meta"
test -f "$SLOT/.fm-slot-owner"
grep -q 'claim that cannot be read' "$LAB/stderr"

fixture
git -C "$WT" switch -q -c fm/stale-task
claim stale-task
mkdir -p "$LAB/fakebin"
real_rm=$(command -v rm)
cat > "$LAB/fakebin/rm" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = -f ] && [ "\${2:-}" = "$LAB/state/stale-task.meta" ]; then exit 1; fi
exec "$real_rm" "\$@"
EOF
chmod +x "$LAB/fakebin/rm"
rc=0
FM_HOME="$LAB" TREEHOUSE_ROOT="$LAB/pool" TMUX="$LAB/s,0,0" PATH="$LAB/fakebin:$PATH" \
  bin/fm-teardown.sh stale-task --force > "$LAB/stdout" 2> "$LAB/stderr" || rc=$?
show_result interrupted-after-return "$rc"
test "$rc" -ne 0
test -f "$LAB/state/stale-task.meta"
test ! -f "$SLOT/.fm-slot-owner"
git -C "$LAB/projects/project" show-ref --verify --quiet refs/heads/fm/stale-task
grep -q 'task record could not be removed' "$LAB/stderr"
rm "$LAB/fakebin/rm"
claim live-task
printf 'claimant sentinel\n' > "$WT/claimant-sentinel"
printf 'window=firstmate:fm-live-task\nendpoint_task_id=live-task\nworktree=%s\nproject=%s\nkind=scout\n' \
  "$WT" "$LAB/projects/project" > "$LAB/state/live-task.meta"
rc=$(run_teardown)
show_result retry-after-reassignment "$rc"
test "$rc" -eq 0
test ! -f "$LAB/state/stale-task.meta"
test -f "$LAB/state/live-task.meta"
test -f "$WT/claimant-sentinel"
grep -q 'task=live-task' "$SLOT/.fm-slot-owner"

fixture
git -C "$WT" switch -q -c fm/stale-task
printf 'unpublished work\n' > "$WT/unpublished.txt"
git -C "$WT" add unpublished.txt
git -C "$WT" -c user.name=lab -c user.email=lab@example.invalid commit -qm unpublished
git -C "$WT" checkout --detach -q
base=$(git -C "$LAB/projects/project" symbolic-ref --short HEAD)
git -C "$LAB/projects/project" branch fm/landed "$base"
for b in fm/stale-task fm/landed; do
  git -C "$LAB/projects/project" config "branch.$b.remote" origin
  git -C "$LAB/projects/project" config "branch.$b.merge" "refs/heads/$b"
done
claim live-task
printf 'claimant sentinel\n' > "$WT/claimant-sentinel"
printf 'window=firstmate:fm-live-task\nendpoint_task_id=live-task\nworktree=%s\nproject=%s\nkind=scout\n' \
  "$WT" "$LAB/projects/project" > "$LAB/state/live-task.meta"
rc=$(run_teardown)
show_result records-only-pruning "$rc"
test "$rc" -eq 0
test ! -f "$LAB/state/stale-task.meta"
test -f "$LAB/state/live-task.meta"
test -f "$WT/claimant-sentinel"
grep -q 'task=live-task' "$SLOT/.fm-slot-owner"
grep -q 'pruned fm/landed' "$LAB/stdout"
git -C "$LAB/projects/project" show-ref --verify --quiet refs/heads/fm/stale-task
test "$(git -C "$LAB/projects/project" show fm/stale-task:unpublished.txt)" = 'unpublished work'
printf 'unpublished commit=preserved; landed branch=pruned\n'

fixture
git -C "$LAB/projects/project" switch -q -c unpublished
printf 'unique committed work\n' > "$LAB/projects/project/unique.txt"
git -C "$LAB/projects/project" add unique.txt
git -C "$LAB/projects/project" -c user.name=lab -c user.email=lab@example.invalid commit -qm unique
git -C "$LAB/projects/project" push -q origin unpublished:carrier
git -C "$LAB/projects/project" fetch -q origin
git --git-dir="$LAB/origin.git" update-ref -d refs/heads/carrier
git -C "$LAB/projects/project" switch -q "$base"
git -C "$LAB/projects/project" config remote.origin.fetch '+refs/heads/master:refs/remotes/origin/master'
git -C "$LAB/projects/project" config branch.unpublished.remote origin
git -C "$LAB/projects/project" config branch.unpublished.merge refs/heads/unpublished
git -C "$LAB/projects/project" show-ref --verify --quiet refs/remotes/origin/carrier
FM_HOME="$LAB" bin/fm-fleet-sync.sh project > "$LAB/stdout" 2> "$LAB/stderr"
printf '\n=== narrow-fetch-stale-origin ===\n'
cat "$LAB/stdout"
test ! -e "$LAB/projects/project/.git/refs/remotes/origin/carrier"
! git -C "$LAB/projects/project" show-ref --verify --quiet refs/remotes/origin/carrier
git -C "$LAB/projects/project" show-ref --verify --quiet refs/heads/unpublished
test "$(git -C "$LAB/projects/project" show unpublished:unique.txt)" = 'unique committed work'
printf 'stale origin ref=removed; unpublished commit=preserved\n'

fixture
git clone -q --bare "$LAB/origin.git" "$LAB/fork.git"
git -C "$LAB/projects/project" remote add fork "$LAB/fork.git"
git -C "$LAB/projects/project" switch -q -c unpublished
printf 'fork only work\n' > "$LAB/projects/project/fork-only.txt"
git -C "$LAB/projects/project" add fork-only.txt
git -C "$LAB/projects/project" -c user.name=lab -c user.email=lab@example.invalid commit -qm fork-only
git -C "$LAB/projects/project" push -q fork unpublished
git -C "$LAB/projects/project" fetch -q fork
git --git-dir="$LAB/fork.git" update-ref -d refs/heads/unpublished
git -C "$LAB/projects/project" switch -q "$base"
git -C "$LAB/projects/project" config branch.unpublished.remote origin
git -C "$LAB/projects/project" config branch.unpublished.merge refs/heads/unpublished
git -C "$LAB/projects/project" show-ref --verify --quiet refs/remotes/fork/unpublished
FM_HOME="$LAB" bin/fm-fleet-sync.sh project > "$LAB/stdout" 2> "$LAB/stderr"
printf '\n=== stale-fork-ref ===\n'
cat "$LAB/stdout"
git -C "$LAB/projects/project" show-ref --verify --quiet refs/remotes/fork/unpublished
git -C "$LAB/projects/project" show-ref --verify --quiet refs/heads/unpublished
test "$(git -C "$LAB/projects/project" show unpublished:fork-only.txt)" = 'fork only work'
printf 'stale fork ref=present; unpublished commit=preserved\n'
