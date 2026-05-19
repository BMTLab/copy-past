#!/bin/bash

# Name: tests/support/clipboard.bash
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   Inspection helpers that read or pre-load the fake clipboard.
#   Loaded by tests/support/test_helper.bash.

#######################################
# Read the raw clipboard contents recorded by the fake backend.
#######################################
__cp_clipboard_dump() {
  cat "$FAKE_CLIPBOARD_FILE"
}

#######################################
# Pre-load the clipboard with arbitrary bytes (used by past tests).
#
# Arguments:
#   1: payload string (printed verbatim, no trailing newline).
#######################################
__cp_clipboard_set() {
  printf '%s' "$1" > "$FAKE_CLIPBOARD_FILE"
}

#######################################
# Hex-dump a string with one continuous line (no spaces or breaks).
# Useful for asserting byte-fidelity round-trips
# without losing trailing newlines through command substitution.
#
# Arguments:
#   1: payload to dump (defaults to stdin if omitted).
#
# Outputs:
#   Lowercase hex string on stdout.
#######################################
__cp_hex() {
  if [[ $# -gt 0 ]]; then
    printf '%s' "$1" | xxd -p | tr -d '\n'
  else
    xxd -p | tr -d '\n'
  fi
}

#######################################
# Hex-dump the current fake clipboard file.
# Convenience wrapper over `xxd -p $FAKE_CLIPBOARD_FILE`.
#######################################
__cp_clipboard_hex() {
  xxd -p "$FAKE_CLIPBOARD_FILE" | tr -d '\n'
}

### End of file
