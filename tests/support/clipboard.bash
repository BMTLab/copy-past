#!/usr/bin/env bash

# Read and fill the fake clipboard, and print bytes as hex for exact checks.

#######################################
# Print the fake clipboard as it is.
#
# Globals:
#   FAKE_CLIPBOARD_FILE: read.
#
# Outputs:
#   The clipboard, to stdout.
#######################################
function print_clipboard() {
  cat -- "${FAKE_CLIPBOARD_FILE}"
}

#######################################
# Fill the fake clipboard, for the tests of past.
#
# Arguments:
#   1: The text; no newline follows it.
#
# Globals:
#   FAKE_CLIPBOARD_FILE: read.
#######################################
function set_clipboard() {
  printf '%s' "$1" >"${FAKE_CLIPBOARD_FILE}"
}

#######################################
# Print stdin as one line of lowercase hex.
#
# A command substitution drops trailing newlines;
# hex keeps them, so a test can check every byte.
#
# Inputs:
#   The bytes, on stdin.
#
# Outputs:
#   The hex, to stdout, with no newline.
#######################################
function print_hex() {
  local hex

  hex="$(xxd -p)" || return

  printf '%s' "${hex//$'\n'/}"
}

#######################################
# Print the fake clipboard as one line of lowercase hex.
#
# Globals:
#   FAKE_CLIPBOARD_FILE: read.
#
# Outputs:
#   The hex, to stdout, with no newline.
#######################################
function print_clipboard_hex() {
  print_hex <"${FAKE_CLIPBOARD_FILE}"
}

### End
