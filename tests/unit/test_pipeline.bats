#!/usr/bin/env bats

# Name: tests/unit/test_pipeline.bats
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   Unit tests for the helpers that move bytes through copy()'s
#   payload-shaping phases:
#     - __cp_buffer_input        (stdin/argv into a temp file)
#     - __cp_capture_prelude     (snapshot existing clipboard)
#     - __cp_stream_with_prelude (concatenate prelude + stdin)
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


# region __cp_buffer_input

@test "__cp_buffer_input captures piped stdin verbatim" {
  # Arrange
  local buffer=''

  # Act
  __cp_buffer_input buffer <<< 'piped content'

  # Assert
  [ -f "$buffer" ]
  # `<<<` adds a trailing newline; that is normal here-string behaviour.
  [ "$(cat "$buffer")" = 'piped content' ]

  # Cleanup
  rm -f -- "$buffer"
}

@test "__cp_buffer_input joins positional argv with single spaces" {
  # Arrange:
  # __cp_buffer_input checks `[[ ! -t 0 ]]` to decide between
  # the pipe and argv branches. We need an argv-branch run,
  # so we wrap the call in a real pty via __cp_run_with_tty.
  # The pty wrapper translates LF to CRLF on stdout,
  # so we sidestep that by writing the chosen buffer path
  # to a file outside the pty, then read it from this test's shell.
  local -r path_file="${BATS_TEST_TMPDIR}/argv.bufpath"

  # Act
  __cp_run_with_tty "
    source '${COPY_PAST_ROOT}/copy.sh'
    buf=''
    __cp_buffer_input buf first second third
    printf '%s' \"\$buf\" > '${path_file}'
  " >/dev/null

  # Assert
  local -r buffer_path="$(< "$path_file")"
  [ -f "$buffer_path" ]
  # `echo "$*"` emits a trailing newline, so we strip it before compare.
  [ "$(cat "$buffer_path")" = 'first second third' ]

  # Cleanup
  rm -f -- "$buffer_path"
}

@test "__cp_buffer_input fails with COPY_ERR_USAGE on no input at all" {
  # Arrange / Act:
  # use the pty wrapper to simulate a tty stdin
  # AND no positional arguments.
  run --separate-stderr __cp_run_with_tty "
    source '${COPY_PAST_ROOT}/copy.sh'
    buf=''
    __cp_buffer_input buf
    echo \"rc=\$?\"
  "

  # Assert
  echo "$output" | grep -q "rc=${COPY_ERR_USAGE}"
}

# endregion


# region __cp_capture_prelude

@test "__cp_capture_prelude no-ops when --append is off" {
  # Arrange
  local prelude='dirty'

  # Act
  __cp_capture_prelude prelude 0

  # Assert
  [ "$prelude" = '' ]
}

@test "__cp_capture_prelude snapshots clipboard into a temp file" {
  # Arrange
  __cp_clipboard_set 'existing buffer'
  local prelude=''

  # Act
  __cp_capture_prelude prelude 1

  # Assert
  [ -f "$prelude" ]
  [ "$(cat "$prelude")" = 'existing buffer' ]

  # Cleanup
  rm -f -- "$prelude"
}

# endregion


# region __cp_stream_with_prelude

@test "__cp_stream_with_prelude with empty path acts as cat" {
  # Arrange
  local -r expected='just stdin'

  # Act
  local got
  got="$(printf '%s' "$expected" | __cp_stream_with_prelude '')"

  # Assert
  [ "$got" = "$expected" ]
}

@test "__cp_stream_with_prelude prefixes prelude before stdin" {
  # Arrange
  local prelude_path
  prelude_path="$(mktemp -p "$BATS_TEST_TMPDIR")"
  printf '%s' 'OLD-' > "$prelude_path"

  # Act
  local got
  got="$(printf '%s' 'NEW' | __cp_stream_with_prelude "$prelude_path")"

  # Assert
  [ "$got" = 'OLD-NEW' ]

  # Cleanup
  rm -f -- "$prelude_path"
}

# endregion

### End of file
