#!/bin/bash

# Name: tests/support/debug_log.bash
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   Assertions over the structured `--debug` log emitted by
#   copy.sh and past.sh.
#
#   Each line follows the contract:
#     [copy debug] event=<name> key=value key='quoted value'
#   (or [past debug] for past).
#
#   Tests use these helpers instead of inline `grep` so the matchers
#   stay future-proof: extra fields can be added to a log line
#   without breaking older assertions, as long as the helpers only
#   require the expected substrings to be present.
#
#   Loaded by tests/support/test_helper.bash.

#######################################
# Assert that a captured stderr blob contains a debug log line
# matching the given event name and (optionally) all the supplied
# key=value substrings.
#
# Globals consumed:
#   $stderr: the buffer captured by `run --separate-stderr`.
#
# Arguments:
#   1:    expected event name (e.g. 'auto-detect').
#   2..N: optional key=value substrings that must appear on the line.
#
# Usage:
#   run --separate-stderr ...
#   __cp_assert_debug_event 'auto-detect' 'mime=application/json'
#######################################
__cp_assert_debug_event() {
  local -r event="$1"
  shift

  local line
  # Find the first '[copy debug] event=<event>' or '[past debug] event=<event>'
  # line in the captured stderr.
  line="$(grep -E "^\[(copy|past) debug\] event=${event}( |$)" \
    <<< "$stderr" | head -n1)"
  if [[ -z $line ]]; then
    printf 'Expected debug event %q not found.\n' "$event" >&2
    printf 'Captured stderr:\n%s\n' "$stderr" >&2
    return 1
  fi

  local kv
  for kv in "$@"; do
    if [[ "$line" != *"$kv"* ]]; then
      printf 'Event %q is missing %q.\n' "$event" "$kv" >&2
      printf 'Matched line: %s\n' "$line" >&2
      return 1
    fi
  done
}

#######################################
# Assert that a captured stderr blob does NOT contain any debug log
# line matching the given event name.
#
# Globals consumed:
#   $stderr: the buffer captured by `run --separate-stderr`.
#
# Arguments:
#   1: event name that must NOT appear.
#######################################
__cp_refute_debug_event() {
  local -r event="$1"

  if grep -qE "^\[(copy|past) debug\] event=${event}( |$)" \
    <<< "$stderr"; then
    printf 'Unexpected debug event %q found.\n' "$event" >&2
    printf 'Captured stderr:\n%s\n' "$stderr" >&2
    return 1
  fi
}

### End of file
