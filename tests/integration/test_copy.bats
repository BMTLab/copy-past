#!/usr/bin/env bats

# Tests what copy writes to a fake clipboard, and how it fails.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

# region Argument mode

@test "copy writes one argument to the clipboard" {
  # Arrange: argument mode needs a terminal as stdin; see run_in_terminal.

  # Act
  run --separate-stderr run_copy_in_terminal "'hello world'"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == 'hello world' ]]
}

@test "copy joins its arguments with single spaces" {
  # Arrange: the second word holds spaces of its own.

  # Act
  run --separate-stderr run_copy_in_terminal "line 1 'with spaces' two"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == 'line 1 with spaces two' ]]
}

# endregion Argument mode

# region Pipe mode

#######################################
# Check that copy writes a piped payload byte for byte.
#
# Arguments:
#   1: The payload, as printf prints it with %b.
#   2: The bytes expected in the clipboard, as hex.
#######################################
function pipe_mode_keeps_every_byte() {
  # Arrange
  local -r payload="$1"
  local -r expected_hex="$2"
  local -r payload_path="${BATS_TEST_TMPDIR}/payload.txt"
  printf '%b' "${payload}" >"${payload_path}"

  # Act
  run --separate-stderr run_snippet "copy <${payload_path@Q}"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard_hex)" == "${expected_hex}" ]]
}

bats_test_function --description "copy writes a piped line byte for byte" \
  -- pipe_mode_keeps_every_byte 'abc' '616263'
bats_test_function \
  --description "copy writes piped lines without a last newline byte for byte" \
  -- pipe_mode_keeps_every_byte 'line1\nline2\nline3' \
  '6c696e65310a6c696e65320a6c696e6533'
bats_test_function \
  --description "copy writes piped lines with a last newline byte for byte" \
  -- pipe_mode_keeps_every_byte 'line1\nline2\n' '6c696e65310a6c696e65320a'

# endregion Pipe mode

# region ANSI escape sequences

@test "copy removes ANSI escape sequences by default" {
  # Arrange: SGR colors around two words.

  # Act
  run --separate-stderr run_snippet \
    'printf "\033[31mred\033[0m\n\033[32mgreen\033[0m" | copy'

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == $'red\ngreen' ]]
}

@test "copy --raw keeps ANSI escape sequences in pipe mode" {
  # Arrange: an SGR color.

  # Act
  run --separate-stderr run_snippet 'printf "\033[31mred\033[0m" | copy --raw'

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == $'\033[31mred\033[0m' ]]
}

@test "copy --raw keeps ANSI escape sequences in argument mode" {
  # Arrange: an SGR color, as an argument.

  # Act
  run --separate-stderr run_copy_in_terminal "--raw $'\\033[31mred\\033[0m'"

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == $'\033[31mred\033[0m' ]]
}

@test "copy leaves plain text as it is" {
  # Arrange: no escape sequence at all.

  # Act
  run --separate-stderr run_snippet \
    'printf "%s" "plain text without escapes" | copy'

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == 'plain text without escapes' ]]
}

# endregion ANSI escape sequences

# region Help and options

@test "copy --help prints the usage to stdout and exits 0" {
  # Arrange: --help stops copy before any backend.

  # Act
  run --separate-stderr copy --help

  # Assert
  ((status == 0))
  [[ "${output}" == *'copy - write'*'system clipboard'* ]]
  [[ "${output}" == *'--raw'* ]]
  [[ "${output}" == *'--debug'* ]]
}

@test "copy takes the words after -- as text" {
  # Arrange: --raw after -- is a word of the text.

  # Act
  run --separate-stderr run_copy_in_terminal '-- --raw not-a-flag'

  # Assert
  ((status == 0))
  [[ "$(print_clipboard)" == '--raw not-a-flag' ]]
}

@test "copy refuses an unknown option with the usage code" {
  # Arrange: --bogus is no option of copy.

  # Act
  run --separate-stderr copy --bogus

  # Assert
  ((status == COPY_ERR_USAGE))
  [[ "${stderr}" == *'unknown option'* ]]
}

@test "copy prefixes each line of a message with its name" {
  # Arrange: --bogus is no option of copy.

  # Act
  run --separate-stderr copy --bogus

  # Assert: what went wrong, then what to do next.
  [[ "${stderr}" == $'copy: unknown option: --bogus\ncopy: see: copy --help' ]]
}

# endregion Help and options

# region Failures

@test "copy refuses no input at all with the usage code" {
  # Arrange: a terminal as stdin, and no words.

  # Act
  run --separate-stderr run_copy_in_terminal ''

  # Assert
  ((status == COPY_ERR_USAGE))
}

@test "copy reports a missing backend with its code" {
  # Arrange: PATH holds no backend; see run_without_backends.

  # Act
  run --separate-stderr run_without_backends "printf '%s' x | copy"

  # Assert
  ((status == COPY_ERR_NO_BACKEND))
  [[ "${stderr}" == *'no clipboard backend found'* ]]
}

# endregion Failures

# region Constants

@test "the exit codes of copy keep their documented values" {
  # Arrange: setup sourced copy.sh.

  # Act: the constants are the input.

  # Assert
  ((COPY_ERR_GENERAL == 1))
  ((COPY_ERR_USAGE == 2))
  ((COPY_ERR_NO_BACKEND == 3))
  ((COPY_ERR_BACKEND_FAILED == 4))
  ((COPY_ERR_TYPE_MISMATCH == 5))
  ((COPY_ERR_INTERNAL == 70))
}

@test "copy.sh can be sourced twice in one shell" {
  # Arrange: run_snippet sources copy.sh, and the snippet sources it again,
  # as a reload of ~/.bashrc does; a readonly constant must not fail.

  # Act
  run --separate-stderr run_snippet "source ${COPY_PAST_ROOT@Q}/copy.sh && printf ok"

  # Assert
  ((status == 0))
  [[ "${output}" == 'ok' ]]
}

# endregion Constants

### End
