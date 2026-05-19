#!/usr/bin/env bats

# Name: tests/integration/test_backends.bats
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   Backend support matrix for copy-past.
#
#   Different clipboard backends expose different capabilities:
#
#     | Feature              | wl-clipboard | xclip | xsel |
#     | -------------------- | :----------: | :---: | :--: |
#     | plain text round-trip|      yes     |  yes  |  yes |
#     | --type MIME forward  |      yes     |  yes  |  no  |
#     | --json (text MIME)   |      yes     |  yes  |  no  |
#     | --image (binary MIME)|      yes     |  yes  |  no  |
#     | wl-paste \n quirk    |      yes     |  no   |  no  |
#
#   This file is the executable form of that matrix.
#   When a backend acquires (or loses) a capability,
#   the table above and the corresponding test must change together.
#
#   Backend selection is always explicit via COPY_PAST_BACKEND,
#   so the tests are deterministic regardless of the host:
#   the fake backends supplied by tests/support/fakes.bash provide
#   real wl-copy / wl-paste / xclip / xsel binaries on $PATH.
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
  __cp_enable_xclip_fake
  __cp_enable_xsel_fake
}


# region Override knob: COPY_PAST_BACKEND selects the backend

@test "COPY_PAST_BACKEND picks the documented backend (every value)" {
  # Arrange:
  # rows are 'env-value|expected-backend|payload'.
  # The matrix below mirrors the case-statement in __cp_detect_backend.
  local -ra cases=(
    'wl-clipboard|wl-copy|via wl'
    'wayland|wl-copy|via wayland alias'
    'wl-copy|wl-copy|via wl-copy alias'
    'xclip|xclip|via xclip'
    'xsel|xsel|via xsel'
  )

  local row env_value expected_backend payload
  for row in "${cases[@]}"; do
    env_value="${row%%|*}"
    local rest="${row#*|}"
    expected_backend="${rest%%|*}"
    payload="${rest#*|}"

    # Reset the clipboard so a previous row cannot leak into this one.
    __cp_clipboard_set ''

    # Act
    run --separate-stderr bash -c "
      export COPY_PAST_BACKEND='${env_value}'
      source '${COPY_PAST_ROOT}/copy.sh'
      printf '%s' '${payload}' | copy --debug
    "

    # Assert
    [ "$status" -eq 0 ] || {
      printf 'env=%s status=%d\n' "$env_value" "$status" >&2
      false
    }
    __cp_assert_debug_event 'backend-resolved' \
      "backend=${expected_backend}"
    [ "$(__cp_clipboard_dump)" = "$payload" ] || {
      printf 'env=%s clipboard mismatch: got %q\n' \
        "$env_value" "$(__cp_clipboard_dump)" >&2
      false
    }
  done
}

@test "COPY_PAST_BACKEND=bogus is a usage error on copy and past" {
  # Arrange / Act (copy)
  run --separate-stderr bash -c "
    export COPY_PAST_BACKEND=bogus
    source '${COPY_PAST_ROOT}/copy.sh'
    printf '%s' 'x' | copy --no-auto
  "

  # Assert (copy)
  [ "$status" -eq "$COPY_ERR_USAGE" ]
  [[ "$stderr" == *'Unknown COPY_PAST_BACKEND'* ]]

  # Act (past)
  run --separate-stderr bash -c "
    export COPY_PAST_BACKEND=bogus
    source '${COPY_PAST_ROOT}/past.sh'
    past
  "

  # Assert (past)
  [ "$status" -eq "$PAST_ERR_USAGE" ]
  [[ "$stderr" == *'Unknown COPY_PAST_BACKEND'* ]]
}

@test "COPY_PAST_BACKEND=xclip without xclip on PATH reports no-backend" {
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
    "$bash_bin" -c "
      source '${COPY_PAST_ROOT}/copy.sh'
      printf '%s' 'x' | copy
    "

  # Assert
  [ "$status" -eq "$COPY_ERR_NO_BACKEND" ]
  [[ "$stderr" == *'No clipboard backend found'* ]]
}

# endregion


# region Plain text round-trip (every backend supports this)

@test "every supported backend round-trips plain text" {
  # Arrange:
  # one row per backend -> all three pairs of fakes share the same
  # clipboard file, so a successful round-trip proves
  # the (backend, copy/past) wiring is correct.
  local -ra backends=(wl-clipboard xclip xsel)
  local backend payload

  for backend in "${backends[@]}"; do
    # Reset the clipboard for a clean per-backend assertion.
    __cp_clipboard_set ''
    payload="round-trip-${backend}"

    # Act
    run --separate-stderr bash -c "
      export COPY_PAST_BACKEND='${backend}'
      source '${COPY_PAST_ROOT}/copy.sh'
      source '${COPY_PAST_ROOT}/past.sh'
      printf '%s' '${payload}' | copy
      past
    "

    # Assert
    [ "$status" -eq 0 ] || {
      printf 'backend=%s status=%d\n' "$backend" "$status" >&2
      false
    }
    [ "$output" = "$payload" ] || {
      printf 'backend=%s mismatch: got %q\n' \
        "$backend" "$output" >&2
      false
    }
  done
}

# endregion


# region MIME-aware backends accept --json and --image

@test "wl-clipboard and xclip accept --json and --image (no TYPE_MISMATCH)" {
  # Arrange:
  # rows are 'backend|flag|expected-mime'.
  # Only backends that actually support MIME are listed; the xsel
  # rejection is covered in its own test below.
  local -ra cases=(
    'wl-clipboard|--json|application/json'
    'wl-clipboard|--image|image/png'
    'xclip|--json|application/json'
    'xclip|--image|image/png'
  )

  local row backend flag expected_mime
  for row in "${cases[@]}"; do
    backend="${row%%|*}"
    local rest="${row#*|}"
    flag="${rest%%|*}"
    expected_mime="${rest#*|}"

    __cp_clipboard_set ''

    # Act:
    # --image needs binary input that cannot be JSON, otherwise
    # auto-detection on the JSON case would still pick it up via jq.
    # We pass an explicit MIME flag in both rows, so the input
    # itself does not matter for this assertion.
    run --separate-stderr bash -c "
      export COPY_PAST_BACKEND='${backend}'
      source '${COPY_PAST_ROOT}/copy.sh'
      printf '%s' '{\"k\":1}' | copy --debug ${flag}
    "

    # Assert
    [ "$status" -eq 0 ] || {
      printf 'backend=%s flag=%s status=%d\n' \
        "$backend" "$flag" "$status" >&2
      printf 'stderr: %s\n' "$stderr" >&2
      false
    }
    __cp_assert_debug_event 'options-parsed' \
      "mime=${expected_mime}"
  done
}

# endregion


# region xsel rejects every MIME-aware feature

@test "xsel rejects --json, --image, and past --type with TYPE_MISMATCH" {
  # Arrange:
  # rows are 'flag-set|expected-error-substring'.
  # The shared exit code is 5 (COPY_ERR_TYPE_MISMATCH /
  # PAST_ERR_TYPE_MISMATCH), with the same human-readable hint
  # mentioning xsel's MIME limitation.
  local -ra copy_cases=(
    '--json'
    '--image'
  )

  local flags
  for flags in "${copy_cases[@]}"; do
    # Act
    run --separate-stderr bash -c "
      export COPY_PAST_BACKEND=xsel
      source '${COPY_PAST_ROOT}/copy.sh'
      printf '%s' 'x' | copy ${flags}
    "

    # Assert
    [ "$status" -eq "$COPY_ERR_TYPE_MISMATCH" ] || {
      printf 'flags=%s status=%d\n' "$flags" "$status" >&2
      false
    }
    [[ "$stderr" == *'xsel does not support MIME types'* ]] || {
      printf 'flags=%s stderr did not mention xsel: %s\n' \
        "$flags" "$stderr" >&2
      false
    }
  done

  # Also covers past --type with the same backend.
  __cp_clipboard_set 'data'
  run --separate-stderr bash -c "
    export COPY_PAST_BACKEND=xsel
    source '${COPY_PAST_ROOT}/past.sh'
    past --type application/json
  "
  [ "$status" -eq "$PAST_ERR_TYPE_MISMATCH" ]
  [[ "$stderr" == *'xsel does not support MIME types'* ]]
}

# endregion


# region wl-paste-only quirk (trailing-newline workaround)

@test "past read-strategy depends on backend AND payload kind" {
  # Arrange:
  # rows are 'backend|past-flags|expected-strategy'.
  # The matrix encodes the routing rule in __ps_emit_clipboard:
  #   - wl-paste + text MIME -> newline-strip (workaround)
  #   - wl-paste + binary MIME -> direct-exec (preserve NULs)
  #   - xclip / xsel -> always direct-exec (no quirk to undo)
  __cp_clipboard_set 'placeholder'
  local -ra cases=(
    'wl-clipboard||wl-paste-newline-strip'
    'wl-clipboard|--image|direct-exec'
    'xclip||direct-exec'
    'xsel||direct-exec'
  )

  local row backend flags expected
  for row in "${cases[@]}"; do
    backend="${row%%|*}"
    local rest="${row#*|}"
    flags="${rest%%|*}"
    expected="${rest#*|}"

    # Act:
    # discard stdout so binary MIME read does not pollute test output.
    run --separate-stderr bash -c "
      export COPY_PAST_BACKEND='${backend}'
      source '${COPY_PAST_ROOT}/past.sh'
      past --debug ${flags} > /dev/null
    "

    # Assert
    [ "$status" -eq 0 ] || {
      printf 'backend=%s flags=%q status=%d\n' \
        "$backend" "$flags" "$status" >&2
      false
    }
    __cp_assert_debug_event 'read-strategy' "mode=${expected}"
  done
}

# endregion

### End of file
