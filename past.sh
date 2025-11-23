#!/bin/bash

# Name: past.sh
# Author: Nikita Neverov (BMTLab)
# Version: 1.0.0
# Date: 2025-11-19
# License: MIT
#
# Description:
#   Prints the content of the system clipboard (CLIPBOARD) to stdout.
#   Useful for piping clipboard content into other commands or scripts.
#   Integrates with KDE/Klipper and other managers automatically.
#
#   Behavior:
#     - Prints content "as is" without appending an extra newline
#       (unless the clipboard content itself has one).
#
# Usage:
#   # As a standalone script:
#   past.sh > file.txt
#
#   # Sourced:
#   source /path/to/past.sh
#   my_var="$(past)"
#
# Exit Codes:
#   0: Success.
#   1: PAST_ERR_GENERAL
#      Generic error.
#   3: PAST_ERR_NO_BACKEND
#      No suitable clipboard utility found.
#   4: PAST_ERR_BACKEND_FAILED
#      The clipboard utility returned a non-zero exit code.
#
# Disclaimer:
#   This script is provided "as is", without any warranty.
#   Ensure required dependencies (wl-clipboard, xclip, or xsel)
#   are installed on your system.

# Error codes (readonly; safe for repeated sourcing)
# bashsupport disable=BP5001
if [[ -z ${PAST_ERR_GENERAL+x} ]]; then
  readonly PAST_ERR_GENERAL=1
fi
if [[ -z ${PAST_ERR_NO_BACKEND+x} ]]; then
  readonly PAST_ERR_NO_BACKEND=3
fi
if [[ -z ${PAST_ERR_BACKEND_FAILED+x} ]]; then
  readonly PAST_ERR_BACKEND_FAILED=4
fi

#######################################
# Print usage information.
#
# Outputs:
#   Usage text to stdout.
#######################################
function __ps_usage() {
  cat << 'EOF'
past - print system clipboard to stdout

Description:
  Detects the display server and outputs the clipboard content
  using wl-paste, xclip, or xsel.

Usage:
  past > output.txt
  echo "Clipboard contains: $(past)"
  past | cat
  past --help

Options:
  -h, --help    Show this help message.
EOF
}

#######################################
# Print error message and return with code.
#
# Arguments:
#   1: Message text.
#   2: Return code (optional, default: PAST_ERR_GENERAL).
#
# Outputs:
#   Error message to stderr.
#######################################
function __ps_error() {
  local -r message="$1"
  local -ir code="${2:-$PAST_ERR_GENERAL}"

  printf 'ERROR: %s\n' "$message" >&2

  return "$code"
}

#######################################
# Check if a command exists.
#
# Arguments:
#   1: Command name.
#
# Returns:
#   0: If exists.
#   1: Otherwise.
#######################################
function __ps_have_cmd() {
  command -v "$1" > /dev/null 2>&1
}

#######################################
# Detect the best available clipboard "read" backend.
# Prefers Wayland wl-paste when Wayland is detected,
# otherwise X11 tools.
#
# Arguments:
#   1: Name of the array variable (nameref) to store the command.
#
# Returns:
#   0: On success.
#   Non-zero: If no backend is found.
#######################################
function __ps_detect_backend() {
  local -n _backend_command="$1"

  # Wayland detection
  if { [[ -n ${WAYLAND_DISPLAY-} ]] \
    || [[ ${XDG_SESSION_TYPE-} == 'wayland' ]]; } \
    && __ps_have_cmd wl-paste; then
    # --no-newline ensures exact fidelity to clipboard content
    _backend_command=(wl-paste --no-newline)
    return 0
  fi

  # X11 detection
  if __ps_have_cmd xclip; then
    _backend_command=(xclip -selection clipboard -out)
    return 0
  fi

  if __ps_have_cmd xsel; then
    _backend_command=(xsel --clipboard --output)
    return 0
  fi

  return "$PAST_ERR_NO_BACKEND"
}

#######################################
# Main function to read from clipboard.
#
# Returns:
#   0: On success.
#   Non-zero: On error.
#######################################
function past() {
  # Localize IFS to prevent global pollution
  local IFS=$'\n\t'

  if [[ ${1-} == '-h' || ${1-} == '--help' ]]; then
    __ps_usage
    return 0
  fi

  local -a clipboard_backend_cmd
  if ! __ps_detect_backend clipboard_backend_cmd; then
    local error_msg='No clipboard backend found. '
    error_msg+='Install wl-clipboard, xclip, or xsel.'

    __ps_error "$error_msg" \
      "$PAST_ERR_NO_BACKEND" \
      || return "$?"
  fi

  if ! "${clipboard_backend_cmd[@]}"; then
    __ps_error 'Clipboard backend failed to read.' \
      "$PAST_ERR_BACKEND_FAILED" \
      || return "$?"
  fi
}

# Execution Guard:
# If the script is executed directly (not sourced), run the main function.
# If sourced, do nothing (just load the function).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  past "$@"
  exit_code=$?
  exit "$exit_code"
fi
### End
