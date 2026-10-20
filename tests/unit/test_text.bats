#!/usr/bin/env bats

# Tests the text filters of copy.sh: the ANSI stripper and the trimmer.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

# region __cp_strip_ansi

#######################################
# Check that __cp_strip_ansi removes one kind of escape sequence.
#
# Arguments:
#   1: The input, as printf prints it with %b.
#   2: The text expected.
#######################################
function strip_ansi_removes_the_sequence() {
  local -r input="$1"
  local -r expected="$2"
  local stripped

  # Arrange: the input is the payload.

  # Act
  stripped="$(printf '%b' "${input}" | __cp_strip_ansi)"

  # Assert
  [[ "${stripped}" == "${expected}" ]]
}

# Samples: "kind|input|expected", one grammar of ECMA-48 each.
ANSI_SAMPLES=(
  'an SGR color|\033[31mred\033[0m|red'
  'an OSC 8 link that BEL ends|\033]8;;https://example.com\007text\033]8;;\007|text'
  'an OSC title that ST ends|\033]0;title\033\\after|after'
  'a private CSI mode|before \033[?25hmid \033[?25lafter|before mid after'
  'bracketed paste|\033[?2004hhello \033[?2004lworld|hello world'
  'a CSI intermediate byte|\033[ qcursor-shape|cursor-shape'
  'a short reset escape|\033cclean|clean'
  'plain text|nothing to strip|nothing to strip'
)

for ansi_sample in "${ANSI_SAMPLES[@]}"; do
  ansi_rest="${ansi_sample#*|}"
  bats_test_function \
    --description "__cp_strip_ansi removes ${ansi_sample%%|*}" \
    -- strip_ansi_removes_the_sequence "${ansi_rest%%|*}" "${ansi_rest#*|}"
done

@test "__cp_strip_ansi keeps newlines and tabs" {
  local stripped

  # Arrange: whitespace sits between the escape sequences.

  # Act
  stripped="$(printf '\033[31ma\033[0m\n\033[32mb\033[0m\tc' | __cp_strip_ansi)"

  # Assert
  [[ "${stripped}" == $'a\nb\tc' ]]
}

# endregion __cp_strip_ansi

# region __cp_trim_whitespace

@test "__cp_trim_whitespace removes the whitespace at both ends" {
  local trimmed

  # Arrange: spaces, a tab and newlines around the text.

  # Act
  trimmed="$(printf '  \t\nmiddle  \n' | __cp_trim_whitespace)"

  # Assert
  [[ "${trimmed}" == 'middle' ]]
}

@test "__cp_trim_whitespace keeps the whitespace inside" {
  local -r output_path="${BATS_TEST_TMPDIR}/trimmed.txt"

  # Arrange: spaces, a tab and a newline inside the text.

  # Act
  printf '  a b\tc\nd  ' | __cp_trim_whitespace >"${output_path}"

  # Assert: a, space, b, tab, c, newline, d; no newline at the end.
  [[ "$(print_hex <"${output_path}")" == '61206209630a64' ]]
}

@test "__cp_trim_whitespace prints nothing for whitespace alone" {
  local -r output_path="${BATS_TEST_TMPDIR}/trimmed.txt"

  # Arrange: only whitespace.

  # Act
  printf '   \t\n  ' | __cp_trim_whitespace >"${output_path}"

  # Assert
  [[ ! -s "${output_path}" ]]
}

# endregion __cp_trim_whitespace

### End
