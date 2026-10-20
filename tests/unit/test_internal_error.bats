#!/usr/bin/env bats

# Tests how the ERR trap of copy.sh and past.sh ends a run that failed.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

#######################################
# Run a handler of the ERR trap in a new bash, from a script file,
# as a program runs it: at the top level, inside a helper,
# or inside the entry function, which bears the name of the tool.
#
# bats puts frames of its own into FUNCNAME, and bash -c gives none
# for the top level: only bash running a file has the frames of a program.
#
# Arguments:
#   1: The script that defines the handler: copy.sh or past.sh.
#   2: The handler: __cp_internal_error or __ps_internal_error.
#   3: Where the handler runs: top-level, helper or entry.
#   4...: Its arguments: the status, the line and the command.
#
# Globals:
#   COPY_PAST_ROOT: read.
#######################################
function run_internal_error() {
  local -r script_name="$1"
  local -r runner_path="${BATS_TEST_TMPDIR}/internal_error.sh"
  local prelude
  shift

  prelude="$(print_snippet_prelude "${script_name}")"
  printf '%s\n' "${prelude}" '
entry_name="$1"
handler="$2"
place="$3"
shift 3
function failing_helper() {
  "${handler}" "$@"
}
# Stand-ins for the entry functions, defined after the source.
function copy() {
  "${handler}" "$@"
}
function past() {
  "${handler}" "$@"
}
case "${place}" in
  helper) failing_helper "$@" ;;
  entry) "${entry_name}" "$@" ;;
  *) "${handler}" "$@" ;;
esac' >"${runner_path}"

  bash "${runner_path}" "${COPY_PAST_ROOT}" "${script_name%.sh}" "$@"
}

#######################################
# Check that a failure inside a function names its line and command,
# and ends the run with the internal code.
#
# Arguments:
#   1: The script: copy.sh or past.sh.
#   2: The handler.
#   3: The tool: copy or past.
#   4: The name of the internal code, such as COPY_ERR_INTERNAL.
#   5: Where the handler runs: helper or entry.
#######################################
function failure_reports_and_exits_internal() {
  local -r script_name="$1"
  local -r handler="$2"
  local -r tool="$3"
  local -ir internal_code="${!4}"
  local -r place="$5"

  # Arrange: status 9 at line 42, from the command false.

  # Act
  run --separate-stderr run_internal_error "${script_name}" "${handler}" \
    "${place}" 9 42 'false'

  # Assert
  ((status == internal_code))
  [[ "${stderr}" == "${tool}: internal error at line 42 (status 9): false" ]]
}

#######################################
# Check that a status passes on as it is, without a message:
# a code that the entry function returns to the top level,
# the 141 of a closed pipe, or the internal code
# of a subshell that has already reported.
#
# Arguments:
#   1: The script: copy.sh or past.sh.
#   2: The handler.
#   3: Where the handler runs: top-level or helper.
#   4: The status.
#######################################
function status_passes_on_silently() {
  local -r script_name="$1"
  local -r handler="$2"
  local -r place="$3"
  local -ir failed_status="$4"

  # Arrange: the status is the input.

  # Act
  run --separate-stderr run_internal_error "${script_name}" "${handler}" \
    "${place}" "${failed_status}" 1 'cmd'

  # Assert
  ((status == failed_status))
  [[ -z "${stderr}" ]]
}

for handler_sample in 'copy.sh|__cp_internal_error|copy|COPY_ERR_INTERNAL' \
  'past.sh|__ps_internal_error|past|PAST_ERR_INTERNAL'; do
  IFS='|' read -r script_name handler_name tool_name code_name <<<"${handler_sample}"
  bats_test_function \
    --description "${handler_name} reports a failure in a helper and exits 70" \
    -- failure_reports_and_exits_internal "${script_name}" \
    "${handler_name}" "${tool_name}" "${code_name}" helper
  # A check for the name of the entry function once let this one pass in silence.
  bats_test_function \
    --description "${handler_name} reports a failure in the body of ${tool_name} and exits 70" \
    -- failure_reports_and_exits_internal "${script_name}" \
    "${handler_name}" "${tool_name}" "${code_name}" entry
  bats_test_function \
    --description "${handler_name} passes on a code that ${tool_name} returns" \
    -- status_passes_on_silently "${script_name}" "${handler_name}" top-level 4
  bats_test_function \
    --description "${handler_name} passes on the 141 of a closed pipe" \
    -- status_passes_on_silently "${script_name}" "${handler_name}" helper 141
  bats_test_function \
    --description "${handler_name} passes on the 70 of a subshell that reported" \
    -- status_passes_on_silently "${script_name}" "${handler_name}" helper 70
done

### End
