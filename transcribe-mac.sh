#!/bin/bash
# macOS port. Dependencies:
#   brew install sox yq
# Required permissions (System Settings → Privacy & Security):
#   - Microphone: grant to your terminal (Terminal.app / iTerm / etc.)
#   - Accessibility: grant to your terminal (needed to simulate ⌘V)
#
# Recording uses sox's `rec` via CoreAudio, which follows the system's default
# input device (System Settings → Sound → Input). Switch mics there and the
# next recording picks it up — no script config needed.

# define constants here!!
export API_KEY_NAME='MISTRAL_API_KEY'
export MODEL='voxtral-mini-latest'
export HOST='api.mistral.ai'
# export API_KEY_NAME='OPENAI_API_KEY'
# export MODEL='gpt-4o-mini-transcribe'
# export HOST='api.openai.com'

set -e

RECORDING_FILE="/tmp/transcribe-recording.wav"
REC_LOG="/tmp/transcribe-rec.log"

notify_error() {
  local msg="${1//\"/\\\"}"
  osascript -e "display notification \"$msg\" with title \"Transcribe\" sound name \"Basso\"" >/dev/null 2>&1 || true
  echo "Error: $1" >&2
}

cleanup() {
  rm -f "$RECORDING_FILE" "$REC_LOG"
}
trap cleanup EXIT

## --- Pre-flight Checks ---
for cmd in rec curl yq osascript; do
  if ! command -v "$cmd" &>/dev/null; then
    notify_error "Missing required command: $cmd"
    exit 1
  fi
done

export API_KEY=$(printenv "$API_KEY_NAME")
if [ -z "$API_KEY" ]; then
  notify_error "$API_KEY_NAME environment variable is not set."
  exit 1
fi

echo "Calling $HOST using $API_KEY_NAME"

## --- Main Logic ---
# Start recording in the background via CoreAudio (sox/rec). Follows the system
# default input device. `rec` flushes the WAV on SIGTERM.
rec -q -c 1 "$RECORDING_FILE" >"$REC_LOG" 2>&1 &
RECORDER_PID=$!

# Menu dialog. Returns "Transcribe", "Ask AI", or "cancel".
# `tell me to activate` forces the dialog to the foreground so it grabs focus
# and Enter confirms without needing a mouse click.
set +e
ACTION=$(osascript <<'EOF'
try
  tell me to activate
  set result to display dialog "🎙️ Recording audio..." ¬
    buttons {"Cancel", "Ask AI", "Transcribe"} ¬
    default button "Transcribe" ¬
    cancel button "Cancel" ¬
    with title "Transcribe"
  return button returned of result
on error
  return "cancel"
end try
EOF
)
set -e

echo "Action: $ACTION"

# Stop recording immediately after user interaction. rec writes the WAV header
# on clean termination, so use SIGTERM (not SIGKILL).
kill -TERM "$RECORDER_PID" 2>/dev/null || true
wait "$RECORDER_PID" 2>/dev/null || true

if [ "$ACTION" = "cancel" ]; then
  echo "User cancelled."
  exit 0
fi

if [ ! -s "$RECORDING_FILE" ]; then
  notify_error "Recording is empty — check mic permission and System Settings → Sound → Input."
  cat "$REC_LOG" >&2 || true
  exit 1
fi

WAV_BYTES=$(stat -f%z "$RECORDING_FILE")
echo "Recorded $WAV_BYTES bytes"

## --- API Call ---
RESPONSE=$(curl --silent --request POST \
  --url "https://$HOST/v1/audio/transcriptions" \
  --header "Authorization: Bearer $API_KEY" \
  -F "file=@$RECORDING_FILE" \
  -F "model=$MODEL")

TRANSCRIPTION=$(echo "$RESPONSE" | yq -r '.text')

if [ -z "$TRANSCRIPTION" ] || [ "$TRANSCRIPTION" = "null" ]; then
  ERROR_MSG=$(echo "$RESPONSE" | yq -r '.error.message // .message // .detail // .')
  notify_error "API Error: $ERROR_MSG"
  exit 1
fi

echo "Transcription ok"

## --- Output: type directly at cursor (no clipboard) ---
# AppleScript's `keystroke` simulates real keypresses via System Events, so
# text arrives at the frontmost app's cursor without touching the pasteboard.
# The leading delay lets focus return to that app after the dialog closes.
type_at_cursor() {
  local text="$1"
  osascript \
    -e 'on run argv' \
    -e '  delay 0.15' \
    -e '  tell application "System Events" to keystroke (item 1 of argv)' \
    -e 'end run' \
    -- "$text"
}

## --- Branching Logic ---
if [ "$ACTION" = "Transcribe" ]; then
  type_at_cursor "$TRANSCRIPTION"
else
  if ! command -v ask &>/dev/null; then
    notify_error "'ask' command not found in PATH"
    exit 1
  fi
  AI_RESPONSE=$(echo "$TRANSCRIPTION" | ask)
  type_at_cursor "$AI_RESPONSE"
fi
