#!/usr/bin/env bats

# Name: tests/integration/test_regressions.bats
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   End-to-end regression tests for bugs fixed in v1.2.0+:
#
#     1. past.sh: wl-paste failures used to be masked
#        by the trailing `printf x` inside the $() capture.
#        The new sentinel encodes the wl-paste exit code,
#        so failures propagate as PAST_ERR_BACKEND_FAILED.
#     2. copy.sh: failures of any pipeline stage
#        (sed in the strip step, or the backend itself)
#        used to be hidden by bash's default behaviour
#        of returning only the last command's exit code.
#        The pipeline now runs under `set -o pipefail`.
#
#   ANSI grammar coverage and parser-level robustness checks
#   live in the unit suite
#   (tests/unit/test_text.bats, tests/unit/test_options.bats);
#   the regression file exercises only behaviours
#   that require a real pipeline and a fake backend
#   to be observable.
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


# region Fix 1: past.sh propagates wl-paste failures

@test "past propagates wl-paste failure (exit code is no longer masked)" {
  # Arrange:
  # tell the fake wl-paste to exit non-zero.
  __cp_clipboard_set 'irrelevant'

  # Act
  run --separate-stderr __cp_run '
    export FAKE_WL_PASTE_RC=42
    past
  '

  # Assert:
  # must surface PAST_ERR_BACKEND_FAILED (rc=4), NOT 0.
  [ "$status" -eq "$PAST_ERR_BACKEND_FAILED" ]
  [[ "$stderr" == *'Clipboard backend failed to read'* ]]
}

# endregion


# region Fix 2: copy.sh detects pipeline-stage failures via pipefail

@test "copy reports backend failure when wl-copy exits non-zero" {
  # Arrange
  __cp_install_failing_wl_copy 7

  # Act
  run --separate-stderr __cp_run 'printf "%s" "data" | copy'

  # Assert:
  # pipefail must surface the backend failure
  # as COPY_ERR_BACKEND_FAILED (rc=4).
  [ "$status" -eq "$COPY_ERR_BACKEND_FAILED" ]
  [[ "$stderr" == *'Clipboard backend failed'* ]]
}

@test "copy reports backend failure even when sed succeeds (pipefail middle stage)" {
  # Arrange:
  # backend exits non-zero AFTER sed has produced clean output.
  # Without pipefail, the cleanup stage would mask this.
  __cp_install_failing_wl_copy 13

  # Act:
  # ANSI sequence forces the strip-stage to actually do work,
  # so we exercise the middle pipeline stage, not just the backend.
  run --separate-stderr __cp_run 'printf "\033[31mred\033[0m" | copy'

  # Assert
  [ "$status" -eq "$COPY_ERR_BACKEND_FAILED" ]
}

# endregion

### End of file
