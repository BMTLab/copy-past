#!/usr/bin/env bats

# Name: tests/integration/test_roundtrip.bats
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   End-to-end round-trip tests:
#   write via copy, read via past, then compare.
#   Validates that the two scripts agree on serialisation semantics
#   and that the wl-paste trailing-newline workaround in past.sh
#   exactly cancels the newline added by the (faked) wl-paste.
#
#   The hex-comparison helper __cp_run_roundtrip_hex
#   captures `past`'s output via a sentinel byte
#   so trailing newlines survive command substitution.
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


@test "round-trip preserves byte fidelity for representative payloads" {
  # Arrange:
  # rows are 'label|printf-payload|expected-hex|extra-copy-flags'.
  # The hex column is the SHA-of-truth: when a row fails, the label
  # tells you which serialisation invariant broke.
  local -ra cases=(
    'simple-ascii|hello|68656c6c6f|'
    'multi-line-no-trailing-lf|line1\nline2\nline3|6c696e65310a6c696e65320a6c696e6533|'
    'multi-line-with-trailing-lf|a\nb\nc\n|610a620a630a|'
    'raw-keeps-ansi|\033[31mred\033[0m|1b5b33316d7265641b5b306d|--raw'
  )

  local row label payload expected flags
  for row in "${cases[@]}"; do
    label="${row%%|*}"
    local rest="${row#*|}"
    payload="${rest%%|*}"
    rest="${rest#*|}"
    expected="${rest%%|*}"
    flags="${rest#*|}"

    # Act
    if [[ -n $flags ]]; then
      run --separate-stderr __cp_run_roundtrip_hex "$payload" "$flags"
    else
      run --separate-stderr __cp_run_roundtrip_hex "$payload"
    fi

    # Assert
    [ "$status" -eq 0 ] || {
      printf 'Row %s exited with status %d\n' "$label" "$status" >&2
      printf 'stderr: %s\n' "$stderr" >&2
      false
    }
    [ "$output" = "$expected" ] || {
      printf 'Row %s mismatch:\n  got      %s\n  expected %s\n' \
        "$label" "$output" "$expected" >&2
      false
    }
  done
}

@test "round-trip: ANSI-coloured input comes back stripped by default" {
  # Arrange:
  # default copy strips the SGR escapes,
  # so past sees only the visible characters.
  local -r expected=$'red\nplain'

  # Act
  run --separate-stderr __cp_run \
    'printf "\033[31mred\033[0m\nplain" | copy; past'

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "round-trip: empty input round-trips as empty string" {
  # Arrange / Act:
  # the inner snippet writes 'empty' only when past returns
  # a zero-length string, giving us a stable assertion target.
  run --separate-stderr __cp_run '
    printf "" | copy
    out="$(past; printf x)"
    out="${out%x}"
    [[ -z "$out" ]] && echo empty
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = 'empty' ]
}

### End of file
