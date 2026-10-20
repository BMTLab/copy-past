#!/usr/bin/env bash

# Check the events of the debug log that copy and past print with --debug.
#
# A line of the log reads: [copy debug] event=NAME key=value key='a value',
# or [past debug] for past. The checks only need the fields they name,
# so a new field on a line breaks no test.

#######################################
# Find the first line of the debug log with an event.
#
# Arguments:
#   1: The name of the variable that takes the line; empty when none.
#   2: The name of the event, such as auto-detect.
#   3: The log, as run --separate-stderr keeps it.
#######################################
function find_debug_event() {
  local -n _event_line_ref=$1
  local -r event="$2"
  local -r log="$3"
  local line

  _event_line_ref=''
  while IFS= read -r line; do
    if [[ "${line}" =~ ^\[(copy|past)\ debug\]\ event=([^ ]+) ]] \
      && [[ "${BASH_REMATCH[2]}" == "${event}" ]]; then
      _event_line_ref="${line}"

      return 0
    fi
  done <<<"${log}"
}

#######################################
# Check that the debug log holds an event with all the fields given.
#
# Arguments:
#   1: The name of the event, such as auto-detect.
#   2...: The fields the line must hold, such as mime=application/json.
#
# Globals:
#   stderr: read; run --separate-stderr sets it.
#
# Returns:
#   0 when the event and its fields are there, 1 otherwise.
#######################################
function assert_debug_event() {
  local -r event="$1"
  local event_line field
  shift

  find_debug_event event_line "${event}" "${stderr}"
  if [[ -z "${event_line}" ]]; then
    printf 'Expected debug event %q not found.\n' "${event}" >&2
    printf 'Captured stderr:\n%s\n' "${stderr}" >&2

    return 1
  fi

  for field in "$@"; do
    if [[ "${event_line}" != *"${field}"* ]]; then
      printf 'Event %q is missing %q.\n' "${event}" "${field}" >&2
      printf 'Matched line: %s\n' "${event_line}" >&2

      return 1
    fi
  done
}

#######################################
# Check that the debug log holds no line with an event.
#
# Arguments:
#   1: The name of the event.
#
# Globals:
#   stderr: read; run --separate-stderr sets it.
#
# Returns:
#   0 when the event is not there, 1 otherwise.
#######################################
function refute_debug_event() {
  local -r event="$1"
  local event_line

  find_debug_event event_line "${event}" "${stderr}"
  if [[ -n "${event_line}" ]]; then
    printf 'Unexpected debug event %q found.\n' "${event}" >&2
    printf 'Captured stderr:\n%s\n' "${stderr}" >&2

    return 1
  fi
}

### End
