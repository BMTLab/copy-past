#!/usr/bin/env bats

# Name: tests/integration/test_copy.bats
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   End-to-end behavioural tests for copy.sh.
#   Uses a fake clipboard backend (see tests/support/fakes.bash),
#   so the tests are hermetic
#   and never touch the real system clipboard.
#
#   Scope:
#     - argument mode (joining, single-arg)
#     - pipe mode    (multi-line, trailing-newline preservation)
#     - default ANSI stripping vs --raw
#     - help / unknown-option / no-input / no-backend error paths
#     - exit-code constants match documented values
#
#   Pure parser-level cases
#     (synonyms, --type=MIME equals form, malformed values, etc.)
#     live in tests/unit/test_options.bats.
#   ANSI-stripping coverage of additional escape grammars
#     lives in tests/unit/test_text.bats.
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


# region Argument mode

@test "argument mode copies a single argument" {
  # Arrange
  local -r payload='hello world'

  # Act:
  # argument mode requires stdin to be a tty
  # (otherwise the script enters pipe mode);
  # see __cp_run_with_tty for the pty trick.
  run --separate-stderr __cp_run_copy_argv "'$payload'"

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$payload" ]
}

@test "argument mode joins multiple args with single spaces" {
  # Arrange
  local -r expected='line 1 with spaces two'

  # Act
  run --separate-stderr __cp_run_copy_argv \
    "line 1 'with spaces' two"

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

# endregion


# region Pipe mode (byte fidelity)

@test "pipe mode preserves byte fidelity for canonical payloads" {
  # Arrange:
  # rows are 'label|printf-payload|expected-hex'.
  # Covers single-line, multi-line, and trailing-newline cases
  # in one table-driven test, since the pipe-mode wiring is the
  # same code path: only the input bytes change.
  local -ra cases=(
    'single-line|abc|616263'
    'multi-line-no-trailing-lf|line1\nline2\nline3|6c696e65310a6c696e65320a6c696e6533'
    'multi-line-with-trailing-lf|line1\nline2\n|6c696e65310a6c696e65320a'
  )

  local row label payload expected
  for row in "${cases[@]}"; do
    label="${row%%|*}"
    local rest="${row#*|}"
    payload="${rest%%|*}"
    expected="${rest#*|}"

    # Reset the clipboard so a previous row cannot leak into this one.
    __cp_clipboard_set ''

    # Act
    run --separate-stderr __cp_run "printf '${payload}' | copy"

    # Assert
    [ "$status" -eq 0 ] || {
      printf 'Row %s exited with %d\n' "$label" "$status" >&2
      false
    }
    local got
    got="$(__cp_clipboard_hex)"
    [ "$got" = "$expected" ] || {
      printf 'Row %s mismatch:\n  got      %s\n  expected %s\n' \
        "$label" "$got" "$expected" >&2
      false
    }
  done
}

# endregion


# region ANSI stripping (default vs --raw)

@test "ANSI escape sequences are stripped by default" {
  # Arrange:
  # SGR colors and a hyperlink (OSC) embedded in the payload.
  local -r expected=$'red\ngreen'

  # Act
  run --separate-stderr __cp_run \
    'printf "\033[31mred\033[0m\n\033[32mgreen\033[0m" | copy'

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "--raw preserves ANSI escape sequences (pipe and argument modes)" {
  # Arrange
  local -r expected=$'\033[31mred\033[0m'

  # Act (pipe mode)
  run --separate-stderr __cp_run \
    'printf "\033[31mred\033[0m" | copy --raw'
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]

  # Reset the clipboard so the second assertion is meaningful.
  __cp_clipboard_set ''

  # Act (argument mode)
  run --separate-stderr __cp_run_copy_argv "--raw $'\\033[31mred\\033[0m'"

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "ANSI stripping leaves plain text untouched" {
  # Arrange
  local -r expected='plain text without escapes'

  # Act
  run --separate-stderr __cp_run \
    'printf "%s" "plain text without escapes" | copy'

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

# endregion


# region Help / option-parsing dispatch

@test "--help prints usage to stdout and exits 0" {
  # Arrange / Act
  run --separate-stderr copy --help

  # Assert
  [ "$status" -eq 0 ]
  [[ "$output" == *'copy - write'*'system clipboard'* ]]
  [[ "$output" == *'--raw'* ]]
  [[ "$output" == *'--debug'* ]]
}

@test "-- terminates option parsing; subsequent args become text" {
  # Arrange
  local -r expected='--raw not-a-flag'

  # Act
  run --separate-stderr __cp_run_copy_argv "-- --raw not-a-flag"

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "unknown option fails with COPY_ERR_USAGE (rc=2)" {
  # Arrange / Act
  run --separate-stderr copy --bogus

  # Assert
  [ "$status" -eq "$COPY_ERR_USAGE" ]
  [[ "$stderr" == *'Unknown option'* ]]
}

# endregion


# region Error paths

@test "no input (no args, tty stdin) fails with COPY_ERR_USAGE (rc=2)" {
  # Arrange:
  # we explicitly allocate a pty for stdin
  # so the script enters argument mode
  # rather than reading zero bytes from a piped stdin.

  # Act
  run --separate-stderr __cp_run_copy_argv ''

  # Assert
  [ "$status" -eq "$COPY_ERR_USAGE" ]
}

@test "missing backend reports COPY_ERR_NO_BACKEND (rc=3)" {
  # Arrange / Act
  run --separate-stderr __cp_run_no_backend "
    source '${COPY_PAST_ROOT}/copy.sh'
    printf '%s' x | copy
  "

  # Assert
  [ "$status" -eq "$COPY_ERR_NO_BACKEND" ]
  [[ "$stderr" == *'No clipboard backend found'* ]]
}

# endregion


# region Constants

@test "exit code constants match documented values" {
  # Arrange / Act:
  # the constants are populated when copy.sh is sourced in setup().

  # Assert
  [ "$COPY_ERR_GENERAL" -eq 1 ]
  [ "$COPY_ERR_USAGE" -eq 2 ]
  [ "$COPY_ERR_NO_BACKEND" -eq 3 ]
  [ "$COPY_ERR_BACKEND_FAILED" -eq 4 ]
  [ "$COPY_ERR_TYPE_MISMATCH" -eq 5 ]
}

@test "constants survive re-sourcing (idempotency)" {
  # Arrange / Act:
  # __cp_run sources both copy.sh and past.sh,
  # so a successful inner `echo ok` proves re-sourcing
  # did not trip a `readonly` redeclaration.
  run --separate-stderr __cp_run 'echo ok'

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = 'ok' ]
}

# endregion

### End of file
