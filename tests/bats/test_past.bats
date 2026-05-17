#!/usr/bin/env bats

# Name: tests/bats/test_past.bats
# Author: Nikita Neverov (BMTLab)
# Version: 1.1.0
# Date: 2026-05-17
# License: MIT
#
# Description:
#   Behavioural tests for past.sh.
#   Uses a fake clipboard backend (see test_helper.bash),
#   so the tests are hermetic
#   and never touch the real system clipboard.
#
#   Each test follows the Arrange-Act-Assert (AAA) pattern.
#
#   Coverage:
#     - reading the clipboard verbatim (including binary fidelity)
#     - the wl-paste trailing-newline workaround
#       for wl-clipboard ≤ 2.2.1
#     - help / option handling
#     - error paths (no backend)
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

@test "past prints clipboard content verbatim" {
  # Arrange
  local -r payload='hello world'
  __cp_clipboard_set "$payload"

  # Act
  run --separate-stderr past

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = "$payload" ]
}

@test "past does NOT add a trailing newline when source has none" {
  # Arrange
  __cp_clipboard_set $'line1\nline2\nline3'
  # ASCII bytes: line1\nline2\nline3 (no trailing 0a)
  # 6c 69 6e 65 31 0a 6c 69 6e 65 32 0a 6c 69 6e 65 33
  local -r expected_hex='6c696e65310a6c696e65320a6c696e6533'

  # Act:
  # `run` swallows the captured output's trailing newline,
  # so we capture raw bytes with a sentinel
  # and dump them as hex instead.
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    out="$(past; printf x)"
    out="${out%x}"
    printf "%s" "$out" | xxd -p
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_hex" ]
}

@test "past preserves single trailing newline from source" {
  # Arrange
  __cp_clipboard_set $'line1\nline2\n'
  # line1\nline2\n
  local -r expected_hex='6c696e65310a6c696e65320a'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    out="$(past; printf x)"
    out="${out%x}"
    printf "%s" "$out" | xxd -p
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_hex" ]
}

@test "past returns empty string for empty clipboard" {
  # Arrange
  __cp_clipboard_set ''

  # Act
  run --separate-stderr past

  # Assert
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "past preserves ANSI escape sequences (does not strip)" {
  # Arrange:
  # past is a faithful reader;
  # stripping is copy's responsibility.
  __cp_clipboard_set $'\033[31mred\033[0m'
  # ESC[31m red ESC[0m → 1b5b33316d 726564 1b5b306d
  local -r expected_hex='1b5b33316d7265641b5b306d'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    out="$(past; printf x)"
    out="${out%x}"
    printf "%s" "$out" | xxd -p
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_hex" ]
}

@test "-h prints help to stdout and exits 0" {
  # Arrange: no fixtures needed.

  # Act
  run --separate-stderr past -h

  # Assert
  [ "$status" -eq 0 ]
  [[ "$output" == *'past - print system clipboard'* ]]
}

@test "--help prints help to stdout and exits 0" {
  # Arrange: no fixtures needed.

  # Act
  run --separate-stderr past --help

  # Assert
  [ "$status" -eq 0 ]
  [[ "$output" == *'past - print system clipboard'* ]]
}

@test "missing backend reports PAST_ERR_NO_BACKEND (rc=3)" {
  # Arrange:
  # point PATH at an empty directory,
  # so detection cannot find any backend.
  # We invoke bash by absolute path,
  # because $PATH no longer contains the bash binary either.
  local empty_bin="${BATS_TEST_TMPDIR}/empty-bin-past"
  mkdir -p "$empty_bin"
  local bash_bin
  bash_bin="$(command -v bash)"

  # Act
  run --separate-stderr env -i \
    HOME="$HOME" \
    PATH="$empty_bin" \
    "$bash_bin" -c '
      unset WAYLAND_DISPLAY XDG_SESSION_TYPE
      source "'"${COPY_PAST_ROOT}"'/past.sh"
      past
    '

  # Assert
  [ "$status" -eq 3 ]
  [[ "$stderr" == *'No clipboard backend found'* ]]
}

@test "exit code constants match documented values" {
  # Arrange / Act:
  # the constants are populated when past.sh is sourced in setup().

  # Assert
  [ "$PAST_ERR_GENERAL" -eq 1 ]
  [ "$PAST_ERR_NO_BACKEND" -eq 3 ]
  [ "$PAST_ERR_BACKEND_FAILED" -eq 4 ]
}

@test "constants are readonly (re-sourcing does not error)" {
  # Arrange:
  # the script guards readonly declarations behind unset checks,
  # so re-sourcing in the same shell is safe.

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    echo ok
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = 'ok' ]
}

### End of file