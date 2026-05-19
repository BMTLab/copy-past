#!/usr/bin/env bats

# Name: tests/integration/test_past.bats
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   End-to-end behavioural tests for past.sh.
#   Uses a fake clipboard backend (see tests/support/fakes.bash),
#   so the tests are hermetic
#   and never touch the real system clipboard.
#
#   Scope:
#     - reading the clipboard verbatim
#     - the wl-paste trailing-newline workaround
#       for wl-clipboard <= 2.2.1
#     - help / no-backend error paths
#     - exit-code constants match documented values
#
#   Pure parser-level cases live in tests/unit/test_options.bats.
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


# region Reading semantics

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

@test "past preserves trailing-newline state byte-for-byte" {
  # Arrange:
  # rows are 'label|set-payload|expected-hex'.
  # The 0x0a at the end of expected_hex is the only signal of
  # whether the source had a trailing newline; past must NOT add one
  # of its own, and must NOT strip an existing one.
  local -ra cases=(
    'no-trailing-lf|line1\nline2\nline3|6c696e65310a6c696e65320a6c696e6533'
    'with-trailing-lf|line1\nline2\n|6c696e65310a6c696e65320a'
    'preserves-ansi-bytes|\033[31mred\033[0m|1b5b33316d7265641b5b306d'
  )

  local row label payload expected
  for row in "${cases[@]}"; do
    label="${row%%|*}"
    local rest="${row#*|}"
    payload="${rest%%|*}"
    expected="${rest#*|}"

    # Decode the printf-format payload via `printf -v` (NOT command
    # substitution), so trailing newlines survive and reach the
    # clipboard intact. Command substitution would silently strip
    # them and the 'with-trailing-lf' row would always fail.
    local decoded
    # shellcheck disable=SC2059
    printf -v decoded "$payload"
    __cp_clipboard_set "$decoded"

    # Act:
    # capture past's raw output via the sentinel helper,
    # then dump it as a single hex line.
    # We pipe DIRECTLY into __cp_hex without an intermediate $()
    # because command substitution silently strips trailing newlines,
    # and the trailing-newline state is exactly what we are testing.
    local got
    got="$(__cp_run_past_raw | __cp_hex)"

    # Assert
    [ "$got" = "$expected" ] || {
      printf 'Row %s mismatch:\n  got      %s\n  expected %s\n' \
        "$label" "$got" "$expected" >&2
      false
    }
  done
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

# endregion


# region Help / error paths

@test "--help prints usage to stdout and exits 0" {
  # Arrange / Act
  run --separate-stderr past --help

  # Assert
  [ "$status" -eq 0 ]
  [[ "$output" == *'past - print system clipboard'* ]]
  [[ "$output" == *'--debug'* ]]
}

@test "missing backend reports PAST_ERR_NO_BACKEND (rc=3)" {
  # Arrange / Act
  run --separate-stderr __cp_run_no_backend "
    source '${COPY_PAST_ROOT}/past.sh'
    past
  "

  # Assert
  [ "$status" -eq "$PAST_ERR_NO_BACKEND" ]
  [[ "$stderr" == *'No clipboard backend found'* ]]
}

# endregion


# region Constants

@test "exit code constants match documented values" {
  # Arrange / Act:
  # the constants are populated when past.sh is sourced in setup().

  # Assert
  [ "$PAST_ERR_GENERAL" -eq 1 ]
  [ "$PAST_ERR_USAGE" -eq 2 ]
  [ "$PAST_ERR_NO_BACKEND" -eq 3 ]
  [ "$PAST_ERR_BACKEND_FAILED" -eq 4 ]
  [ "$PAST_ERR_TYPE_MISMATCH" -eq 5 ]
}

@test "constants survive re-sourcing (idempotency)" {
  # Arrange / Act
  run --separate-stderr __cp_run 'echo ok'

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = 'ok' ]
}

# endregion

### End of file
