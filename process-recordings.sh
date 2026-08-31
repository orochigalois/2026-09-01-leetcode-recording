#!/bin/bash
#
# Watches nothing by itself — it is invoked by the launchd agent whenever the
# repo folder changes. It picks up any new (unprocessed) video, speeds it up 8x,
# deletes the original, and pushes the result to GitHub.
#
# Rename rule: <YYYY-MM-DD>-<HH>-<original name>.mp4   (HH = 24h, parsed from
# the date/time already embedded in the filename; falls back to mtime if the
# filename doesn't match the expected "at H.MM.SS am/pm" pattern)
#   "Screen Recording 2026-09-01 at 8.19.31 pm.mov"
#     -> "2026-09-01-20-Screen Recording 2026-09-01 at 8.19.31 pm.mp4"

set -uo pipefail

# launchd gives a minimal PATH, so be explicit.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR" || exit 1

LOG="$REPO_DIR/.process-recordings.log"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# --- single instance lock (mkdir is atomic; macOS has no flock) ---------------
LOCKDIR="/tmp/leetcode-recording.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  exit 0   # another run is already working
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

SPEED=8
PROCESSED_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-'
EXTS="mov mp4 m4v mkv avi"

# --- wait until a file has stopped growing (still recording / still copying) --
wait_until_stable() {
  local f="$1" last=-1 size
  for _ in $(seq 1 60); do
    size=$(stat -f %z "$f" 2>/dev/null) || return 1
    [ "$size" = "$last" ] && [ "$size" -gt 0 ] && return 0
    last="$size"
    sleep 2
  done
  return 1
}

shopt -s nullglob nocaseglob nocasematch

# --- pull the timestamp out of the filename itself, e.g.:            ---------
#   "Screen Recording 2026-09-01 at 8.19.31 pm.mov" -> "2026-09-01-20"
# Falls back to file mtime if the name doesn't match that pattern.
stamp_from_name() {
  local n="$1"
  # macOS names sometimes use a narrow no-break space (U+202F) before am/pm
  n="${n//$'\xe2\x80\xaf'/ }"
  if [[ "$n" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2})\ at\ ([0-9]{1,2})\.[0-9]{2}\.[0-9]{2}\ (am|pm) ]]; then
    local date_part="${BASH_REMATCH[1]}" hour12="${BASH_REMATCH[2]}" ampm="${BASH_REMATCH[3],,}"
    local hour24=$((10#$hour12))
    if [ "$ampm" = "pm" ] && [ "$hour24" -ne 12 ]; then
      hour24=$((hour24 + 12))
    elif [ "$ampm" = "am" ] && [ "$hour24" -eq 12 ]; then
      hour24=0
    fi
    printf '%s-%02d' "$date_part" "$hour24"
    return 0
  fi
  return 1
}

did_work=0

for ext in $EXTS; do
  for f in *."$ext"; do
    base="$(basename "$f")"
    name="${base%.*}"

    # skip anything we already produced
    [[ "$base" =~ $PROCESSED_RE ]] && continue

    if ! wait_until_stable "$f"; then
      log "SKIP (still changing): $base"
      continue
    fi

    if stamp="$(stamp_from_name "$name")"; then
      :
    else
      mtime=$(stat -f %m "$f")
      stamp=$(date -r "$mtime" '+%Y-%m-%d-%H')
      log "  (couldn't parse timestamp from filename, using mtime)"
    fi
    out="${stamp}-${name}.mp4"

    if [ -e "$out" ]; then
      log "SKIP (output exists): $out"
      continue
    fi

    log "PROCESSING: $base -> $out"

    # does it have an audio stream?
    has_audio=$(ffprobe -v error -select_streams a -show_entries stream=index \
                  -of csv=p=0 "$f" | head -n 1)

    if [ -n "$has_audio" ]; then
      # atempo maxes out at 2.0 per filter, so chain three of them: 2*2*2 = 8
      ffmpeg -nostdin -hide_banner -loglevel error -y -i "$f" \
        -filter_complex "[0:v]setpts=PTS/${SPEED}[v];[0:a]atempo=2,atempo=2,atempo=2[a]" \
        -map "[v]" -map "[a]" \
        -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p \
        -c:a aac -b:a 128k -movflags +faststart \
        "$out" >> "$LOG" 2>&1
    else
      log "  (no audio stream found, video only)"
      ffmpeg -nostdin -hide_banner -loglevel error -y -i "$f" \
        -filter:v "setpts=PTS/${SPEED}" -an \
        -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p \
        -movflags +faststart \
        "$out" >> "$LOG" 2>&1
    fi

    if [ $? -ne 0 ] || [ ! -s "$out" ]; then
      log "FAILED: ffmpeg error on $base — original kept"
      rm -f "$out"
      continue
    fi

    rm -f "$f"
    log "DONE: $out ($(du -h "$out" | cut -f1)), original removed"
    git add -- "$out"
    did_work=1
  done
done

if [ "$did_work" = 1 ] && ! git diff --cached --quiet; then
  git commit -q -m "Add sped-up recording $(date '+%Y-%m-%d %H:%M')" >> "$LOG" 2>&1
  if git push -q >> "$LOG" 2>&1; then
    log "PUSHED"
  else
    log "PUSH FAILED — commit is local, run 'git push' manually"
  fi
fi
