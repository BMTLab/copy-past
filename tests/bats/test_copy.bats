#!/usr/bin/env bats

# Name: tests/bats/test_copy.bats
# Author: Nikita Neverov (BMTLab)
# Version: 1.1.0
# Date: 2026-05-17
# License: MIT
#
# Description:
#   Behavioural tests for copy.sh.
#   Uses a fake clipboard backend (see test_helper.bash),
#   so the tests are hermetic
#   and never touch the real system clipboard.
#
#   Each test follows the Arrange-Act-Assert (AAA) pattern:
#     - Arrange: prepare inputs, fixtures, and environment.
#     - Act:     invoke the function or script under test.
#     - Assert:  verify outputs, side effects, and exit codes.
#
#   Coverage:
#     - argument mode (joining, single-arg)
#     - pipe mode (multi-line, trailing-newline preservation)
#     - ANSI escape sequence stripping (default + --raw bypass)
#     - option parsing (-h/--help, -r/--raw, --, unknown)
#     - error paths (no input, no backend)
#     - exit codes match the documented constants
#
# Disclaimer:
#   This script is provided "as is", without any warranty.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

setup() {
  __cp_setup_fake_backend
  __cp_load_scripts
}

@test "argument mode copies a single argument" {
  # Arrange
  local -r payload='hello world'

  # Act:
  # argument mode requires stdin to be a tty
  # (otherwise the script enters pipe mode);
  # see __cp_run_with_tty for the pty trick.
  run --separate-stderr __cp_run_with_tty "
    source '${COPY_PAST_ROOT}/copy.sh'
    copy '$payload'
  "

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$payload" ]
}

@test "argument mode joins multiple args with single spaces" {
  # Arrange
  local -r expected='line 1 with spaces two'

  # Act
  run --separate-stderr __cp_run_with_tty "
    source '${COPY_PAST_ROOT}/copy.sh'
    copy line 1 'with spaces' two
  "

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "pipe mode copies stdin verbatim (no trailing newline added)" {
  # Arrange:
  # the payload is constructed inside the subshell,
  # so the exact byte sequence reaches copy via a real pipeline.
  local -r expected='abc'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "abc" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "pipe mode preserves multi-line content without trailing newline" {
  # Arrange
  # line1\nline2\nline3 = 6c696e65310a6c696e65320a6c696e6533
  local -r expected_hex='6c696e65310a6c696e65320a6c696e6533'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "line1\nline2\nline3" | copy
  '

  # Assert:
  # compare via xxd
  # to avoid command substitution stripping trailing newlines
  # (it would still pass here, but we keep the pattern consistent
  # with the other byte-fidelity tests).
  [ "$status" -eq 0 ]
  local hex
  hex=$(xxd -p "$FAKE_CLIPBOARD_FILE" | tr -d '\n')
  [ "$hex" = "$expected_hex" ]
}

@test "pipe mode preserves explicit trailing newline" {
  # Arrange
  # line1\nline2\n = 6c696e65310a6c696e65320a
  local -r expected_hex='6c696e65310a6c696e65320a'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "line1\nline2\n" | copy
  '

  # Assert:
  # xxd avoids the trailing-newline strip
  # that command substitution would apply
  # when comparing with =$'...\n'.
  [ "$status" -eq 0 ]
  local hex
  hex=$(xxd -p "$FAKE_CLIPBOARD_FILE" | tr -d '\n')
  [ "$hex" = "$expected_hex" ]
}

@test "ANSI escape sequences are stripped by default (pipe mode)" {
  # Arrange
  local -r expected=$'red\ngreen'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "\033[31mred\033[0m\n\033[32mgreen\033[0m" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "ANSI stripping handles OSC sequences (ESC ] ... BEL)" {
  # Arrange:
  # OSC 8 hyperlink:
  # ESC ] 8 ; ; URL BEL text ESC ] 8 ; ; BEL
  local -r expected='link text'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "\033]8;;https://example.com\007link text\033]8;;\007" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "--raw preserves ANSI escape sequences (pipe mode)" {
  # Arrange
  local -r expected=$'\033[31mred\033[0m'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "\033[31mred\033[0m" | copy --raw
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "-r short flag is equivalent to --raw" {
  # Arrange
  local -r expected=$'\033[31mred\033[0m'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "\033[31mred\033[0m" | copy -r
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "--raw works in argument mode too" {
  # Arrange
  local -r payload=$'\033[31mred\033[0m'

  # Act
  run --separate-stderr __cp_run_with_tty "
    source '${COPY_PAST_ROOT}/copy.sh'
    copy --raw $'\\033[31mred\\033[0m'
  "

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$payload" ]
}

@test "ANSI stripping leaves plain text untouched" {
  # Arrange
  local -r expected='plain text without escapes'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "plain text without escapes" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "-h prints help to stdout and exits 0" {
  # Arrange: no fixtures needed.

  # Act
  run --separate-stderr copy -h

  # Assert
  [ "$status" -eq 0 ]
  [[ "$output" == *'copy - write text to system clipboard'* ]]
  [[ "$output" == *'--raw'* ]]
}

@test "--help prints help to stdout and exits 0" {
  # Arrange: no fixtures needed.

  # Act
  run --separate-stderr copy --help

  # Assert
  [ "$status" -eq 0 ]
  [[ "$output" == *'copy - write text to system clipboard'* ]]
}

@test "-- terminates option parsing; subsequent args are text" {
  # Arrange
  local -r expected='--raw not-a-flag'

  # Act
  run --separate-stderr __cp_run_with_tty "
    source '${COPY_PAST_ROOT}/copy.sh'
    copy -- --raw not-a-flag
  "

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "unknown option fails with COPY_ERR_USAGE (rc=2)" {
  # Arrange: no fixtures needed.

  # Act
  run --separate-stderr copy --bogus

  # Assert
  [ "$status" -eq "$COPY_ERR_USAGE" ]
  [[ "$stderr" == *'Unknown option'* ]]
}

@test "no input (no args, tty stdin) fails with COPY_ERR_USAGE (rc=2)" {
  # Arrange:
  # we explicitly allocate a pty for stdin
  # so the script enters argument mode
  # rather than reading zero bytes from a piped stdin.

  # Act
  run --separate-stderr __cp_run_with_tty "
    source '${COPY_PAST_ROOT}/copy.sh'
    copy
  "

  # Assert
  [ "$status" -eq "$COPY_ERR_USAGE" ]
}

@test "missing backend reports COPY_ERR_NO_BACKEND (rc=3)" {
  # Arrange:
  # point PATH at an empty directory,
  # so detection cannot find any backend.
  # We invoke bash by absolute path,
  # because $PATH no longer contains the bash binary either.
  local empty_bin="${BATS_TEST_TMPDIR}/empty-bin"
  mkdir -p "$empty_bin"
  local bash_bin
  bash_bin="$(command -v bash)"

  # Act
  run --separate-stderr env -i \
    HOME="$HOME" \
    PATH="$empty_bin" \
    "$bash_bin" -c '
      unset WAYLAND_DISPLAY XDG_SESSION_TYPE
      source "'"${COPY_PAST_ROOT}"'/copy.sh"
      printf "%s" "x" | copy
    '

  # Assert
  [ "$status" -eq 3 ]
  [[ "$stderr" == *'No clipboard backend found'* ]]
}

@test "exit code constants match documented values" {
  # Arrange / Act:
  # the constants are populated when copy.sh is sourced in setup().

  # Assert
  [ "$COPY_ERR_GENERAL" -eq 1 ]
  [ "$COPY_ERR_USAGE" -eq 2 ]
  [ "$COPY_ERR_NO_BACKEND" -eq 3 ]
  [ "$COPY_ERR_BACKEND_FAILED" -eq 4 ]
}

@test "constants are readonly (re-sourcing does not error)" {
  # Arrange:
  # the script guards readonly declarations behind unset checks,
  # so re-sourcing in the same shell is safe (idempotency).

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    echo ok
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = 'ok' ]
}

### End of file
