#!/usr/bin/env bats

# Name: tests/bats/test_roundtrip.bats
# Author: Nikita Neverov (BMTLab)
# Version: 1.1.0
# Date: 2026-05-17
# License: MIT
#
# Description:
#   End-to-end round-trip tests:
#   write via copy, read via past, then compare.
#   Validates that the two scripts agree on serialisation semantics
#   and that the wl-paste trailing-newline workaround in past.sh
#   exactly cancels the newline added by the (faked) wl-paste.
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

@test "round-trip: simple ASCII string" {
  # Arrange
  # hello = 68656c6c6f
  local -r expected_hex='68656c6c6f'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    printf "%s" "hello" | copy
    out="$(past; printf x)"
    out="${out%x}"
    printf "%s" "$out" | xxd -p | tr -d "\n"
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_hex" ]
}

@test "round-trip: multi-line without trailing newline" {
  # Arrange
  # line1\nline2\nline3 = 6c696e65310a6c696e65320a6c696e6533
  local -r expected_hex='6c696e65310a6c696e65320a6c696e6533'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    printf "line1\nline2\nline3" | copy
    out="$(past; printf x)"
    out="${out%x}"
    printf "%s" "$out" | xxd -p | tr -d "\n"
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_hex" ]
}

@test "round-trip: multi-line with trailing newline" {
  # Arrange
  # a\nb\nc\n = 610a620a630a
  local -r expected_hex='610a620a630a'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    printf "a\nb\nc\n" | copy
    out="$(past; printf x)"
    out="${out%x}"
    printf "%s" "$out" | xxd -p | tr -d "\n"
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_hex" ]
}

@test "round-trip: ANSI input is stripped on default copy, comes back clean" {
  # Arrange:
  # no escapes are expected after default copy + past.
  local -r expected=$'red\nplain'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    printf "\033[31mred\033[0m\nplain" | copy
    past
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "round-trip: --raw preserves ANSI bytes through past" {
  # Arrange
  # ESC[31m red ESC[0m = 1b5b33316d 726564 1b5b306d
  local -r expected_hex='1b5b33316d7265641b5b306d'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    printf "\033[31mred\033[0m" | copy --raw
    out="$(past; printf x)"
    out="${out%x}"
    printf "%s" "$out" | xxd -p | tr -d "\n"
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_hex" ]
}

@test "round-trip: pipe-mode hello world (cross-script wiring)" {
  # Arrange:
  # this test exercises the cross-script wiring (copy → past)
  # rather than the argument-mode path specifically;
  # argument-mode parsing has its own dedicated tests in test_copy.bats.
  # Keeping the round-trip purely in pipe mode also avoids relying
  # on the caller's stdin being a TTY, which is not guaranteed
  # in every CI runner / bats version combination.
  local -r expected='hello world'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    printf "%s" "hello world" | copy
    past
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "round-trip: empty input round-trips as empty string" {
  # Arrange:
  # the inner script writes "empty"
  # only when past returns a zero-length string,
  # giving us a stable assertion target.

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    source "'"${COPY_PAST_ROOT}"'/past.sh"
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
