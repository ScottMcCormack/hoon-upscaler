#!/bin/bash
# ============================================================================
# Rent a GPU, run cloud/run_on_pod.sh on it, retrieve the result, terminate.
#
#   bash cloud/launch_pod.sh 720 test          # cheap first run, ~6 min
#   bash cloud/launch_pod.sh 1080 full         # the 1080p master, ~45 min
#   BATCH_SIZE=65 bash cloud/launch_pod.sh 720 full   # reproduce the 720p master
#
# Why this exists as a script rather than a sequence of commands: the pod bills by
# the second from creation, and every version of "I will watch it and shut it down"
# has cost money. One run armed a clock-based watchdog instead of a completion
# check, and the render finished about an hour before the pod died — $1.01 for an
# empty GPU. So completion here is defined by the manifest appearing, the download
# starts the moment it does, and termination is an EXIT trap armed BEFORE the pod
# is created, so a crash between creation and polling still shuts it down.
#
# It terminates ONLY the pod id this script created, recorded in POD_ID. A previous
# teardown nearly destroyed a second workload that had been started on a shared pod;
# owning the pod is what makes automatic termination safe, so this never touches a
# pod it did not create.
#
# Cost guard: MAX_MIN is a ceiling, not a completion check. Hitting it means
# something is wrong, and the pod dies regardless.
# ============================================================================
set -euo pipefail

# This wrapper calls run_on_pod.sh, which has its own empty-argument and extra-argument
# guards - but those run on the POD, after money is already being spent renting it. The
# same ambiguities are worth refusing here too: an explicitly empty "$1" would otherwise
# default to 720 exactly like `${1:-720}` did in run_on_pod.sh before that was fixed, and
# `launch_pod.sh "" full` would rent a 720p full-render pod at a resolution nobody chose.
[ "$#" -le 2 ] || { echo "!! unexpected extra argument(s): ${*:3}"; exit 1; }
if [ "$#" -ge 1 ] && [ -z "${1:-}" ]; then
  echo "!! resolution was given but empty. Pass a resolution explicitly, e.g. 720."; exit 1
fi
if [ "$#" -ge 2 ] && [ -z "${2:-}" ]; then
  echo "!! mode was given but empty. Pass 'test' or 'full' explicitly."; exit 1
fi

RES="${1:-720}"
MODE="${2:-test}"     # deliberately NOT 'full' — the default here should be the cheap one
GPU="${GPU:-NVIDIA A40}"
MAX_MIN="${MAX_MIN:-150}"
IMAGE="${IMAGE:-runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04}"

[[ "$RES" =~ ^[0-9]+$ ]] && [ "$RES" -gt 0 ] || {
  echo "!! resolution must be a positive integer, got: '$RES'"; exit 1; }
case "$MODE" in test|full) ;; *) echo "!! unknown mode: '$MODE' (test|full)"; exit 1 ;; esac

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$MODE" in
  test) IN="$REPO/cloud/test_15s.mp4";  OUT_BASE="sr_test_${RES}" ;;
  full) IN="$REPO/input/full_169.mp4"; OUT_BASE="sr_out_${RES}"  ;;
esac

# Nonce-backed, not just OUT_BASE. The name was deterministic (hoon-sr_test_720 every
# time), and the by-name cleanup fallback below matches on it alone - so a second launch
# with the same RES/MODE running concurrently, or this cleanup running after `create pod`
# failed but left an orphan under that name from an EARLIER run, would delete a pod this
# invocation did not create. That directly breaks the "terminates ONLY the pod this script
# created" guarantee stated at the top. The nonce makes the name unique per launch while
# keeping the by-name fallback - which exists because POD_ID can be lost, see below -
# restricted to exactly this invocation.
POD_NAME="hoon-${OUT_BASE}-$$-$(date +%s)"
[ -f "$IN" ] || { echo "!! input not found: $IN"; exit 1; }
command -v runpodctl >/dev/null || { echo "!! runpodctl not on PATH"; exit 1; }
runpodctl pod list >/dev/null 2>&1 || {
  echo "!! runpodctl is not authenticated. runpodctl config --apiKey <key>"; exit 1; }

DEST="$REPO/cloud"
POD_ID=""
STATE="$REPO/cloud/.pod_id"          # gitignored; survives a crash so an orphan is findable

# ---------------------------------------------------------------------------
# Armed before the pod exists. If creation half-succeeds, or anything below dies,
# this still runs. Terminating a pod that never came up is a harmless no-op.
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  echo
  if [ -n "$POD_ID" ]; then
    echo "=== terminating pod $POD_ID ==="
    # `runpodctl pod delete` is the current spelling; `remove pod` is deprecated but
    # still works, so try both rather than depend on one CLI version.
    runpodctl pod delete "$POD_ID" >/dev/null 2>&1 \
      || runpodctl remove pod "$POD_ID" >/dev/null 2>&1 || true
  fi
  # Do not trust the exit status of the delete: confirm against the pod list, and sweep
  # anything left behind under our name in case the id was never parsed. A pod that
  # survives this is the only failure here that costs real money.
  local left
  left="$(runpodctl pod list -o json 2>/dev/null | grep -o "$POD_NAME" | head -1 || true)"
  if [ -n "$left" ]; then
    echo "!! a pod named $POD_NAME is still listed — removing by name"
    runpodctl remove pods "$POD_NAME" >/dev/null 2>&1 || true
    sleep 5
    if runpodctl pod list -o json 2>/dev/null | grep -q "$POD_NAME"; then
      echo "!! TERMINATION FAILED — a pod is STILL BILLING."
      echo "!! Terminate it now:  runpodctl pod delete ${POD_ID:-<id from runpodctl pod list>}"
      echo "!! Pod id, if known, is in $STATE"
      rc=1
    else
      echo "=== terminated (by name) ==="; rm -f "$STATE"
    fi
  else
    [ -n "$POD_ID" ] && { echo "=== terminated, confirmed absent from pod list ==="; rm -f "$STATE"; } || true
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

say() { printf '\n=== %s ===\n' "$*"; }
elapsed() { printf '%dm%02ds' $(( ($(date +%s) - T0) / 60 )) $(( ($(date +%s) - T0) % 60 )); }
T0=$(date +%s)

say "renting $GPU for ${RES}p ${MODE}  (ceiling ${MAX_MIN}min)"
CREATE="$(runpodctl create pod \
  --name "$POD_NAME" \
  --gpuType "$GPU" \
  --imageName "$IMAGE" \
  --containerDiskSize 60 \
  --volumeSize 60 \
  --mem 32 \
  --vcpu 8 \
  --secureCloud \
  --startSSH \
  --ports '22/tcp' \
  -o json 2>&1)" || { echo "$CREATE"; echo "!! pod creation failed"; exit 1; }

# `|| true` is load-bearing, not defensive noise. Under `set -euo pipefail` a grep that
# matches nothing fails the whole pipeline, and the failing command substitution exits the
# script BEFORE the diagnostic below can run - so a parse failure looked like a silent
# death with a live pod behind it. This is the exact trap CLAUDE.md documents; writing it
# again here is what the first run of this script found.
# Parse JSON first, then fall back to any pod-id-shaped token, since `create pod` does not
# always honour -o json.
POD_ID="$(printf '%s' "$CREATE" | python3 -c '
import json,re,sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    if isinstance(d, dict):
        for k in ("id", "podId"):
            if d.get(k): print(d[k]); raise SystemExit
        for v in d.values():
            if isinstance(v, dict) and v.get("id"): print(v["id"]); raise SystemExit
except Exception:
    pass
m = re.search(r"\b([a-z0-9]{12,20})\b", raw)
if m: print(m.group(1))
' 2>/dev/null || true)"
[ -n "$POD_ID" ] || {
  # Nothing to terminate if we could not learn the id — but say so loudly, because a
  # pod may well exist and be billing under a name we can still find.
  echo "$CREATE"
  echo "!! could not parse a pod id from the creation response."
  echo "!! CHECK FOR AN ORPHAN: runpodctl pod list   (look for $POD_NAME)"
  exit 1
}
echo "$POD_ID" > "$STATE"
echo "pod $POD_ID created (id also written to $STATE)"

# --- wait for SSH -----------------------------------------------------------
say "waiting for SSH"
SSH_HOST=""; SSH_PORT=""
for _ in $(seq 1 60); do
  J="$(runpodctl pod get "$POD_ID" -o json 2>/dev/null || true)"
  # `runpodctl pod get` returns ssh details in a top-level "ssh" object on this version
  # ("runtime" is null even when runtimeStatus is "running"). The first run of this script
  # waited ten minutes for a runtime.ports array that never appears. Both shapes are read,
  # newest first, so this survives the API changing back.
  SSH_HOST="$(printf '%s' "$J" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
for p in (d if isinstance(d,list) else [d]):
    sh = p.get("ssh") or {}
    if sh.get("ip") and sh.get("port"):
        print(sh["ip"], sh["port"]); raise SystemExit
    for prt in ((p.get("runtime") or {}).get("ports") or []):
        if prt.get("privatePort") == 22 and prt.get("ip") and prt.get("publicPort"):
            print(prt["ip"], prt["publicPort"]); raise SystemExit
' 2>/dev/null || true)"
  if [ -n "$SSH_HOST" ]; then
    SSH_PORT="${SSH_HOST##* }"; SSH_HOST="${SSH_HOST%% *}"
    break
  fi
  sleep 10
done
[ -n "$SSH_HOST" ] && [ -n "$SSH_PORT" ] || { echo "!! SSH never came up"; exit 1; }
echo "ssh root@$SSH_HOST -p $SSH_PORT  (after $(elapsed))"

# Be explicit about the identity. ~/.ssh/id_ed25519 and ~/.runpod/ssh/runpodctl-ssh-key
# are both registered on the account (runpodctl ssh list-keys); offering them by name
# avoids depending on what an agent happens to present first.
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
      -o ServerAliveInterval=30 -o ConnectTimeout=15)
[ -f "$HOME/.ssh/id_ed25519" ] && SSHO+=(-i "$HOME/.ssh/id_ed25519") || true
[ -f "$HOME/.runpod/ssh/runpodctl-ssh-key" ] && SSHO+=(-i "$HOME/.runpod/ssh/runpodctl-ssh-key") || true
rsh() { ssh "${SSHO[@]}" -p "$SSH_PORT" "root@$SSH_HOST" "$@"; }

# A bare `scp` under set -e turns one transient network blip into an immediate script
# exit, which - via the unconditional EXIT trap - deletes the pod. That is fine for the
# uploads (nothing unique exists there yet, retrying the whole script is cheap) but
# would be a real loss for the downloads: the render is complete and verified on the pod
# and a failed scp would destroy the only place that survives once the pod is gone.
scp_retry() {  # same args as scp
  local n=0 max=4 delay=10
  until scp "${SSHO[@]}" -P "$SSH_PORT" "$@"; do
    n=$((n + 1))
    [ "$n" -ge "$max" ] && return 1
    echo "  scp attempt $n failed, retrying in ${delay}s..." >&2
    sleep "$delay"
  done
}

for _ in $(seq 1 30); do rsh true 2>/dev/null && break; sleep 10; done
rsh true || { echo "!! SSH did not accept a command"; exit 1; }

# --- upload -----------------------------------------------------------------
say "uploading input and runner"
rsh 'mkdir -p /workspace/cloud'
scp_retry "$IN" "root@$SSH_HOST:/workspace/cloud/$(basename "$IN")"
scp_retry "$REPO/cloud/run_on_pod.sh" "root@$SSH_HOST:/workspace/cloud/run_on_pod.sh"

# --- render -----------------------------------------------------------------
# Detached on the pod so the SSH session is not the thing keeping it alive: a dropped
# connection should not kill a 45-minute render, and should not strand a live pod either.
say "starting render (${RES}p ${MODE})"
ENVS=""
[ -n "${BATCH_SIZE:-}" ]       && ENVS="$ENVS BATCH_SIZE=$BATCH_SIZE" || true
[ -n "${TEMPORAL_OVERLAP:-}" ] && ENVS="$ENVS TEMPORAL_OVERLAP=$TEMPORAL_OVERLAP" || true
[ -n "$ENVS" ] && echo "overrides:$ENVS" || true

# Capture $! so liveness can be checked by PID rather than by matching a command line.
# `pgrep -f "bash run_on_pod.sh"` was tried first and always reports alive, even with
# nothing running: the remote shell sshd spawns to run the pgrep command itself has that
# exact string in ITS OWN command line (it is right there in the quoted pattern), so
# `-f` matches the checker, not the checked. Reproduced locally: `bash -c 'pgrep -f
# "bash run_on_pod.sh" >/dev/null; echo $?'` prints 0 with no such process anywhere.
# docs/findings.md already records this exact self-match trap from a different script.
#
# The setup (cd, rm) and the backgrounded launch are deliberately SEPARATE statements,
# not chained with && into one backgrounded job. `A && B & echo $!` backgrounds the
# whole "A && B" as a subshell and $! captures THAT subshell's PID, not B's - confirmed
# locally: `cd /tmp && sleep N &` left $! pointing at a wrapper process whose child (a
# different PID) was the actual sleep. `kill -0` on the wrapper can behave differently
# from the real process's lifetime depending on shell/job-control internals neither this
# script nor the pod's shell should be trusted to pin down. Backgrounding the render
# command on its own line makes $! its PID directly, with nothing in between.
RENDER_PID="$(rsh "cd /workspace/cloud
rm -f ${OUT_BASE}.mp4 ${OUT_BASE}.json render.log
nohup env$ENVS bash run_on_pod.sh $RES $MODE > render.log 2>&1 < /dev/null &
echo \$!")"
[ -n "$RENDER_PID" ] || { echo "!! could not capture the render's PID"; exit 1; }

# --- poll for the manifest --------------------------------------------------
# The manifest is written last, after the frame check passes, so its existence means
# the render both finished and verified. Polling for the mp4 instead would race the
# encoder and download a partial file.
say "polling for completion"
MAN="/workspace/cloud/${OUT_BASE}.json"
DONE=0
while [ $(( ($(date +%s) - T0) / 60 )) -lt "$MAX_MIN" ]; do
  if rsh "test -f $MAN" 2>/dev/null; then DONE=1; break; fi
  # A dead process with no manifest means it failed; stop paying to poll a corpse.
  if ! rsh "kill -0 $RENDER_PID" 2>/dev/null; then
    sleep 5
    if rsh "test -f $MAN" 2>/dev/null; then DONE=1; break; fi
    say "the render exited without writing a manifest — last 40 lines"
    rsh 'tail -40 /workspace/cloud/render.log' 2>/dev/null || true
    exit 1
  fi
  printf '  %s  %s\n' "$(elapsed)" "$(rsh 'tail -1 /workspace/cloud/render.log' 2>/dev/null | tr -d '\r' | cut -c1-90)"
  sleep 30
done

[ "$DONE" -eq 1 ] || { say "hit the ${MAX_MIN}min ceiling without finishing"; \
  rsh 'tail -20 /workspace/cloud/render.log' 2>/dev/null || true; exit 1; }

say "render complete after $(elapsed) — downloading before anything else"
# On exhausted retries here, do NOT let the EXIT trap tear the pod down: the render is
# the only complete copy until the download and verification below both succeed, and
# destroying it over a transient network failure is a worse outcome than an idle pod the
# operator has to terminate by hand. `trap - EXIT INT TERM` clears the trap so plain
# `exit 1` does not invoke cleanup(); the pod id and manual recovery commands are printed
# instead.
if ! scp_retry "root@$SSH_HOST:$MAN" "$DEST/${OUT_BASE}.json" \
   || ! scp_retry "root@$SSH_HOST:/workspace/cloud/${OUT_BASE}.mp4" "$DEST/${OUT_BASE}.mp4"; then
  say "download failed after retries — leaving the pod running for manual recovery"
  echo "!! pod $POD_ID ($POD_NAME) still has the only complete copy of this render." >&2
  echo "!! Retry the download by hand:" >&2
  echo "!!   scp -P $SSH_PORT root@$SSH_HOST:$MAN $DEST/" >&2
  echo "!!   scp -P $SSH_PORT root@$SSH_HOST:/workspace/cloud/${OUT_BASE}.mp4 $DEST/" >&2
  echo "!! Terminate it yourself when you are done:  runpodctl pod delete $POD_ID" >&2
  trap - EXIT INT TERM
  exit 1
fi

# Verify against the manifest the pod itself wrote, before the pod is gone: a truncated
# transfer is indistinguishable from a truncated render once the evidence is deleted.
# Same reasoning as the retries above: a hash mismatch means the LOCAL copy is bad, not
# necessarily the render, so it is not evidence the pod's copy is bad too - leave the pod
# up rather than destroy the one place a clean copy is known to exist.
say "verifying transfer"
if ! python3 - "$DEST/${OUT_BASE}.json" "$DEST/${OUT_BASE}.mp4" <<'PY'
import hashlib, json, sys
man, mp4 = sys.argv[1], sys.argv[2]
m = json.load(open(man))
want = m["output"]["sha256"]
h = hashlib.sha256()
with open(mp4, "rb") as f:
    for b in iter(lambda: f.read(1 << 20), b""):
        h.update(b)
got = h.hexdigest()
print(f"  frames   {m['output']['frames']}  ({m['output']['width']}x{m['output']['height']})")
print(f"  expected {want}")
print(f"  got      {got}")
if got != want:
    sys.exit("!! TRANSFER CORRUPT — downloaded file does not match the manifest")
print("  transfer verified")
PY
then
  echo "!! pod $POD_ID ($POD_NAME) is being left running - the LOCAL copy is bad, not" >&2
  echo "!! necessarily the pod's, so retry the download by hand before assuming the" >&2
  echo "!! render itself is broken:" >&2
  echo "!!   scp -P $SSH_PORT root@$SSH_HOST:$MAN $DEST/" >&2
  echo "!!   scp -P $SSH_PORT root@$SSH_HOST:/workspace/cloud/${OUT_BASE}.mp4 $DEST/" >&2
  echo "!! Terminate it yourself when you are done:  runpodctl pod delete $POD_ID" >&2
  trap - EXIT INT TERM
  exit 1
fi

say "done in $(elapsed): $DEST/${OUT_BASE}.mp4"
# EXIT trap terminates the pod from here.
