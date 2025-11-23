#!/bin/bash

# Name: copy.sh
# Author: Nikita Neverov (BMTLab)
# Version: 1.0.0
# Date: 2025-11-19
# License: MIT
#
# Description:
#   Writes text to the system clipboard (CLIPBOARD)
#   regardless of the display server (Wayland or X11).
#   It automatically selects the best available backend:
#     - Wayland: wl-copy (wl-clipboard)
#     - X11:     xclip or xsel
#
#   Behavior:
#     - With arguments:
#         copy word1 word2
#         -> Joins arguments with spaces and copies "word1 word2".
#     - With stdin (Pipe):
#         echo 'hello' | copy
#         -> Streams input directly to clipboard.
#     - Priority:
#         If stdin is piped,
#         it takes precedence over arguments (streaming mode).
#         No trailing newline is appended by the script itself.
#
# Usage:
#   # As a standalone script (must be in $PATH):
#   echo 'hello' | copy.sh
#
#   # Sourced in .bashrc:
#   source /path/to/copy.sh
#   copy 'text'
#
# Exit Codes:
#   0: Success.
#   1: COPY_ERR_GENERAL
#      Generic error.
#   2: COPY_ERR_USAGE
#      Invalid usage or missing arguments.
#   3: COPY_ERR_NO_BACKEND
#      No suitable clipboard utility found (wl-copy, xclip, xsel).
#   4: COPY_ERR_BACKEND_FAILED
#      The clipboard utility returned a non-zero exit code.
#
# Disclaimer:
#   This script is provided "as is", without any warranty.
#   Ensure required dependencies (wl-clipboard, xclip, or xsel)
#   are installed on your system.

# Error codes (readonly; safe for repeated sourcing)
# bashsupport disable=BP5001
if [[ -z ${COPY_ERR_GENERAL+x} ]]; then
  readonly COPY_ERR_GENERAL=1
fi
if [[ -z ${COPY_ERR_USAGE+x} ]]; then
  readonly COPY_ERR_USAGE=2
fi
if [[ -z ${COPY_ERR_NO_BACKEND+x} ]]; then
  readonly COPY_ERR_NO_BACKEND=3
fi
if [[ -z ${COPY_ERR_BACKEND_FAILED+x} ]]; then
  readonly COPY_ERR_BACKEND_FAILED=4
fi

#######################################
# Print usage information.
#
# Outputs:
#   Usage text to stdout.
#######################################
function __cp_usage() {
  cat << 'EOF'
copy - write text to system clipboard

Description:
  Detects the display server (Wayland/X11) and uses the appropriate tool
  (wl-copy, xclip, or xsel) to copy data to the clipboard.

Usage:
  copy [text...]
  echo 'text' | copy
  copy --help

Options:
  -h, --help    Show this help message.

Examples:
  copy 'Hello World'    # Copies: Hello World
  pwd | copy            # Copies current path
EOF
}

#######################################
# Print error message and return with code.
#
# Arguments:
#   1: Message text.
#   2: Return code (optional, default: COPY_ERR_GENERAL).
#
# Outputs:
#   Error message to stderr.
#######################################
function __cp_error() {
  local -r message="$1"
  local -ir code="${2:-$COPY_ERR_GENERAL}"

  printf 'ERROR: %s\n' "$message" >&2

  return "$code"
}

#######################################
# Check if a command exists in the system.
#
# Arguments:
#   1: Command name.
#
# Returns:
#   0: If exists
#   1: Otherwise.
#######################################
function __cp_have_cmd() {
  command -v "$1" > /dev/null 2>&1
}

#######################################
# Detect the best available clipboard backend command.
# Prefers Wayland wl-copy when Wayland is detected,
# otherwise X11 tools.
#
# Arguments:
#   1: Name of the array variable (nameref) to store the command.
#
# Returns:
#   0: On success (backend found).
#   Non-zero: If no backend is found.
#######################################
function __cp_detect_backend() {
  local -n _backend_command="$1"

  # Wayland detection: prefer wl-copy
  if { [[ -n ${WAYLAND_DISPLAY-} ]] \
    || [[ ${XDG_SESSION_TYPE-} == 'wayland' ]]; } \
    && __cp_have_cmd wl-copy; then
    _backend_command=(wl-copy)
    return 0
  fi

  # X11 detection
  if __cp_have_cmd xclip; then
    _backend_command=(xclip -selection clipboard -in)
    return 0
  fi

  if __cp_have_cmd xsel; then
    _backend_command=(xsel --clipboard --input)
    return 0
  fi

  return "$COPY_ERR_NO_BACKEND"
}

#######################################
# Main function to write to clipboard.
#
# Arguments:
#   [text...] or read from stdin.
#
# Returns:
#   0: On success.
#   Non-zero: On error.
#######################################
function copy() {
  # Limit word splitting to newline/tab for safety in logic,
  # EXCEPT when we join arguments later.
  local IFS=$'\n\t'

  if [[ ${1-} == '-h' || ${1-} == '--help' ]]; then
    __cp_usage
    return 0
  fi

  # Detect backend using a local array passed by reference
  local -a clipboard_backend_cmd
  if ! __cp_detect_backend clipboard_backend_cmd; then
    local error_msg='No clipboard backend found. '
    error_msg+='Install wl-clipboard, xclip, or xsel.'

    __cp_error "$error_msg" \
      "$COPY_ERR_NO_BACKEND" \
      || return "$?"
  fi

  # 1. Pipe Mode: Stream stdin directly to backend
  if [[ ! -t 0 ]]; then
    if ! "${clipboard_backend_cmd[@]}"; then
      __cp_error 'Clipboard backend failed during pipe operation.' \
        "$COPY_ERR_BACKEND_FAILED" \
        || return "$?"
    fi
    return 0
  fi

  # 2. Argument Mode
  if [[ $# -eq 0 ]]; then
    local error_msg='No input provided. '
    error_msg+='Pass text as arguments or pipe via stdin.'

    __cp_usage >&2
    __cp_error "$error_msg" \
      "$COPY_ERR_USAGE" \
      || return "$?"
  fi

  # Join arguments with spaces (imitating echo behavior).
  # We run this in a subshell or simple assignment to safely change IFS
  # just for the expansion of "$*".
  local -r input_text="$(
    IFS=' '
    echo "$*"
  )"

  if ! printf '%s' "$input_text" | "${clipboard_backend_cmd[@]}"; then
    __cp_error 'Clipboard backend failed.' "$COPY_ERR_BACKEND_FAILED" \
      || return "$?"
  fi
}

# Execution Guard:
# If the script is executed directly (not sourced), run the main function.
# If sourced, do nothing (just load the function).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  copy "$@"
  exit_code=$?
  exit "$exit_code"
fi
### End
