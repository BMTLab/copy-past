#!/usr/bin/env bats

# Tests that past reads back exactly what copy wrote.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

#######################################
# Check that a payload makes a round trip through copy and past.
#
# Arguments:
#   1: The payload, as printf prints it with %b.
#   2: The bytes that past must print, as hex.
#   3...: The options of copy.
#######################################
function payload_makes_a_round_trip() {
  local -r payload="$1"
  local -r expected_hex="$2"
  shift 2

  # Arrange: the payload and the options are the input.

  # Act
  run --separate-stderr run_roundtrip_hex "${payload}" "$@"

  # Assert
  ((status == 0))
  [[ "${output}" == "${expected_hex}" ]]
}

bats_test_function --description "plain ASCII makes a round trip" \
  -- payload_makes_a_round_trip 'hello' '68656c6c6f'
bats_test_function \
  --description "lines without a last newline make a round trip" \
  -- payload_makes_a_round_trip 'line1\nline2\nline3' \
  '6c696e65310a6c696e65320a6c696e6533'
bats_test_function \
  --description "lines with a last newline make a round trip" \
  -- payload_makes_a_round_trip 'a\nb\nc\n' '610a620a630a'
bats_test_function \
  --description "ANSI escape sequences make a round trip with --raw" \
  -- payload_makes_a_round_trip '\033[31mred\033[0m' '1b5b33316d7265641b5b306d' --raw

@test "a colored payload comes back from past without its colors" {
  # Arrange: copy removes the SGR colors by default.

  # Act
  run --separate-stderr run_snippet \
    'printf "\033[31mred\033[0m\nplain" | copy; past'

  # Assert
  ((status == 0))
  [[ "${output}" == $'red\nplain' ]]
}

@test "an empty payload comes back from past as an empty text" {
  # Arrange: past prints, then x, so a newline would show before the x.

  # Act
  run --separate-stderr run_snippet '
    printf "" | copy
    output="$(past; printf x)"
    printf "%s" "${output}"
  '

  # Assert
  ((status == 0))
  [[ "${output}" == 'x' ]]
}

### End
