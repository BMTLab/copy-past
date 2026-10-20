#!/usr/bin/env bats

# Tests what past prints from a fake clipboard, and how it fails.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

# region Reading

@test "past prints the clipboard as it is" {
  # Arrange
  set_clipboard 'hello world'

  # Act
  run --separate-stderr past

  # Assert
  ((status == 0))
  [[ "${output}" == 'hello world' ]]
}

#######################################
# Check that past prints the clipboard byte for byte:
# it adds no newline of its own, and keeps the newline of the text.
#
# Arguments:
#   1: The clipboard, as printf prints it with %b.
#   2: The bytes expected, as hex.
#######################################
function past_keeps_every_byte() {
  # Arrange
  local -r clipboard="$1"
  local -r expected_hex="$2"
  local -r output_path="${BATS_TEST_TMPDIR}/past.out"
  printf '%b' "${clipboard}" >"${FAKE_CLIPBOARD_FILE}"

  # Act:
  # the output goes through a file, since $(...) would drop the newline.
  run_past_keeping_newlines >"${output_path}"

  # Assert
  [[ "$(print_hex <"${output_path}")" == "${expected_hex}" ]]
}

bats_test_function \
  --description "past prints lines without a last newline byte for byte" \
  -- past_keeps_every_byte 'line1\nline2\nline3' \
  '6c696e65310a6c696e65320a6c696e6533'
bats_test_function \
  --description "past prints lines with a last newline byte for byte" \
  -- past_keeps_every_byte 'line1\nline2\n' '6c696e65310a6c696e65320a'
bats_test_function \
  --description "past prints ANSI escape sequences byte for byte" \
  -- past_keeps_every_byte '\033[31mred\033[0m' '1b5b33316d7265641b5b306d'

@test "past prints nothing for an empty clipboard" {
  # Arrange
  set_clipboard ''

  # Act
  run --separate-stderr past

  # Assert
  ((status == 0))
  [[ -z "${output}" ]]
}

# endregion Reading

# region Help and failures

@test "past --help prints the usage to stdout and exits 0" {
  # Arrange: --help stops past before any backend.

  # Act
  run --separate-stderr past --help

  # Assert
  ((status == 0))
  [[ "${output}" == *'past - print system clipboard'* ]]
  [[ "${output}" == *'--debug'* ]]
}

@test "past reports a missing backend with its code" {
  # Arrange: PATH holds no backend; see run_without_backends.

  # Act
  run --separate-stderr run_without_backends 'past'

  # Assert
  ((status == PAST_ERR_NO_BACKEND))
  [[ "${stderr}" == *'no clipboard backend found'* ]]
}

@test "past prefixes each line of a message with its name" {
  # Arrange: past takes no positional argument.

  # Act
  run --separate-stderr past stray

  # Assert: what went wrong, then what to do next.
  [[ "${stderr}" == $'past: unknown argument: stray\npast: see: past --help' ]]
}

# endregion Help and failures

# region Constants

@test "the exit codes of past keep their documented values" {
  # Arrange: setup sourced past.sh.

  # Act: the constants are the input.

  # Assert
  ((PAST_ERR_GENERAL == 1))
  ((PAST_ERR_USAGE == 2))
  ((PAST_ERR_NO_BACKEND == 3))
  ((PAST_ERR_BACKEND_FAILED == 4))
  ((PAST_ERR_TYPE_MISMATCH == 5))
  ((PAST_ERR_INTERNAL == 70))
}

@test "past.sh can be sourced twice in one shell" {
  # Arrange: run_snippet sources past.sh, and the snippet sources it again,
  # as a reload of ~/.bashrc does; a readonly constant must not fail.

  # Act
  run --separate-stderr run_snippet "source ${COPY_PAST_ROOT@Q}/past.sh && printf ok"

  # Assert
  ((status == 0))
  [[ "${output}" == 'ok' ]]
}

# endregion Constants

### End
