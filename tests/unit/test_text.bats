#!/usr/bin/env bats

# Name: tests/unit/test_text.bats
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   Unit tests for text-transformation helpers in copy.sh:
#     - __cp_strip_ansi      (ECMA-48 escape sequence stripper)
#     - __cp_trim_whitespace (leading/trailing whitespace trimmer)
#
#   Each helper is exercised directly via stdin/stdout
#   instead of going through the full copy() pipeline,
#   so the grammar coverage is faster and the assertions
#   are not coupled to backend dispatch.
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


# region __cp_strip_ansi

@test "__cp_strip_ansi handles the full ECMA-48 grammar (table-driven)" {
  # Arrange:
  # rows describe one escape grammar each.
  # Format: 'label|input-printf|expected-output'.
  # The label identifies the failing row when an assertion fails.
  local -ra cases=(
    'sgr-color|\033[31mred\033[0m|red'
    'osc-bel-hyperlink|\033]8;;https://example.com\007text\033]8;;\007|text'
    'osc-st-title|\033]0;title\033\\after|after'
    'csi-private-mode|before \033[?25hmid \033[?25lafter|before mid after'
    'csi-bracketed-paste|\033[?2004hhello \033[?2004lworld|hello world'
    'csi-intermediate|\033[ qcursor-shape|cursor-shape'
    'short-esc-reset|\033cclean|clean'
    'plain-text|nothing to strip|nothing to strip'
  )

  local row label input expected got
  for row in "${cases[@]}"; do
    label="${row%%|*}"
    local rest="${row#*|}"
    input="${rest%%|*}"
    expected="${rest#*|}"

    # Act
    got="$(printf "$input" | __cp_strip_ansi)"

    # Assert
    [ "$got" = "$expected" ] || {
      printf 'Row %s failed: got %q, expected %q\n' \
        "$label" "$got" "$expected" >&2
      false
    }
  done
}

@test "__cp_strip_ansi preserves embedded newlines and tabs" {
  # Arrange:
  # the stripper must touch ESC sequences only,
  # not whitespace classes that look superficially similar.
  local -r expected=$'a\nb\tc'

  # Act
  local got
  got="$(printf '\033[31ma\033[0m\n\033[32mb\033[0m\tc' \
    | __cp_strip_ansi)"

  # Assert
  [ "$got" = "$expected" ]
}

# endregion


# region __cp_trim_whitespace

@test "__cp_trim_whitespace removes leading and trailing whitespace runs" {
  # Arrange
  local -r expected='middle'

  # Act
  local got
  got="$(printf '  \t\nmiddle  \n' | __cp_trim_whitespace)"

  # Assert
  [ "$got" = "$expected" ]
}

@test "__cp_trim_whitespace preserves internal whitespace verbatim" {
  # Arrange:
  # only the surrounding whitespace should disappear;
  # interior spaces, tabs, and newlines stay intact.
  local -r expected=$'a b\tc\nd'

  # Act
  local got
  got="$(printf '  a b\tc\nd  ' | __cp_trim_whitespace)"

  # Assert
  [ "$got" = "$expected" ]
}

@test "__cp_trim_whitespace returns the empty string for whitespace-only input" {
  # Arrange / Act
  local got
  got="$(printf '   \t\n  ' | __cp_trim_whitespace)"

  # Assert
  [ -z "$got" ]
}

# endregion

### End of file
