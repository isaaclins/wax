#!/usr/bin/env bash
# scripts/eq-mic-permission-audit.sh — guards Spotiglass against ever
# re-introducing the microphone / audio-recording path that the legacy
# process-tap EQ (deleted from main) required.
#
# Fails the build on any reference to:
#   - NSMicrophoneUsage              (Info.plist key for mic permission)
#   - AVCaptureDevice                (any input capture)
#   - AVAudioEngine.inputNode        (the input scope of AVAudioEngine)
#   - AudioHardwareCreateProcessTap  (CoreAudio process tap)
#   - CATapDescription               (process-tap description type)
#   - kAudioObjectPropertyScopeInput / input-scope CoreAudio
#
# Greps Spotiglass/ (app sources), SpotiglassTests/ (test target) and
# SpotiglassEQDriver/ (the HAL plugin, #607). Skips the audit script itself and
# `docs/equalizer.md`, which intentionally names the APIs so reviewers know
# exactly what's banned.
#
# ALLOWED_LINES lists reviewed uses by file and exact line content (not line
# number, so moving them doesn't matter and changing them needs a new review).
#
# Wired into `make test` (see Makefile).

set -e

# rg is bundled in modern Xcode CLT and on Homebrew. Fall back to grep if
# someone runs this outside the standard dev env.
SEARCH_DIRS=(Spotiglass SpotiglassTests SpotiglassEQDriver)

if command -v rg >/dev/null; then
  SEARCH() { rg --no-heading --line-number "$1" "${SEARCH_DIRS[@]}"; }
else
  SEARCH() { grep -RIn "$1" "${SEARCH_DIRS[@]}"; }
fi

BANNED_PATTERNS=(
  'NSMicrophoneUsage'
  'AVCaptureDevice'
  'AVAudioEngine.*inputNode'
  '\.inputNode'
  'AudioHardwareCreateProcessTap'
  'CATapDescription'
  'kAudioObjectPropertyScopeInput'
)

EXCLUDE_FILES=(
  'scripts/eq-mic-permission-audit.sh'
  'docs/equalizer.md'
)

# "<file>|<line content, leading/trailing spaces trimmed>"
ALLOWED_LINES=(
  # The driver answers coreaudiod's stream queries with ZERO input streams, so
  # the device has no input channels. Reading the scope only to refuse it.
  'SpotiglassEQDriver/SpotiglassEQPlugin.cpp|*outDataSize = (address->mScope == kAudioObjectPropertyScopeInput)'
  'SpotiglassEQDriver/SpotiglassEQPlugin.cpp|if (address->mScope == kAudioObjectPropertyScopeInput) {'
)

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

violations=0
for pattern in "${BANNED_PATTERNS[@]}"; do
  hits=$(SEARCH "$pattern" 2>/dev/null || true)
  if [[ -n "$hits" ]]; then
    # Strip out exempted file paths.
    filtered=""
    while IFS= read -r line; do
      keep=1
      for excl in "${EXCLUDE_FILES[@]}"; do
        if [[ "$line" == *"$excl"* ]]; then
          keep=0
          break
        fi
      done
      if (( keep )); then
        # rg/grep print "file:line:content".
        file=${line%%:*}
        rest=${line#*:}
        content=$(trim "${rest#*:}")
        for allowed in "${ALLOWED_LINES[@]}"; do
          if [[ "$file|$content" == "$allowed" ]]; then
            keep=0
            break
          fi
        done
      fi
      if (( keep )); then
        filtered+="$line"$'\n'
      fi
    done <<< "$hits"
    filtered=${filtered%$'\n'}
    if [[ -n "$filtered" ]]; then
      echo "FAIL: banned mic / audio-recording API '$pattern' found:"
      printf "%s\n" "$filtered" | sed 's/^/    /'
      violations=$((violations + 1))
    fi
  fi
done

if (( violations > 0 )); then
  echo
  echo "Spotiglass must never request microphone permission. The HAL plugin"
  echo "path uses only OUTPUT-scope CoreAudio; if you genuinely need input,"
  echo "discuss the design before adding any of the above APIs."
  exit 1
fi

echo "OK: 0 banned mic / audio-recording APIs in ${SEARCH_DIRS[*]}"
