#!/usr/bin/env bats

# Tests how the ERR trap of copy.sh and past.sh ends a run that failed.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

#######################################
# Call a handler as the ERR trap would, from inside a helper.
#
# Arguments:
#   1: The handler: __cp_internal_error or __ps_internal_error.
#   2...: Its arguments: the status, the line and the command.
#######################################
function fail_inside_a_helper() {
  local -r handler="$1"
  shift

  "${handler}" "$@"
}

#######################################
# Check that a failure inside a helper names its line and command,
# and ends the run with the internal code.
#
# Arguments:
#   1: The handler: __cp_internal_error or __ps_internal_error.
#   2: The tool: copy or past.
#   3: The name of the internal code, such as COPY_ERR_INTERNAL.
#######################################
function helper_failure_reports_and_exits_internal() {
  # Arrange: status 9 at line 42, from the command false.
  local -r handler="$1"
  local -r tool="$2"
  local -ir internal_code="${!3}"

  # Act
  run --separate-stderr fail_inside_a_helper "${handler}" 9 42 'false'

  # Assert
  ((status == internal_code))
  [[ "${stderr}" == "${tool}: internal error at line 42 (status 9): false" ]]
}

#######################################
# Check that a status passes on as it is, without a message:
# the 141 of a closed pipe, or the internal code of a subshell
# that has already reported.
#
# Arguments:
#   1: The handler: __cp_internal_error or __ps_internal_error.
#   2: The status.
#######################################
function status_passes_on_silently() {
  # Arrange: the status is the input.
  local -r handler="$1"
  local -ir failed_status="$2"

  # Act
  run --separate-stderr fail_inside_a_helper "${handler}" "${failed_status}" 1 'cmd'

  # Assert
  ((status == failed_status))
  [[ -z "${stderr}" ]]
}

@test "__cp_internal_error passes on a code that copy returns" {
  # Arrange:
  # a stand-in for copy calls the handler, as the trap does
  # when a helper returns a code to copy; the helper has reported.
  function copy() {
    __cp_internal_error 4 7 'return 4'
  }

  # Act
  run --separate-stderr copy

  # Assert
  ((status == 4))
  [[ -z "${stderr}" ]]
}

@test "__ps_internal_error passes on a code that past returns" {
  # Arrange: a stand-in for past, as for copy above.
  function past() {
    __ps_internal_error 4 7 'return 4'
  }

  # Act
  run --separate-stderr past

  # Assert
  ((status == 4))
  [[ -z "${stderr}" ]]
}

for tool_sample in 'copy|__cp_internal_error|COPY_ERR_INTERNAL' \
  'past|__ps_internal_error|PAST_ERR_INTERNAL'; do
  tool_name="${tool_sample%%|*}"
  handler_rest="${tool_sample#*|}"
  handler_name="${handler_rest%%|*}"
  bats_test_function \
    --description "${handler_name} reports a failure in a helper and exits 70" \
    -- helper_failure_reports_and_exits_internal "${handler_name}" "${tool_name}" \
    "${handler_rest#*|}"
  bats_test_function \
    --description "${handler_name} passes on the 141 of a closed pipe" \
    -- status_passes_on_silently "${handler_name}" 141
  bats_test_function \
    --description "${handler_name} passes on the 70 of a subshell that reported" \
    -- status_passes_on_silently "${handler_name}" 70
done

### End
