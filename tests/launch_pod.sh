#!/bin/bash
# Exercise cloud/launch_pod.sh without a real pod or a real dollar.
#
# This script rents a GPU, so every mistake in it either wastes money (a billable pod
# created and torn down for nothing) or loses it (a pod left running with no recovery
# record, or an active render killed by a wrong guess). tests/cloud_pod.sh already
# established the pattern for driving a paid-cloud script against stubs; this does the
# same for the launcher one level up: runpodctl, ssh and scp are all fakes, and `sleep`
# is a no-op so a script with several real polling loops still runs in under a second.
#
#   bash tests/launch_pod.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib.sh"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
STUB="$W/stub"; mkdir -p "$STUB"
export STUB_STATE_DIR="$W/state"

# --- a fake repo, so the script's own $REPO-relative paths stay inside $W -------------
FAKEREPO="$W/repo"; mkdir -p "$FAKEREPO/cloud" "$FAKEREPO/input"
cp "$REPO/cloud/launch_pod.sh" "$FAKEREPO/cloud/"
printf '#!/bin/bash\necho "stub run_on_pod.sh"\n' > "$FAKEREPO/cloud/run_on_pod.sh"
echo "fake test clip" > "$FAKEREPO/cloud/test_15s.mp4"
echo "fake full clip" > "$FAKEREPO/input/full_169.mp4"
LAUNCH="$FAKEREPO/cloud/launch_pod.sh"

# --- a fixture manifest+mp4 whose hashes actually match, for the download/verify step --
FIX="$W/fixtures"; mkdir -p "$FIX"
echo "fake rendered bytes, deterministic" > "$FIX/out.mp4"
FIXSHA="$(sha256sum "$FIX/out.mp4" | cut -d' ' -f1)"
cat > "$FIX/out.json" <<JSON
{"output": {"sha256": "$FIXSHA", "frames": 214, "width": 1280, "height": 720}}
JSON
export STUB_FIXTURE_MANIFEST="$FIX/out.json"
export STUB_FIXTURE_MP4="$FIX/out.mp4"
# A second fixture whose mp4 does NOT match any manifest's sha256, for the corrupt-transfer case.
echo "corrupted bytes" > "$FIX/bad.mp4"
export STUB_FIXTURE_BAD_MP4="$FIX/bad.mp4"

# A distinct, internally-consistent second render (different bytes, different sha256), so
# a concurrent-publish test can tell whether the final pair is A's manifest with A's own
# video or B's with B's - or, if publication interleaved, a manifest from one paired with
# the video from the other.
echo "a completely different fake render, set B" > "$FIX/outB.mp4"
FIXSHA_B="$(sha256sum "$FIX/outB.mp4" | cut -d' ' -f1)"
cat > "$FIX/outB.json" <<JSON
{"output": {"sha256": "$FIXSHA_B", "frames": 214, "width": 1280, "height": 720}}
JSON
export STUB_FIXTURE_MANIFEST_B="$FIX/outB.json"
export STUB_FIXTURE_MP4_B="$FIX/outB.mp4"

# --- stubs -------------------------------------------------------------------
cat > "$STUB/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF

# Widens the publish critical section on demand (STUB_PUBLISH_DELAY), so a concurrent
# racing launch has a real window to interleave its own moves into the gap if - and only
# if - the two moves are not actually serialized by a lock around them. Real `mv`
# otherwise; only ever used at the two publish call sites in launch_pod.sh, so this
# cannot affect anything else the script does.
REALMV="$(command -v mv)"
REALSLEEP="$(command -v sleep)"
cat > "$STUB/mv" <<EOF
#!/bin/bash
"$REALMV" "\$1" "\$2"
if [ -n "\${STUB_PUBLISH_DELAY:-}" ] && [[ "\$2" == *.json ]]; then
  "$REALSLEEP" "\$STUB_PUBLISH_DELAY"
fi
EOF

cat > "$STUB/runpodctl" <<'EOF'
#!/bin/bash
mkdir -p "$STUB_STATE_DIR"
echo "$*" >> "$STUB_STATE_DIR/runpodctl_calls.log"
case "$1 $2" in
  "pod list")
    # STUB_POD_LIST_FAIL only affects the `-o json` form cleanup() uses to confirm
    # termination - not the plain `pod list` the script's own auth check makes at
    # startup, which a test simulating an API outage during CLEANUP still needs to pass.
    if [[ "$*" == *"-o json"* ]]; then
      if [ "${STUB_POD_LIST_FAIL:-0}" = "1" ]; then
        echo "error: could not reach RunPod API" >&2
        exit 1
      fi
      # "self" stands in for whatever --name this run's own `create pod` call actually
      # used - the real POD_NAME is a nonce (hoon-<out_base>-$$-<timestamp>), unknown to
      # the test in advance, so it is captured off the real create-pod invocation below
      # rather than guessed at here.
      if [ "${STUB_POD_LIST_CONTAINS:-}" = "self" ] && [ ! -f "$STUB_STATE_DIR/pod_removed" ]; then
        NAME="$(cat "$STUB_STATE_DIR/last_pod_name" 2>/dev/null || true)"
        [ -n "$NAME" ] && echo "[{\"id\":\"${STUB_POD_ID:-podabc123456}\",\"name\":\"$NAME\"}]" || echo "[]"
      elif [ -n "${STUB_POD_LIST_CONTAINS:-}" ] && [ ! -f "$STUB_STATE_DIR/pod_removed" ]; then
        echo "[{\"id\":\"${STUB_POD_ID:-podabc123456}\",\"name\":\"${STUB_POD_LIST_CONTAINS}\"}]"
      else
        echo "[]"
      fi
    fi
    exit 0 ;;
  "create pod")
    prev=""
    for a in "$@"; do [ "$prev" = "--name" ] && printf '%s' "$a" > "$STUB_STATE_DIR/last_pod_name"; prev="$a"; done
    case "${STUB_CREATE_SHAPE:-dict_id}" in
      dict_id)  echo "{\"id\":\"${STUB_POD_ID:-podabc123456}\"}" ;;
      nested)   echo "{\"pod\":{\"id\":\"${STUB_POD_ID:-podabc123456}\"}}" ;;
      non_json) echo "Pod created successfully with id ${STUB_POD_ID:-podabc123456} in region US-CA" ;;
      unparseable) echo "no id-shaped token anywhere in this line at all" ;;
      deeply_nested_with_decoy)
        # "id" three levels deep, with an unrelated but same-shaped token (a decoy
        # machineId) appearing EARLIER in the raw text - the shallow (top-level or
        # one-level-nested) search finds neither and falls to the raw-text regex, which
        # would grab the decoy first since it comes first in the string. Only a
        # recursive JSON search finds the real id correctly regardless of depth or order.
        echo "{\"data\":{\"machineId\":\"decoytoken12\",\"pod\":{\"details\":{\"id\":\"${STUB_POD_ID:-podabc123456}\"}}}}" ;;
    esac
    exit 0 ;;
  "pod get")
    case "${STUB_SSH_SHAPE:-ssh_object}" in
      ssh_object)     echo "{\"ssh\":{\"ip\":\"127.0.0.1\",\"port\":${STUB_SSH_PORT:-2222}}}" ;;
      runtime_ports)  echo "{\"runtime\":{\"ports\":[{\"privatePort\":22,\"ip\":\"127.0.0.1\",\"publicPort\":${STUB_SSH_PORT:-2222}}]}}" ;;
      none)           echo "{}" ;;
    esac
    exit 0 ;;
  "pod delete")
    [ "${STUB_DELETE_FAIL:-0}" = "0" ] && touch "$STUB_STATE_DIR/pod_removed"
    exit "${STUB_DELETE_FAIL:-0}" ;;
  "remove pod")
    # The id-based fallback (tried when `pod delete` fails), independent of
    # STUB_REMOVE_FAIL below - which controls the BY-NAME fallback instead, so a test can
    # make one succeed while the other fails and actually exercise a specific path.
    [ "${STUB_REMOVE_ID_FAIL:-0}" = "0" ] && touch "$STUB_STATE_DIR/pod_removed"
    exit "${STUB_REMOVE_ID_FAIL:-0}" ;;
  "remove pods")
    # A real removal takes a moment to be reflected; the script sleeps 5s and re-lists
    # itself, so the stub does not need to fake that delay - only the eventual outcome.
    [ "${STUB_REMOVE_FAIL:-0}" = "0" ] && touch "$STUB_STATE_DIR/pod_removed"
    exit "${STUB_REMOVE_FAIL:-0}" ;;
  *) exit 0 ;;
esac
EOF

cat > "$STUB/ssh" <<'EOF'
#!/bin/bash
# The remote command is always the LAST argument, however many -o/-i/-p flags precede it.
cmd="${@: -1}"
mkdir -p "$STUB_STATE_DIR"
case "$cmd" in
  true)
    f="$STUB_STATE_DIR/ssh_ready_attempts"
    [ -f "$f" ] || echo 0 > "$f"
    c=$(cat "$f")
    if [ "$c" -ge "${STUB_SSH_READY_AFTER:-0}" ]; then exit 0
    else echo $((c+1)) > "$f"; exit 255; fi ;;
  *mkdir*) exit 0 ;;
  *'echo $!'*) echo "${STUB_RENDER_PID:-42424}"; exit 0 ;;
  *'kill -0'*)
    case "${STUB_KILL0:-alive}" in
      alive) exit 0 ;;
      dead)  exit 1 ;;
      transport_then_alive)
        f="$STUB_STATE_DIR/kill0_attempts"
        [ -f "$f" ] || echo 0 > "$f"
        c=$(cat "$f")
        if [ "$c" -lt "${STUB_TRANSPORT_FAILS:-1}" ]; then echo $((c+1)) > "$f"; exit 255
        else exit 0; fi ;;
      transport_forever) exit 255 ;;
    esac ;;
  *'test -f'*)
    f="$STUB_STATE_DIR/manifest_polls"
    [ -f "$f" ] || echo 0 > "$f"
    c=$(cat "$f")
    echo $((c+1)) > "$f"
    if [ "$c" -ge "${STUB_MANIFEST_AFTER:-0}" ]; then exit 0; else exit 1; fi ;;
  *'tail -40'*|*'tail -1'*) echo "stub render log line"; exit 0 ;;
  *) exit 0 ;;
esac
EOF

cat > "$STUB/scp" <<'EOF'
#!/bin/bash
mkdir -p "$STUB_STATE_DIR"
src="${@: -2:1}"
dest="${@: -1}"
case "$dest" in
  *:*) kind=upload ;;
  *)   kind=download ;;
esac
if [ "$kind" = upload ]; then
  f="$STUB_STATE_DIR/scp_upload_attempts"
  [ -f "$f" ] || echo 0 > "$f"
  c=$(cat "$f"); echo $((c+1)) > "$f"
  [ "$c" -lt "${STUB_SCP_UPLOAD_FAILS:-0}" ] && exit 1
  exit 0
else
  f="$STUB_STATE_DIR/scp_download_attempts"
  [ -f "$f" ] || echo 0 > "$f"
  c=$(cat "$f"); echo $((c+1)) > "$f"
  [ "${STUB_SCP_DOWNLOAD_ALWAYS_FAIL:-0}" = "1" ] && exit 1
  [ "$c" -lt "${STUB_SCP_DOWNLOAD_FAILS:-0}" ] && exit 1
  case "$src" in
    *.json)
      if [ "${STUB_FIXTURE_SET:-A}" = "B" ]; then cp "$STUB_FIXTURE_MANIFEST_B" "$dest"
      else cp "$STUB_FIXTURE_MANIFEST" "$dest"; fi ;;
    *.mp4)
      if [ "${STUB_DOWNLOAD_BAD_MP4:-0}" = "1" ]; then cp "$STUB_FIXTURE_BAD_MP4" "$dest"
      elif [ "${STUB_FIXTURE_SET:-A}" = "B" ]; then cp "$STUB_FIXTURE_MP4_B" "$dest"
      else cp "$STUB_FIXTURE_MP4" "$dest"; fi ;;
  esac
  exit 0
fi
EOF

chmod +x "$STUB"/*

echo "launch_pod runner"
echo

# Each case starts clean: prior state files, downloaded artefacts, and stub attempt
# counters must not leak between cases.
clean() {
  rm -rf "$STUB_STATE_DIR" "$FAKEREPO/cloud"/.pod_id_* "$FAKEREPO/cloud"/.*.sr_*.json \
    "$FAKEREPO/cloud"/.*.sr_*.mp4 "$FAKEREPO/cloud"/sr_*.mp4 "$FAKEREPO/cloud"/sr_*.json
  mkdir -p "$STUB_STATE_DIR"
}

run_launch() {  # env... -- args to launch_pod.sh
  clean
  env PATH="$STUB:$PATH" "$@" 2>&1
}

# Every preflight guard below claims to refuse BEFORE `runpodctl create pod` is ever
# invoked - the whole reason these guards exist here rather than relying on run_on_pod.sh's
# own copies, which only run after a pod is already billing. That invariant was never
# actually checked: the guards below asserted only the diagnostic message and/or exit
# status, so a regression that printed the right refusal AND created the pod anyway would
# still have passed every one of them. This helper checks all three: nonzero exit, the
# expected message, and no "create pod" line in the same run's runpodctl call log.
assert_refused_before_billing() {  # name pattern env... -- args
  local name="$1" pat="$2"; shift 2
  clean
  local out status calls
  out="$(env PATH="$STUB:$PATH" "$@" 2>&1)"; status=$?
  calls="$(cat "$STUB_STATE_DIR/runpodctl_calls.log" 2>/dev/null || true)"
  if [ "$status" -eq 0 ]; then
    bad "$name" "exited 0 - it printed a message but did not refuse"
  elif [[ "$calls" == *"create pod"* ]]; then
    bad "$name" "a pod was created despite the refusal: $calls"
  else
    case "$out" in
      *"$pat"*) ok "$name" ;;
      *) bad "$name" "exit $status, but no '$pat' in: $(printf '%s' "$out" | tail -1)" ;;
    esac
  fi
}

# --- preflight guards, refused before anything billable happens --------------------
# These mirror run_on_pod.sh's own empty-argument standard, applied here too since this
# wrapper spends money before run_on_pod.sh's guards ever run on the pod.
assert_refused_before_billing "guard: an explicitly empty resolution is refused" \
  "resolution was given but empty" \
  bash "$LAUNCH" ""

assert_refused_before_billing "guard: an explicitly empty mode is refused" \
  "mode was given but empty" \
  bash "$LAUNCH" 720 ""

assert_refused_before_billing "guard: extra arguments are refused" \
  "unexpected extra argument" \
  bash "$LAUNCH" 720 test extra

assert_refused_before_billing "guard: a non-integer resolution is refused" \
  "resolution must be a positive integer" \
  bash "$LAUNCH" abc test

assert_refused_before_billing "guard: an unknown mode is refused" \
  "unknown mode" \
  bash "$LAUNCH" 720 tset

# MAX_MIN: reviewed as unvalidated, unlike RES - a non-integer or non-positive value used
# to reach the polling loop's `[ N -lt "$MAX_MIN" ]` unchecked, which silently skips the
# loop entirely (bash's `[` errors "integer expected" and returns false) rather than
# raising - so the ceiling-exceeded path ran immediately, after a real pod had already
# been created.
for bad in abc 0 -5; do
  assert_refused_before_billing "guard: MAX_MIN='$bad' is refused before pod creation" \
    "MAX_MIN must be a positive integer" \
    env MAX_MIN="$bad" bash "$LAUNCH" 720 test
done

# BATCH_SIZE/TEMPORAL_OVERLAP: spliced unquoted into a remote shell command string later
# in the script - unvalidated, "17 --debug_leak" would reach that remote shell verbatim.
# Refused here too, before pod creation, with the same guard run_on_pod.sh applies on the
# pod itself.
for v in BATCH_SIZE TEMPORAL_OVERLAP; do
  assert_refused_before_billing "guard: $v with an embedded flag is refused" \
    "$v must be a positive integer" \
    env "$v=17 --debug_leak" bash "$LAUNCH" 720 test
done

# --- pod-creation response parsing: every shape the real API has returned -----------
for shape in dict_id nested non_json; do
  out="$(run_launch env STUB_CREATE_SHAPE="$shape" STUB_MANIFEST_AFTER=0 \
    PATH="$STUB:$PATH" bash "$LAUNCH" 720 test)"
  case "$out" in
    *"done in"*) ok "creation response: '$shape' shape parses to a usable pod id" ;;
    *) bad "creation response: '$shape' shape parses to a usable pod id" \
           "$(printf '%s' "$out" | tail -3 | head -1)" ;;
  esac
done

out="$(run_launch env STUB_CREATE_SHAPE=unparseable PATH="$STUB:$PATH" bash "$LAUNCH" 720 test)"
case "$out" in
  *"could not parse a pod id"*) ok "creation response: an unparseable response is reported, not silently ignored" ;;
  *) bad "creation response: an unparseable response is reported, not silently ignored" \
         "$(printf '%s' "$out" | tail -1)" ;;
esac

# The id sits three levels deep, and an unrelated same-shaped token (a decoy machineId)
# appears earlier in the raw text - a shallow (top-level or one-level-nested) JSON search
# finds neither the real id nor a reason to keep looking, and falls to the raw-text regex,
# which would grab the decoy first since it comes first in the string. Checked directly
# against the runpodctl call log, not just "did the run finish" - a wrong id still lets
# the by-name fallback in cleanup() find and terminate the real pod, so a merely-successful
# run does not by itself prove the RIGHT id was used anywhere upstream of that fallback.
run_launch env STUB_CREATE_SHAPE=deeply_nested_with_decoy PATH="$STUB:$PATH" bash "$LAUNCH" 720 test >/dev/null
CALLS="$(cat "$STUB_STATE_DIR/runpodctl_calls.log" 2>/dev/null || true)"
case "$CALLS" in
  *"pod delete podabc123456"*) ok "creation response: the real id is found however deeply it is nested, not a same-shaped decoy" ;;
  *"pod delete decoytoken12"*) bad "creation response: the real id is found however deeply it is nested, not a same-shaped decoy" \
         "deleted the decoy token instead of the real pod id" ;;
  *) bad "creation response: the real id is found however deeply it is nested, not a same-shaped decoy" \
         "no delete call recorded: $CALLS" ;;
esac

# --- SSH-details response parsing: both shapes the real API has used ----------------
for shape in ssh_object runtime_ports; do
  out="$(run_launch env STUB_SSH_SHAPE="$shape" PATH="$STUB:$PATH" bash "$LAUNCH" 720 test)"
  case "$out" in
    *"done in"*) ok "SSH details: '$shape' shape is read" ;;
    *) bad "SSH details: '$shape' shape is read" "$(printf '%s' "$out" | tail -3 | head -1)" ;;
  esac
done

# --- the happy path, end to end -----------------------------------------------------
out="$(run_launch env PATH="$STUB:$PATH" bash "$LAUNCH" 720 test)"
case "$out" in
  *"done in"*"sr_test_720.mp4"*) ok "happy path: completes and publishes the named deliverable" ;;
  *) bad "happy path: completes and publishes the named deliverable" "$(printf '%s' "$out" | tail -3 | head -1)" ;;
esac
[ -f "$FAKEREPO/cloud/sr_test_720.mp4" ] && [ -f "$FAKEREPO/cloud/sr_test_720.json" ] \
  && ok "happy path: both deliverable files are on disk under their final names" \
  || bad "happy path: both deliverable files are on disk under their final names" "missing"
# No per-invocation staging debris should survive a successful run.
if ls "$FAKEREPO"/cloud/.*.sr_*.* >/dev/null 2>&1; then
  bad "happy path: no staged-download temp files survive a successful run" "$(ls "$FAKEREPO"/cloud/.*.sr_*.* )"
else
  ok "happy path: no staged-download temp files survive a successful run"
fi
if ls "$FAKEREPO"/cloud/.pod_id_* >/dev/null 2>&1; then
  bad "happy path: the state file is removed once termination is confirmed" "$(ls "$FAKEREPO"/cloud/.pod_id_*)"
else
  ok "happy path: the state file is removed once termination is confirmed"
fi

# --- concurrent publish must not interleave -----------------------------------------
# Per-invocation staging (above) stops two concurrent launches of the same RES/MODE
# corrupting each other's DOWNLOADS, but OUT_BASE - the final published name - is
# deliberately shared, not nonce-keyed, so both still publish to the same two paths.
# Without a lock around the two-mv publish, one launch's own pair of moves can
# interleave with the other's: A's manifest ends up on disk next to B's video, or the
# reverse. Two genuinely concurrent launches of the same output, one carrying fixture
# set A and delayed (via the stub `mv`) between its own two moves specifically to widen
# that window, the other carrying a distinct fixture set B and undelayed - if
# publication is not serialized, B's fast pair has a real chance to land inside A's
# artificially-widened gap.
# B is launched the instant A's json appears at the final destination - guaranteed still
# inside A's artificially-widened gap before its own mp4 move - rather than after a guessed
# time delay, so this does not depend on absolute scheduling timing to land the race.
clean
env PATH="$STUB:$PATH" STUB_PUBLISH_DELAY=2 bash "$LAUNCH" 720 test > "$W/raceA.log" 2>&1 &
RACE_A=$!
for _ in $(seq 1 100); do
  [ -f "$FAKEREPO/cloud/sr_test_720.json" ] && break
  sleep 0.05
done
env PATH="$STUB:$PATH" STUB_FIXTURE_SET=B bash "$LAUNCH" 720 test > "$W/raceB.log" 2>&1 &
RACE_B=$!
wait "$RACE_A" 2>/dev/null; wait "$RACE_B" 2>/dev/null
if [ -f "$FAKEREPO/cloud/sr_test_720.json" ] && [ -f "$FAKEREPO/cloud/sr_test_720.mp4" ]; then
  PUB_WANT="$(python3 -c "import json; print(json.load(open('$FAKEREPO/cloud/sr_test_720.json'))['output']['sha256'])")"
  PUB_GOT="$(sha256sum "$FAKEREPO/cloud/sr_test_720.mp4" | cut -d' ' -f1)"
  if [ "$PUB_WANT" = "$PUB_GOT" ]; then
    ok "publish: two concurrent launches of the same output never interleave a mismatched pair"
  else
    bad "publish: two concurrent launches of the same output never interleave a mismatched pair" \
        "published manifest sha ($PUB_WANT) does not match the published video's actual sha ($PUB_GOT)"
  fi
else
  bad "publish: two concurrent launches of the same output never interleave a mismatched pair" \
      "expected deliverables missing after both launches: $(ls "$FAKEREPO/cloud" 2>&1)"
fi

# --- signal-triggered cleanup --------------------------------------------------------
# A SIGTERM mid-poll must still terminate the pod - the EXIT trap covers INT and TERM too.
clean
env PATH="$STUB:$PATH" STUB_MANIFEST_AFTER=1000000 STUB_KILL0=alive \
  bash "$LAUNCH" 720 test > "$W/sigterm.log" 2>&1 &
LPID=$!
for _ in $(seq 1 50); do
  grep -q "polling for completion" "$W/sigterm.log" 2>/dev/null && break
  sleep 0.1
done
kill -TERM "$LPID" 2>/dev/null
wait "$LPID" 2>/dev/null; TERM_EXIT=$?
if grep -q "terminating pod" "$W/sigterm.log"; then
  ok "signal: SIGTERM mid-poll still terminates the pod"
else
  bad "signal: SIGTERM mid-poll still terminates the pod" "$(tail -3 "$W/sigterm.log")"
fi
# Binding cleanup directly to INT/TERM meant its own `local rc=$?` captured whatever
# command happened to finish immediately before the ASYNCHRONOUS signal arrived - which
# can easily be 0 - not the signal itself. A pod torn down mid-render by a caught signal
# used to report the whole launcher's exit status as 0: success, to anything checking $?.
# Reproduced directly with an isolated construct (a `true` immediately before a `sleep`
# that gets SIGTERM'd) before fixing. The conventional 128+signal status (143 for TERM)
# is what a caller - a supervising watchdog, a CI step - should see instead.
if [ "$TERM_EXIT" -eq 143 ]; then
  ok "signal: a SIGTERM exit reports the conventional 143, not whatever preceded it"
else
  bad "signal: a SIGTERM exit reports the conventional 143, not whatever preceded it" \
      "exit was $TERM_EXIT"
fi
# cleanup() ends in `exit $rc`, and `exit` fires the EXIT trap even when called from
# inside the handler a caught signal already invoked - so a single SIGTERM used to run
# the whole function TWICE (once as the INT/TERM handler, again via its own exit),
# doubling every delete/list/sleep in it. One signal must produce exactly one cleanup.
TERM_COUNT="$(grep -c "terminating pod" "$W/sigterm.log")"
if [ "$TERM_COUNT" -eq 1 ]; then
  ok "signal: SIGTERM triggers cleanup exactly once, not twice"
else
  bad "signal: SIGTERM triggers cleanup exactly once, not twice" \
      "\"terminating pod\" appeared $TERM_COUNT times"
fi

# --- cleanup vs. a failed pod-list call ---------------------------------------------
# A failed `pod list` during cleanup used to be indistinguishable from a successful list
# that found nothing - both collapsed to an empty match, and empty meant "confirmed
# absent, delete the recovery file". Reproduced directly and fixed: the state file must
# now survive a pod-list failure, since the pod may still be billing.
out="$(run_launch env PATH="$STUB:$PATH" STUB_POD_LIST_FAIL=1 bash "$LAUNCH" 720 test)"
case "$out" in
  *"could not confirm"*) ok "cleanup: a failed pod-list call is reported, not treated as absence" ;;
  *) bad "cleanup: a failed pod-list call is reported, not treated as absence" \
         "$(printf '%s' "$out" | tail -3 | head -1)" ;;
esac
if ls "$FAKEREPO"/cloud/.pod_id_* >/dev/null 2>&1; then
  ok "cleanup: the state file survives a pod-list failure"
else
  bad "cleanup: the state file survives a pod-list failure" "state file was deleted anyway"
fi

# --- the by-name fallback, and the path that never reaches it ------------------------
# The id-based delete fails (STUB_DELETE_FAIL), but the pod is still listed under its own
# nonce-backed name (STUB_POD_LIST_CONTAINS=self) - this is the fallback that exists
# because POD_ID can be unreliable or never learned at all, and it was never directly
# exercised by any prior test despite the stub already supporting it.
clean
out="$(env PATH="$STUB:$PATH" STUB_DELETE_FAIL=1 STUB_REMOVE_ID_FAIL=1 STUB_POD_LIST_CONTAINS=self \
  bash "$LAUNCH" 720 test 2>&1)"
case "$out" in
  *"still listed"*"removing by name"*"terminated (by name)"*) \
    ok "cleanup: an id-based delete failure falls back to removal by the nonce-backed name" ;;
  *) bad "cleanup: an id-based delete failure falls back to removal by the nonce-backed name" \
         "$(printf '%s' "$out" | tail -4 | head -1)" ;;
esac
if ls "$FAKEREPO"/cloud/.pod_id_* >/dev/null 2>&1; then
  bad "cleanup: the state file is removed once the by-name fallback succeeds" \
      "state file survived a successful by-name removal"
else
  ok "cleanup: the state file is removed once the by-name fallback succeeds"
fi

# --- both removal paths failing: STILL BILLING, and the launcher must say so ----------
clean
out="$(env PATH="$STUB:$PATH" STUB_DELETE_FAIL=1 STUB_REMOVE_ID_FAIL=1 STUB_REMOVE_FAIL=1 STUB_POD_LIST_CONTAINS=self \
  bash "$LAUNCH" 720 test 2>&1)"; BILLING_EXIT=$?
case "$out" in
  *"TERMINATION FAILED"*"STILL BILLING"*) ok "cleanup: a persistent removal failure reports STILL BILLING" ;;
  *) bad "cleanup: a persistent removal failure reports STILL BILLING" \
         "$(printf '%s' "$out" | tail -4 | head -1)" ;;
esac
if ls "$FAKEREPO"/cloud/.pod_id_* >/dev/null 2>&1; then
  ok "cleanup: the recovery record survives when the pod could not be confirmed terminated"
else
  bad "cleanup: the recovery record survives when the pod could not be confirmed terminated" \
      "state file was deleted despite the pod still being listed"
fi
if [ "$BILLING_EXIT" -ne 0 ]; then
  ok "cleanup: the launcher's own exit status reflects a pod that could not be terminated"
else
  bad "cleanup: the launcher's own exit status reflects a pod that could not be terminated" \
      "exited 0 despite STILL BILLING"
fi

# --- SSH transport failure vs a genuinely dead render -------------------------------
# A transient SSH disconnect during `kill -0` must be retried, not treated as proof the
# render died - and a real dead process (a normal, successful `kill -0` answer of "no
# such process") must still be caught.
clean
out="$(env PATH="$STUB:$PATH" STUB_KILL0=transport_then_alive STUB_TRANSPORT_FAILS=2 \
  STUB_MANIFEST_AFTER=5 bash "$LAUNCH" 720 test 2>&1)"
case "$out" in
  *"done in"*) ok "polling: a transient SSH disconnect during kill-0 is retried, not fatal" ;;
  *) bad "polling: a transient SSH disconnect during kill-0 is retried, not fatal" \
         "$(printf '%s' "$out" | tail -3 | head -1)" ;;
esac

clean
out="$(env PATH="$STUB:$PATH" STUB_KILL0=transport_forever STUB_MANIFEST_AFTER=1000 \
  bash "$LAUNCH" 720 test 2>&1)"
case "$out" in
  *"cannot reach the pod"*"not being torn down"*) ok "polling: SSH unreachable after retries leaves the pod running, not torn down" ;;
  *"terminating pod"*) bad "polling: SSH unreachable after retries leaves the pod running, not torn down" \
         "the pod was torn down on an unconfirmed signal" ;;
  *) bad "polling: SSH unreachable after retries leaves the pod running, not torn down" \
         "$(printf '%s' "$out" | tail -3 | head -1)" ;;
esac
if ls "$FAKEREPO"/cloud/.pod_id_* >/dev/null 2>&1; then
  ok "polling: the state file survives an unconfirmed (not torn down) exit"
else
  bad "polling: the state file survives an unconfirmed (not torn down) exit" "state file was deleted"
fi

clean
out="$(run_launch env PATH="$STUB:$PATH" STUB_KILL0=dead STUB_MANIFEST_AFTER=1000 \
  bash "$LAUNCH" 720 test)"
case "$out" in
  *"exited without writing a manifest"*"terminating pod"*) \
    ok "polling: a genuinely dead render is still caught and the pod torn down" ;;
  *) bad "polling: a genuinely dead render is still caught and the pod torn down" \
         "$(printf '%s' "$out" | tail -3 | head -1)" ;;
esac

# --- download and verification failures must preserve the pod ----------------------
out="$(run_launch env PATH="$STUB:$PATH" STUB_SCP_DOWNLOAD_ALWAYS_FAIL=1 bash "$LAUNCH" 720 test)"
case "$out" in
  *"leaving the pod running for manual recovery"*) ok "download: a persistent scp failure leaves the pod running" ;;
  *) bad "download: a persistent scp failure leaves the pod running" "$(printf '%s' "$out" | tail -3 | head -1)" ;;
esac
if grep -q "terminating pod" <<<"$out"; then
  bad "download: a persistent scp failure does not tear down the pod" "it was torn down anyway"
else
  ok "download: a persistent scp failure does not tear down the pod"
fi

out="$(run_launch env PATH="$STUB:$PATH" STUB_DOWNLOAD_BAD_MP4=1 bash "$LAUNCH" 720 test)"
case "$out" in
  *"TRANSFER CORRUPT"*"is being left running"*) ok "verify: a hash mismatch leaves the pod running rather than trusting a bad transfer" ;;
  *) bad "verify: a hash mismatch leaves the pod running rather than trusting a bad transfer" \
         "$(printf '%s' "$out" | tail -3 | head -1)" ;;
esac

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%d passed\033[0m\n' "$PASS"
else
  printf '\033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$PASS" "$FAIL"
fi
[ "$FAIL" -eq 0 ]
