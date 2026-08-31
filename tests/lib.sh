# Shared helpers for the test suite. Sourced by run.sh.
#
# Everything here is synthetic and tiny: no GPU, no model, and no dependency on the
# media in input/ or masters/, so the suite runs anywhere in seconds.

PASS=0; FAIL=0; FAILED_NAMES=()

# The scripts under test call `python`. Prefer the repo venv if one exists.
if [ -x "$REPO/.venv/bin/python" ]; then
  export PATH="$REPO/.venv/bin:$PATH"
fi

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; }

assert_eq() {  # name expected actual
  [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"
}

assert_under() {  # name limit actual  — actual must be < limit
  if python -c "import sys; sys.exit(0 if $3 < $2 else 1)" 2>/dev/null
  then ok "$1 ($3 < $2)"; else bad "$1" "expected < $2, got $3"; fi
}

assert_exits_nonzero() {  # name description command...
  local name="$1" desc="$2"; shift 2
  if "$@" >/dev/null 2>&1; then bad "$name" "$desc — command succeeded but should have failed"
  else ok "$name"; fi
}

assert_stderr_matches() {  # name pattern command...
  local name="$1" pat="$2"; shift 2
  local out; out="$("$@" 2>&1 || true)"
  case "$out" in *"$pat"*) ok "$name" ;; *) bad "$name" "no '$pat' in: $(printf '%s' "$out" | tail -1)" ;; esac
}

# --- fixtures ---------------------------------------------------------------

# Frame presentation times of a video, one per line.
pts_of() {
  ffprobe -v error -select_streams v:0 -show_entries frame=pts_time -of csv=p=0 "$1" \
    | tr -d ',' | grep -v '^$'
}

frame_count() {
  ffprobe -v error -select_streams v:0 -count_packets \
    -show_entries stream=nb_read_packets -of csv=p=0 "$1"
}

duration_of() {
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"
}

# A variable-frame-rate clip with a real stall, built by dropping frames from a CFR
# source. Every gap is then an exact multiple of 1/15, which is the property the real
# Nokia footage has and the one the timing code must preserve.
# A second stall is not redundant: state carried between stalls has been wrong before
# while a single-stall clip still passed, because the first stall works and only later
# ones fail.
#   mk_vfr_source <out.mp4> <total_cfr_frames> <drop_from> <drop_to> [from2] [to2]
mk_vfr_source() {
  local out="$1" total="$2" from="$3" to="$4" from2="${5:-}" to2="${6:-}"
  local sel="not(between(n,$from,$to))"
  [ -n "$from2" ] && sel="$sel*not(between(n,$from2,$to2))"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=64x36:r=15:d=20" \
    -frames:v "$total" -c:v libx264 -crf 20 -pix_fmt yuv420p "$out.cfr.mp4"
  ffmpeg -hide_banner -loglevel error -y -i "$out.cfr.mp4" \
    -vf "select='$sel'" -fps_mode passthrough \
    -c:v libx264 -crf 20 -pix_fmt yuv420p "$out"
  rm -f "$out.cfr.mp4"
}

# Stands in for the model's output: same frame count, any content.
#   mk_upscaled <out.mp4> <frames>
mk_upscaled() {
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=64x36:r=15:d=20" \
    -frames:v "$2" -c:v libx264 -crf 20 -pix_fmt yuv420p "$1"
}

# A run of PNGs, for exercising the concat stage directly.
#   mk_pngs <dir> <count>
mk_pngs() {
  local d="$1"; mkdir -p "$d"
  for i in $(seq 1 "$2"); do
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=gray:s=64x36" \
      -frames:v 1 "$(printf '%s/f_%06d.png' "$d" "$i")"
  done
}
