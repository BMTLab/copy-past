#!/usr/bin/env bats

# Tests the bugs that were fixed, so none of them comes back.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

# region past reports a failure of wl-paste

@test "past reports a failure of wl-paste with the backend code" {
  # Arrange:
  # past puts x and the status of wl-paste after its output,
  # and once the trailing x hid the failure.
  set_clipboard 'irrelevant'

  # Act
  run --separate-stderr run_snippet '
    export FAKE_WL_PASTE_CODE=42
    past
  '

  # Assert
  ((status == PAST_ERR_BACKEND_FAILED))
  [[ "${stderr}" == *'clipboard backend failed to read'* ]]
}

# endregion past reports a failure of wl-paste

# region copy reports a failure of any stage

@test "copy reports a failure of wl-copy with the backend code" {
  # Arrange
  install_failing_wl_copy 7

  # Act
  run --separate-stderr run_snippet 'printf "%s" "data" | copy'

  # Assert
  ((status == COPY_ERR_BACKEND_FAILED))
  [[ "${stderr}" == *'clipboard backend failed'* ]]
}

@test "copy reports a failing backend after a filter that worked" {
  # Arrange:
  # sed removes the colors and succeeds, then the backend fails;
  # without pipefail, a stage before the last one would hide it.
  install_failing_wl_copy 13

  # Act
  run --separate-stderr run_snippet 'printf "\033[31mred\033[0m" | copy'

  # Assert
  ((status == COPY_ERR_BACKEND_FAILED))
}

# endregion copy reports a failure of any stage

# region copy keeps the backend off the output of its caller

@test "copy inside \$(...) returns while the backend still serves the clipboard" {
  # Arrange:
  # like the real wl-copy, the fake leaves a process behind
  # that keeps the stdout and stderr it got, here for 10 s.
  install_forking_wl_copy 10

  # Act: $(...) waits until no process holds its pipe.
  run --separate-stderr run_snippet '
    started="${SECONDS}"
    captured="$(printf "%s" "data" | copy)"
    printf "%s" "$((SECONDS - started))"
  '

  # Assert: the capture ends long before the process left behind.
  ((status == 0))
  [[ "${output}" =~ ^[0-9]+$ ]]
  ((output < 5))
  [[ "$(print_clipboard)" == 'data' ]]
}

@test "copy still shows the error message of a failing backend" {
  # Arrange
  install_failing_wl_copy 1 'wl-copy: failed to connect to a Wayland server'

  # Act
  run --separate-stderr run_snippet 'printf "%s" "data" | copy'

  # Assert: the message of the backend comes with the one of copy.
  ((status == COPY_ERR_BACKEND_FAILED))
  [[ "${stderr}" == *'wl-copy: failed to connect to a Wayland server'* ]]
  [[ "${stderr}" == *'clipboard backend failed'* ]]
}

# endregion copy keeps the backend off the output of its caller

### End
