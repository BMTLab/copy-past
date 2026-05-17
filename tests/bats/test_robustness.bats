#!/usr/bin/env bats

# Name: tests/bats/test_robustness.bats
# Author: Nikita Neverov (BMTLab)
# Version: 1.0.0
# Date: 2026-05-17
# License: MIT
#
# Description:
#   Regression tests for the robustness fixes applied in v1.2.0:
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
#     3. copy.sh: ANSI stripping now covers private-mode CSI sequences
#        (ESC[?…), short ESC controls (ESC c),
#        and OSC sequences terminated by ESC \ (ST), not just BEL.
#     4. COPY_PAST_BACKEND override:
#        forces a specific backend
#        and rejects unknown values
#        with COPY_ERR_USAGE / PAST_ERR_USAGE.
#     5. past.sh: rejects unknown positional arguments
#        instead of silently ignoring them.
#
#   Each test follows the Arrange-Act-Assert (AAA) pattern.
#
# Disclaimer:
#   This script is provided "as is", without any warranty.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

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
  run --separate-stderr bash -c '
    export FAKE_WL_PASTE_RC=42
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    past
  '

  # Assert:
  # must surface PAST_ERR_BACKEND_FAILED (rc=4), NOT 0.
  [ "$status" -eq "$PAST_ERR_BACKEND_FAILED" ]
  [[ "$stderr" == *'Clipboard backend failed to read'* ]]
}

@test "past returns success when wl-paste exits 0 (control case for fix 1)" {
  # Arrange:
  # sanity check that the failure path from the previous test
  # is genuinely conditional on FAKE_WL_PASTE_RC.
  __cp_clipboard_set 'works'

  # Act
  run --separate-stderr past

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = 'works' ]
}

# endregion


# region Fix 2: copy.sh detects pipeline-stage failures via pipefail

@test "copy reports backend failure when wl-copy exits non-zero" {
  # Arrange:
  # replace the working wl-copy fake with a failing one.
  cat > "${FAKE_BIN}/wl-copy" << 'EOF'
#!/usr/bin/env bash
cat > /dev/null
exit 7
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "data" | copy
  '

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
  cat > "${FAKE_BIN}/wl-copy" << 'EOF'
#!/usr/bin/env bash
cat > /dev/null
exit 13
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "\033[31mred\033[0m" | copy
  '

  # Assert
  [ "$status" -eq "$COPY_ERR_BACKEND_FAILED" ]
}

# endregion


# region Fix 3: extended ANSI stripping coverage

@test "ANSI stripping handles private-mode CSI (ESC[?25h cursor toggle)" {
  # Arrange
  local -r expected='before mid after'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "before \033[?25hmid \033[?25lafter" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "ANSI stripping handles bracketed-paste mode toggles (ESC[?2004h)" {
  # Arrange
  local -r expected='hello world'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "\033[?2004hhello \033[?2004lworld" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "ANSI stripping handles short ESC controls (ESC c reset)" {
  # Arrange
  local -r expected='clean'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "\033cclean" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "ANSI stripping handles OSC terminated by ESC \\ (ST)" {
  # Arrange:
  # OSC 0 ; window title <ST>, where ST = ESC '\'.
  local -r expected='title-stripped'

  # Act:
  # note the quadruple backslash;
  # bash -c expands '\\\\' → '\\' before printf,
  # then printf converts '\\' → '\'.
  # The leading '\033' escape is similarly subject
  # to one round of expansion.
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "\033]0;my title\033\\\\title-stripped" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "ANSI stripping handles CSI with intermediate bytes (ESC[ ! q)" {
  # Arrange:
  # DECSCUSR-like sequence with a 0x20-0x2F intermediate.
  local -r expected='cursor-shape'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "\033[ qcursor-shape" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

# endregion


# region Fix 4: COPY_PAST_BACKEND override

@test "COPY_PAST_BACKEND=xclip forces xclip even on Wayland" {
  # Arrange
  __cp_enable_xclip_fake

  # Act
  run --separate-stderr bash -c '
    export COPY_PAST_BACKEND=xclip
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "via xclip" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = 'via xclip' ]
}

@test "COPY_PAST_BACKEND=xsel forces xsel" {
  # Arrange
  __cp_enable_xsel_fake

  # Act
  run --separate-stderr bash -c '
    export COPY_PAST_BACKEND=xsel
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "via xsel" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = 'via xsel' ]
}

@test "COPY_PAST_BACKEND=wl-clipboard works on copy and past round-trip" {
  # Arrange
  local -r expected_hex='726f756e642d74726970'

  # Act
  run --separate-stderr bash -c '
    export COPY_PAST_BACKEND=wl-clipboard
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    printf "%s" "round-trip" | copy
    out="$(past; printf x)"
    out="${out%x}"
    printf "%s" "$out" | xxd -p | tr -d "\n"
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_hex" ]
}

@test "COPY_PAST_BACKEND=bogus on copy fails with COPY_ERR_USAGE" {
  # Arrange: no setup needed.

  # Act
  run --separate-stderr bash -c '
    export COPY_PAST_BACKEND=bogus
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "x" | copy
  '

  # Assert
  [ "$status" -eq "$COPY_ERR_USAGE" ]
  [[ "$stderr" == *'Unknown COPY_PAST_BACKEND'* ]]
}

@test "COPY_PAST_BACKEND=bogus on past fails with PAST_ERR_USAGE" {
  # Arrange: no setup needed.

  # Act
  run --separate-stderr bash -c '
    export COPY_PAST_BACKEND=bogus
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    past
  '

  # Assert
  [ "$status" -eq "$PAST_ERR_USAGE" ]
  [[ "$stderr" == *'Unknown COPY_PAST_BACKEND'* ]]
}

@test "COPY_PAST_BACKEND=xclip without xclip installed reports no-backend" {
  # Arrange:
  # explicitly remove the xclip fake AND restrict PATH to FAKE_BIN
  # only, so a system-installed xclip on the runner cannot satisfy
  # the override. Without the PATH restriction this test was a
  # tautology: it passed locally only because the developer's box
  # happened to lack xclip on $PATH.
  rm -f "${FAKE_BIN}/xclip"
  local bash_bin
  bash_bin="$(command -v bash)"

  # Act
  run --separate-stderr env -i \
    HOME="$HOME" \
    PATH="${FAKE_BIN}" \
    COPY_PAST_BACKEND=xclip \
    "$bash_bin" -c '
      source "'"${COPY_PAST_ROOT}"'/copy.sh"
      printf "%s" "x" | copy
    '

  # Assert
  [ "$status" -eq "$COPY_ERR_NO_BACKEND" ]
  [[ "$stderr" == *'No clipboard backend found'* ]]
}

# endregion


# region Fix 5: past rejects unknown positional arguments

@test "past rejects unknown positional argument with PAST_ERR_USAGE" {
  # Arrange
  __cp_clipboard_set 'data'

  # Act
  run --separate-stderr past unexpected-arg

  # Assert
  [ "$status" -eq "$PAST_ERR_USAGE" ]
  [[ "$stderr" == *'Unknown argument'* ]]
}

@test "past with no arguments still works (control case for fix 5)" {
  # Arrange
  __cp_clipboard_set 'normal-read'

  # Act
  run --separate-stderr past

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = 'normal-read' ]
}

# endregion


# region Fix 9: PAST_ERR_USAGE constant exists and matches docs

@test "PAST_ERR_USAGE constant equals 2 (consistent with COPY_ERR_USAGE)" {
  # Arrange / Act:
  # constants are populated by source in setup().

  # Assert
  [ "$PAST_ERR_USAGE" -eq 2 ]
}

# endregion

### End of file