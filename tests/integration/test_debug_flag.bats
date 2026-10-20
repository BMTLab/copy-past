#!/usr/bin/env bats

# Tests the --debug flag of copy and past end to end.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

# region Quiet by default

@test "copy prints no debug line without --debug" {
  # Arrange: a plain payload.

  # Act
  run --separate-stderr run_snippet 'printf "%s" "hello" | copy'

  # Assert
  ((status == 0))
  [[ "${stderr}" != *'[copy debug]'* ]]
}

@test "past prints no debug line without --debug" {
  # Arrange
  set_clipboard 'hello'

  # Act
  run --separate-stderr past

  # Assert
  ((status == 0))
  [[ "${stderr}" != *'[past debug]'* ]]
}

@test "copy prints nothing to stderr when it detects JSON without --debug" {
  # Arrange:
  # an old release printed a notice on every detection,
  # which broke pipelines that read stderr.
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed; JSON detection needs it'
  fi

  # Act
  run --separate-stderr run_snippet 'printf "%s" "{\"k\":1}" | copy'

  # Assert
  ((status == 0))
  [[ -z "${stderr}" ]]
}

# endregion Quiet by default

# region The three spellings

#######################################
# Check that a spelling of the debug flag turns on the log of copy.
#
# Arguments:
#   1: The flag: -d, --debug or --verbose.
#######################################
function copy_debug_flag_prints_the_log() {
  local -r flag="$1"

  # Arrange: the flag is the input.

  # Act
  run --separate-stderr run_snippet 'printf x | copy "$1"' "${flag}"

  # Assert
  ((status == 0))
  [[ "${stderr}" == *'[copy debug] event=options-parsed'* ]]
}

#######################################
# Check that a spelling of the debug flag turns on the log of past.
#
# Arguments:
#   1: The flag: -d, --debug or --verbose.
#######################################
function past_debug_flag_prints_the_log() {
  local -r flag="$1"

  # Arrange
  set_clipboard 'data'

  # Act
  run --separate-stderr past "${flag}"

  # Assert
  ((status == 0))
  [[ "${stderr}" == *'[past debug] event=options-parsed'* ]]
}

for flag_name in -d --debug --verbose; do
  bats_test_function --description "copy ${flag_name} prints the debug log" \
    -- copy_debug_flag_prints_the_log "${flag_name}"
  bats_test_function --description "past ${flag_name} prints the debug log" \
    -- past_debug_flag_prints_the_log "${flag_name}"
done

# endregion The three spellings

# region The events of copy

@test "copy --debug logs every step for a plain text payload" {
  # Arrange: --no-auto keeps auto-detection out.

  # Act
  run --separate-stderr run_snippet \
    'printf "%s" "hi" | copy --debug --no-auto'

  # Assert
  ((status == 0))
  assert_debug_event 'options-parsed' 'auto=0' 'mime=<none>'
  assert_debug_event 'options-validated' 'auto=0'
  assert_debug_event 'backend-resolved' 'backend=wl-copy'
  assert_debug_event 'pipeline-start' 'mode=pipe'
  assert_debug_event 'done' 'mode=pipeline'
}

@test "copy --debug logs the MIME type that it detected for JSON" {
  # Arrange
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed; JSON detection needs it'
  fi

  # Act
  run --separate-stderr run_snippet 'printf "%s" "{\"k\":1}" | copy --debug'

  # Assert: JSON takes the way of a binary payload.
  ((status == 0))
  assert_debug_event 'auto-detect-start'
  assert_debug_event 'auto-detect' 'mime=application/json'
  assert_debug_event 'auto-detect-binary' \
    'mime=application/json' 'action=stream-buffer'
  assert_debug_event 'done' 'mode=auto-binary'
}

@test "copy --debug logs the MIME type that it detected for PNG bytes" {
  # Arrange: the PNG signature, then more bytes.

  # Act
  run --separate-stderr run_snippet \
    'printf "\x89PNG\r\n\x1a\nrest" | copy --debug'

  # Assert
  ((status == 0))
  assert_debug_event 'auto-detect' 'mime=image/png'
  assert_debug_event 'auto-detect-binary' 'mime=image/png'
}

@test "copy --debug logs that plain text goes on to the pipeline" {
  # Arrange: plain text, with auto-detection on.

  # Act
  run --separate-stderr run_snippet 'printf "%s" "plain text" | copy --debug'

  # Assert
  ((status == 0))
  assert_debug_event 'auto-detect' 'mime=text/plain'
  assert_debug_event 'auto-detect-text' 'action=fall-through-to-pipeline'
  assert_debug_event 'done' 'mode=pipeline'
}

@test "copy --debug --append logs the saved clipboard" {
  # Arrange
  set_clipboard 'first '

  # Act
  run --separate-stderr run_snippet \
    'printf "%s" "second" | copy --append --debug'

  # Assert: --append turns auto-detection off.
  ((status == 0))
  assert_debug_event 'options-parsed' 'append=1'
  assert_debug_event 'options-validated' 'auto=0'
  assert_debug_event 'prelude-captured'
  [[ "$(print_clipboard)" == 'first second' ]]
}

@test "copy --debug logs argument mode when stdin is a terminal" {
  local -r stderr_path="${BATS_TEST_TMPDIR}/argument-mode.stderr"

  # Arrange:
  # stderr goes to a file, since the terminal turns LF into CRLF.

  # Act
  run_in_terminal 'copy --debug --no-auto hello world 2>"$1"' "${stderr_path}" \
    >/dev/null

  # Assert
  [[ "$(<"${stderr_path}")" == *'[copy debug] event=pipeline-start mode=argument'* ]]
  [[ "$(print_clipboard)" == 'hello world' ]]
}

# endregion The events of copy

# region The events of past

@test "past --debug logs every step for a plain text payload" {
  # Arrange
  set_clipboard 'data'

  # Act
  run --separate-stderr past --debug

  # Assert
  ((status == 0))
  assert_debug_event 'options-parsed' 'mime=<none>'
  assert_debug_event 'mime-classified' 'is-binary=0'
  assert_debug_event 'backend-resolved' 'backend=wl-paste'
  assert_debug_event 'read-strategy' 'mode=wl-paste-newline-strip'
}

@test "past --debug --image logs that wl-paste runs as it is" {
  # Arrange:
  # a binary MIME type skips the newline fix,
  # which goes through $(...) and would lose NUL bytes.
  set_clipboard 'binary-bytes'

  # Act
  run --separate-stderr past --image --debug

  # Assert
  ((status == 0))
  assert_debug_event 'mime-classified' 'is-binary=1'
  assert_debug_event 'read-strategy' 'mode=direct-exec'
}

# endregion The events of past

# region The format of a line

@test "every debug line of copy starts with its prefix and an event" {
  local line
  local -a malformed_lines=()

  # Arrange: the format is a contract for other tools.

  # Act
  run --separate-stderr run_snippet 'printf "%s" "x" | copy --debug --no-auto'
  while IFS= read -r line; do
    if [[ ! "${line}" =~ ^\[copy\ debug\]\ event=[a-zA-Z0-9_-]+(\ |$) ]]; then
      malformed_lines+=("${line}")
    fi
  done <<<"${stderr}"

  # Assert
  ((status == 0))
  ((${#malformed_lines[@]} == 0))
}

# endregion The format of a line

### End
