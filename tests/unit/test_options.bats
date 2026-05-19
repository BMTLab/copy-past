#!/usr/bin/env bats

# Name: tests/unit/test_options.bats
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   Unit tests for option-handling helpers in copy.sh and past.sh:
#     - __cp_init_options / __ps_init_options
#     - __cp_parse_args   / __ps_parse_args
#     - __cp_parse_type_flag  / __ps_parse_type_flag
#     - __cp_parse_image_flag / __ps_parse_image_flag
#     - __cp_validate_options
#
#   These functions are pure
#   (no clipboard touch, no pipeline composition),
#   so they can be tested in isolation by passing namerefs in
#   and inspecting their effect on the caller's state.
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


# region Defaults

@test "__cp_init_options resets every flag to its default value" {
  # Arrange:
  # pre-poison every slot
  # so the test fails if init_options forgets a slot.
  local -i raw=9 trim=9 append=9 auto=9 debug=9
  local mime='dirty'

  # Act
  __cp_init_options raw trim append auto debug mime

  # Assert
  [ "$raw" -eq 0 ]
  [ "$trim" -eq 0 ]
  [ "$append" -eq 0 ]
  [ "$auto" -eq 1 ]
  [ "$debug" -eq 0 ]
  [ "$mime" = '' ]
}

@test "__ps_init_options resets every slot" {
  # Arrange
  local mime='dirty'
  local -i is_binary=9 debug=9

  # Act
  __ps_init_options mime is_binary debug

  # Assert
  [ "$mime" = '' ]
  [ "$is_binary" -eq 0 ]
  [ "$debug" -eq 0 ]
}

# endregion


# region __cp_parse_type_flag / __ps_parse_type_flag

@test "__cp_parse_type_flag accepts both --type=MIME and --type MIME" {
  # Arrange
  local mime=''
  local -i consumed=0

  # Act (equals form)
  __cp_parse_type_flag mime consumed '--type=text/html'

  # Assert
  [ "$mime" = 'text/html' ]
  [ "$consumed" -eq 1 ]

  # Act (two-arg form)
  __cp_parse_type_flag mime consumed '--type' 'application/xml'

  # Assert
  [ "$mime" = 'application/xml' ]
  [ "$consumed" -eq 2 ]
}

@test "__cp_parse_type_flag rejects empty MIME values" {
  # Arrange
  local mime=''
  local -i consumed=0
  local -i rc=0

  # Act (no value at all)
  __cp_parse_type_flag mime consumed '--type' 2>/dev/null || rc=$?
  [ "$rc" -eq "$COPY_ERR_USAGE" ]

  # Act (=empty form)
  rc=0
  __cp_parse_type_flag mime consumed '--type=' 2>/dev/null || rc=$?
  [ "$rc" -eq "$COPY_ERR_USAGE" ]
}

@test "__ps_parse_type_flag mirrors __cp_parse_type_flag" {
  # Arrange
  local mime=''
  local -i consumed=0
  local -i rc=0

  # Act / Assert (success)
  __ps_parse_type_flag mime consumed '--type=text/markdown'
  [ "$mime" = 'text/markdown' ]
  [ "$consumed" -eq 1 ]

  # Act / Assert (error)
  __ps_parse_type_flag mime consumed '--type=' 2>/dev/null || rc=$?
  [ "$rc" -eq "$PAST_ERR_USAGE" ]
}

# endregion


# region __cp_parse_image_flag / __ps_parse_image_flag

@test "__cp_parse_image_flag bare --image yields image/png and raw=1" {
  # Arrange
  local mime=''
  local -i raw=0 consumed=0

  # Act
  __cp_parse_image_flag mime raw consumed '--image'

  # Assert
  [ "$mime" = 'image/png' ]
  [ "$raw" -eq 1 ]
  [ "$consumed" -eq 1 ]
}

@test "__cp_parse_image_flag --image=FORMAT delegates to format-to-mime" {
  # Arrange
  local mime=''
  local -i raw=0 consumed=0

  # Act
  __cp_parse_image_flag mime raw consumed '--image=svg'

  # Assert
  [ "$mime" = 'image/svg+xml' ]
  [ "$raw" -eq 1 ]
}

@test "__cp_parse_image_flag rejects --image= (empty format)" {
  # Arrange
  local mime=''
  local -i raw=0 consumed=0 rc=0

  # Act
  __cp_parse_image_flag mime raw consumed '--image=' 2>/dev/null \
    || rc=$?

  # Assert
  [ "$rc" -eq "$COPY_ERR_USAGE" ]
  [ "$raw" -eq 0 ]
}

@test "__ps_parse_image_flag bare --image yields image/png" {
  # Arrange
  local mime=''
  local -i consumed=0

  # Act
  __ps_parse_image_flag mime consumed '--image'

  # Assert
  [ "$mime" = 'image/png' ]
}

# endregion


# region __cp_parse_args

@test "__cp_parse_args populates every slot from a full argv" {
  # Arrange
  local -i raw=0 trim=0 append=0 auto=1 debug=0
  local mime=''
  local -a rest=()

  # Act
  __cp_parse_args raw trim append auto debug mime rest \
    --raw --trim -a --debug --type=text/markdown -- leftover args

  # Assert
  [ "$raw" -eq 1 ]
  [ "$trim" -eq 1 ]
  [ "$append" -eq 1 ]
  [ "$debug" -eq 1 ]
  [ "$mime" = 'text/markdown' ]
  [ "${rest[0]}" = 'leftover' ]
  [ "${rest[1]}" = 'args' ]
}

@test "__cp_parse_args treats -j/--json as MIME pin + raw" {
  # Arrange
  local -i raw=0 trim=0 append=0 auto=1 debug=0
  local mime=''
  local -a rest=()

  # Act
  __cp_parse_args raw trim append auto debug mime rest --json

  # Assert
  [ "$mime" = 'application/json' ]
  [ "$raw" -eq 1 ]
  # auto is NOT flipped here; the validate phase is what flips it
  # in response to an explicit MIME pin.
  [ "$auto" -eq 1 ]
}

@test "__cp_parse_args -- terminates parsing and forwards literal flags" {
  # Arrange
  local -i raw=0 trim=0 append=0 auto=1 debug=0
  local mime=''
  local -a rest=()

  # Act
  __cp_parse_args raw trim append auto debug mime rest \
    -- --not-a-flag

  # Assert
  [ "${rest[0]}" = '--not-a-flag' ]
}

@test "__cp_parse_args rejects unknown options with COPY_ERR_USAGE" {
  # Arrange
  local -i raw=0 trim=0 append=0 auto=1 debug=0
  local mime=''
  local -a rest=()
  local -i rc=0

  # Act
  __cp_parse_args raw trim append auto debug mime rest --bogus \
    2>/dev/null || rc=$?

  # Assert
  [ "$rc" -eq "$COPY_ERR_USAGE" ]
}

@test "__cp_parse_args reports help via the rc=200 sentinel" {
  # Arrange
  local -i raw=0 trim=0 append=0 auto=1 debug=0
  local mime=''
  local -a rest=()
  local -i rc=0

  # Act
  __cp_parse_args raw trim append auto debug mime rest --help \
    >/dev/null || rc=$?

  # Assert
  [ "$rc" -eq 200 ]
}

@test "__cp_parse_args accepts -d, --debug, and --verbose synonyms" {
  # Arrange / Act / Assert: each form must flip debug to 1.
  local -i raw=0 trim=0 append=0 auto=1 debug=0
  local mime=''
  local -a rest=()

  __cp_parse_args raw trim append auto debug mime rest -d
  [ "$debug" -eq 1 ]

  debug=0
  __cp_parse_args raw trim append auto debug mime rest --debug
  [ "$debug" -eq 1 ]

  debug=0
  __cp_parse_args raw trim append auto debug mime rest --verbose
  [ "$debug" -eq 1 ]
}

# endregion


# region __ps_parse_args

@test "__ps_parse_args populates mime_type from --json and accepts --debug" {
  # Arrange
  local mime=''
  local -i debug=0

  # Act
  __ps_parse_args mime debug --json --debug

  # Assert
  [ "$mime" = 'application/json' ]
  [ "$debug" -eq 1 ]
}

@test "__ps_parse_args reports help via rc=200" {
  # Arrange
  local mime=''
  local -i debug=0 rc=0

  # Act
  __ps_parse_args mime debug --help >/dev/null || rc=$?

  # Assert
  [ "$rc" -eq 200 ]
}

@test "__ps_parse_args rejects stray positional with PAST_ERR_USAGE" {
  # Arrange
  local mime=''
  local -i debug=0 rc=0

  # Act
  __ps_parse_args mime debug stray-arg 2>/dev/null || rc=$?

  # Assert
  [ "$rc" -eq "$PAST_ERR_USAGE" ]
}

@test "__ps_parse_args accepts -d, --debug, and --verbose synonyms" {
  # Arrange
  local mime=''
  local -i debug=0

  # Act / Assert
  __ps_parse_args mime debug -d
  [ "$debug" -eq 1 ]

  debug=0
  __ps_parse_args mime debug --debug
  [ "$debug" -eq 1 ]

  debug=0
  __ps_parse_args mime debug --verbose
  [ "$debug" -eq 1 ]
}

# endregion


# region __cp_validate_options

@test "__cp_validate_options rejects --append + binary MIME (rc=5)" {
  # Arrange
  local -i auto=1 rc=0

  # Act
  __cp_validate_options auto 1 0 'image/png' 2>/dev/null || rc=$?

  # Assert
  [ "$rc" -eq "$COPY_ERR_TYPE_MISMATCH" ]
}

@test "__cp_validate_options rejects --trim + binary MIME (rc=5)" {
  # Arrange
  local -i auto=1 rc=0

  # Act
  __cp_validate_options auto 0 1 'application/octet-stream' \
    2>/dev/null || rc=$?

  # Assert
  [ "$rc" -eq "$COPY_ERR_TYPE_MISMATCH" ]
}

@test "__cp_validate_options disables auto when an explicit MIME is set" {
  # Arrange
  local -i auto=1

  # Act
  __cp_validate_options auto 0 0 'application/json'

  # Assert
  [ "$auto" -eq 0 ]
}

@test "__cp_validate_options disables auto under --append (text-only)" {
  # Arrange
  local -i auto=1

  # Act
  __cp_validate_options auto 1 0 ''

  # Assert
  [ "$auto" -eq 0 ]
}

@test "__cp_validate_options keeps auto on for plain text input" {
  # Arrange
  local -i auto=1

  # Act
  __cp_validate_options auto 0 0 ''

  # Assert
  [ "$auto" -eq 1 ]
}

# endregion

### End of file
