#!/usr/bin/env bats

# Name: tests/integration/test_features.bats
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   Behavioural integration tests for the v1.3.0+ feature surface:
#     - --append / -a       (text concatenation onto existing buffer)
#     - --trim              (whitespace trimming before write)
#     - --type MIME         (universal MIME-type forwarding)
#     - --json / -j         (sugar for --type application/json --raw)
#     - --image[=FORMAT]    (sugar for --type image/<format> --raw)
#     - --no-auto           (disable the always-on heuristic)
#
#   Each test exercises one end-to-end behaviour
#   that cannot be expressed at the unit-test level
#   (clipboard side effects, prelude composition,
#   cross-flag compatibility errors, real backend dispatch).
#
#   MIME-routing assertions reach into the structured debug log
#   instead of grepping wl-copy's argv:
#   the `--debug` flag is contractually stable
#   and gives us a much cleaner narrative for what the script chose.
#
#   Pure flag mappings (e.g. --image=jpg -> image/jpeg)
#   live in tests/unit/test_options.bats and tests/unit/test_mime.bats:
#   they exercise the same code path
#   without involving a fake-backend round-trip.
#
#   Each test follows the Arrange-Act-Assert (AAA) pattern.
#
# Disclaimer:
#   This script is provided 'as is', without any warranty.

bats_require_minimum_version 1.5.0

load '../support/test_helper.bash'

setup() {
  __cp_setup_fake_backend
  __cp_load_scripts
}


# region --append

@test "--append concatenates new text onto existing clipboard content" {
  # Arrange
  __cp_clipboard_set 'first '

  # Act
  run --separate-stderr __cp_run 'printf "%s" "second" | copy --append'

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = 'first second' ]
}

@test "--append on empty clipboard behaves like a plain write" {
  # Arrange
  __cp_clipboard_set ''

  # Act
  run --separate-stderr __cp_run 'printf "%s" "fresh" | copy --append'

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = 'fresh' ]
}

@test "--append works in argument mode (no piped stdin)" {
  # Arrange
  __cp_clipboard_set 'hello '

  # Act
  run --separate-stderr __cp_run_copy_argv '--append world'

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = 'hello world' ]
}

# endregion


# region --trim

@test "--trim removes leading and trailing whitespace, preserves the interior" {
  # Arrange:
  # whitespace surrounds the payload; tabs and newlines stay inside.
  local -r expected=$'middle a b\tc\nd'

  # Act
  run --separate-stderr __cp_run \
    'printf "  \t\nmiddle a b\tc\nd  \n" | copy --trim'

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "--trim composes correctly with default ANSI stripping" {
  # Arrange:
  # ANSI codes around the payload are stripped first,
  # then the leftover whitespace is trimmed.
  local -r expected='red'

  # Act
  run --separate-stderr __cp_run \
    'printf "  \033[31mred\033[0m  " | copy --trim'

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "--trim composes with --raw (ANSI kept, whitespace gone)" {
  # Arrange
  local -r expected=$'\033[31mred\033[0m'

  # Act
  run --separate-stderr __cp_run \
    'printf "  \033[31mred\033[0m  " | copy --trim --raw'

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

# endregion


# region MIME forwarding (debug-driven)
#
# These tests assert the MIME chosen by copy/past via the structured
# `--debug` log, rather than grepping the backend's argv.
# Why: the debug log is the project's stable contract for what was
# decided, while argv-grepping conflates 'how did the script call
# wl-copy' with 'what MIME did it pick'.

@test "explicit --type pins the MIME on copy" {
  # Arrange
  local -r payload='<html>hi</html>'

  # Act
  run --separate-stderr __cp_run \
    "printf '%s' '${payload}' | copy --debug --type text/html"

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$payload" ]
  __cp_assert_debug_event 'options-parsed' 'mime=text/html'
  # An explicit --type wins over auto-detection.
  __cp_assert_debug_event 'options-validated' 'auto=0'
}

@test "--json pins application/json and skips ANSI stripping" {
  # Arrange:
  # ANSI escapes inside the payload would normally be stripped,
  # but --json implies --raw, so they survive verbatim.
  local -r payload=$'{"key":"\033[31mvalue\033[0m"}'

  # Act
  run --separate-stderr __cp_run \
    'printf "%s" $'"'"'{"key":"\033[31mvalue\033[0m"}'"'"' \
      | copy --debug --json'

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$payload" ]
  __cp_assert_debug_event 'options-parsed' \
    'mime=application/json' 'raw=1'
}

@test "past --type pins the MIME on read" {
  # Arrange
  __cp_clipboard_set 'binary-bytes'

  # Act
  run --separate-stderr past --debug --type image/png

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = 'binary-bytes' ]
  __cp_assert_debug_event 'options-parsed' 'mime=image/png'
  __cp_assert_debug_event 'mime-classified' 'is-binary=1'
}

# endregion


# region Auto-detection

@test "JSON is auto-detected by default when jq is available" {
  # Arrange
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed; default JSON detection is opt-in via jq presence'
  fi

  # Act
  run --separate-stderr __cp_run \
    'printf "%s" "{\"hello\":\"world\"}" | copy --debug'

  # Assert:
  # the auto-detect helper picks application/json,
  # the binary fast-path completes the write.
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = '{"hello":"world"}' ]
  __cp_assert_debug_event 'auto-detect' 'mime=application/json'
  __cp_assert_debug_event 'done' 'mode=auto-binary'
}

@test "PNG bytes are auto-detected by default" {
  # Arrange / Act
  run --separate-stderr __cp_run \
    'printf "\x89PNG\r\n\x1a\nrest" | copy --debug'

  # Assert
  [ "$status" -eq 0 ]
  __cp_assert_debug_event 'auto-detect' 'mime=image/png'
  __cp_assert_debug_event 'done' 'mode=auto-binary'
}

@test "--no-auto pins the payload to text/plain" {
  # Arrange
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed; --no-auto only matters when default sniff is active'
  fi

  # Act:
  # the payload IS valid JSON, but --no-auto pins us to text/plain.
  run --separate-stderr __cp_run \
    'printf "%s" "{\"a\":1}" | copy --debug --no-auto'

  # Assert:
  # auto must be off, no auto-detect events should fire,
  # and the payload reaches the clipboard verbatim.
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = '{"a":1}' ]
  __cp_assert_debug_event 'options-parsed' 'auto=0'
  __cp_refute_debug_event 'auto-detect-start'
}

@test "explicit --type wins over auto-detection" {
  # Arrange
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed'
  fi

  # Act:
  # the payload looks like JSON, but the user pinned text/html.
  run --separate-stderr __cp_run \
    'printf "%s" "{\"a\":1}" | copy --debug --type text/html'

  # Assert
  [ "$status" -eq 0 ]
  __cp_assert_debug_event 'options-parsed' 'mime=text/html'
  __cp_refute_debug_event 'auto-detect'
}

@test "auto-detection silently disabled with --append (text-only mode)" {
  # Arrange:
  # the existing clipboard content is text;
  # the new payload looks like JSON.
  # --append must suppress the heuristic
  # so the prelude is never accidentally classified
  # as part of a JSON document.
  __cp_clipboard_set 'prefix '

  # Act
  run --separate-stderr __cp_run \
    'printf "%s" "{\"a\":1}" | copy --debug --append'

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = 'prefix {"a":1}' ]
  __cp_assert_debug_event 'options-validated' 'auto=0'
  __cp_refute_debug_event 'auto-detect-start'
}

# endregion


# region --image (binary fidelity)

@test "--image preserves binary bytes verbatim and pins image/png" {
  # Arrange / Act
  run --separate-stderr __cp_run \
    'printf "\x89PNG\r\n\x1a\n" | copy --debug --image'

  # Assert
  [ "$status" -eq 0 ]
  __cp_assert_debug_event 'options-parsed' \
    'mime=image/png' 'raw=1'
  # \x89 P N G \r \n \x1a \n  ->  89 50 4e 47 0d 0a 1a 0a
  [ "$(__cp_clipboard_hex)" = '89504e470d0a1a0a' ]
}

# endregion


# region Cross-flag compatibility errors

@test "--append with --image fails with COPY_ERR_TYPE_MISMATCH" {
  # Arrange / Act
  run --separate-stderr __cp_run 'printf "x" | copy --append --image'

  # Assert
  [ "$status" -eq "$COPY_ERR_TYPE_MISMATCH" ]
  [[ "$stderr" == *'--append is only valid for text payloads'* ]]
}

@test "--trim with --image fails with COPY_ERR_TYPE_MISMATCH" {
  # Arrange / Act
  run --separate-stderr __cp_run 'printf "x" | copy --trim --image'

  # Assert
  [ "$status" -eq "$COPY_ERR_TYPE_MISMATCH" ]
  [[ "$stderr" == *'--trim is only valid for text payloads'* ]]
}

# endregion


# region past --image (NUL fidelity)

@test "past --image bypasses the trailing-newline workaround (NUL fidelity)" {
  # Arrange:
  # the workaround calls $(...), which corrupts NUL bytes.
  # When MIME is image/*, past must exec wl-paste directly
  # so the binary payload reaches stdout intact.
  printf 'a\x00b' > "$FAKE_CLIPBOARD_FILE"

  # Act:
  # capture into a temp file to preserve NULs across `run` boundaries.
  local -r out_file="${BATS_TEST_TMPDIR}/past-image.bin"
  past --image > "$out_file"
  local -ir rc=$?

  # Assert
  [ "$rc" -eq 0 ]
  # a (61), NUL (00), b (62)
  [ "$(__cp_hex < "$out_file")" = '610062' ]
}

# endregion

### End of file
