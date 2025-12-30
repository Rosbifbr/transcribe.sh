#!/bin/bash
# sudo dnf install alsa-utils curl yq wl-clipboard kdialog libnotify

# define constants here!!
export API_KEY_NAME='MISTRAL_API_KEY'
export MODEL='voxtral-mini-latest'
export HOST='api.mistral.ai'
# export API_KEY_NAME='OPENAI_API_KEY'
# export MODEL='gpt-4o-mini-transcribe'
# export HOST='api.openai.com'

# exit immediately if a command exits with a non-zero status.
set -e

## --- configuration ---
RECORDING_FILE="/tmp/transcribe-recording.wav"

## --- Pre-flight Checks ---
# Check for required tools
for cmd in pw-record curl yq wl-copy kdialog notify-send ask; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: Required command '$cmd' is not installed." >&2
    if command -v "kdialog" &>/dev/null; then
      kdialog --error "Missing required command: $cmd"
    fi
    exit 1
  fi
done

# Check for the API Key
export API_KEY=$(printenv $API_KEY_NAME)
if [ -z "$API_KEY" ]; then
  echo "Error: $API_KEY_NAME environment variable is not set." >&2
  kdialog --error "$API_KEY_NAME environment variable is not set."
  exit 1
fi

echo Calling $HOST using $API_KEY_NAME

## --- Main Logic ---
# Start recording in the background
pw-record --format=s16 --rate=44100 --channels=2 "$RECORDING_FILE" &
RECORDER_PID=$!

# Use --yesnocancel to provide three options:
# Yes (0) -> Just Transcribe
# No (1)  -> Ask AI
# Cancel (2) -> Abort
set +e
ACTION=$(kdialog --title "Transcribe" \
  --menu "🎙️ Recording audio...\n\nChoose an action:" \
  'transcribe' Transcribe \
  'ask' 'Ask AI')
: ${ACTION:=$?}
set -e

echo Action is $ACTION

# Stop recording immediately after user interaction
kill -SIGINT "$RECORDER_PID"
wait "$RECORDER_PID" 2>/dev/null || true

if [ $ACTION = 1 ]; then
  echo "User chose to abort."
  rm -f "$RECORDING_FILE"
  exit 1
fi

notify-send "Transcribe" "Processing audio..." --icon=media-record

# --- API Call ---
RESPONSE=$(curl --silent --request POST \
  --url https://$HOST/v1/audio/transcriptions \
  --header "Authorization: Bearer $API_KEY" \
  -F file=@$RECORDING_FILE \
  -F model=$MODEL)

echo Request ok

TRANSCRIPTION=$(echo "$RESPONSE" | yq -r '.text')

# Error handling
if [ -z "$TRANSCRIPTION" ] || [ "$TRANSCRIPTION" == "null" ]; then
  ERROR_MSG=$(echo "$RESPONSE" | yq -r '.error.message // .message // .detail // .')
  kdialog --error "API Error: $ERROR_MSG"
  exit 1
fi

rm -f "$RECORDING_FILE"

echo Transcription ok

# --- Branching Logic ---
if [ $ACTION = 'transcribe' ]; then
  # Option: Just Transcribe
  echo "$TRANSCRIPTION" | wl-copy
  notify-send "Transcribe" "Transcription copied to clipboard!" --icon=edit-copy
else
  # Option: Ask AI
  notify-send "Ask AI" "Thinking..." --icon=brain

  # Pipe transcription to 'ask' and capture output
  AI_RESPONSE=$(echo "$TRANSCRIPTION" | ask)

  # Display the result in a text box so the user can see/edit/copy it
  FINAL_OUTPUT=$(kdialog --title "AI Response" --textinputbox "Result from 'ask':" "$AI_RESPONSE")
fi
