#!/bin/bash

# Name: past.sh
# Author: Nikita Neverov (BMTLab)
# Version: 1.2.0 # x-release-please-version
# Date: 2026-05-17
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
#     - On Wayland uses `wl-paste` and strips
#       the single trailing newline that wl-paste appends,
#       while preserving any original trailing newlines.
#       This is a workaround for wl-clipboard ≤ 2.2.1,
#       where `--no-newline` truncates the last line
#       if the clipboard content is not LF-terminated.
#
#   Backend override:
#     - Set COPY_PAST_BACKEND={wl-clipboard|xclip|xsel}
#       to force a specific backend.
#       The same variable is honoured by copy.sh,
#       so both halves of a round-trip stay consistent.
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
#   2: PAST_ERR_USAGE
#      Invalid usage or unknown backend override.
#   3: PAST_ERR_NO_BACKEND
#      No suitable clipboard utility found.
#   4: PAST_ERR_BACKEND_FAILED
#      The clipboard utility returned a non-zero exit code.
#
# Disclaimer:
#   This script is provided "as is", without any warranty.
#   Ensure required dependencies (wl-clipboard, xclip, or xsel)
#   are installed on your system.

# region Error codes
#
# These constants are guarded against re-declaration,
# so the script can be sourced repeatedly in the same shell
# without tripping `readonly`.
# bashsupport disable=BP5001

if [[ -z ${PAST_ERR_GENERAL+x} ]]; then
  readonly PAST_ERR_GENERAL=1
fi

if [[ -z ${PAST_ERR_USAGE+x} ]]; then
  readonly PAST_ERR_USAGE=2
fi

if [[ -z ${PAST_ERR_NO_BACKEND+x} ]]; then
  readonly PAST_ERR_NO_BACKEND=3
fi

if [[ -z ${PAST_ERR_BACKEND_FAILED+x} ]]; then
  readonly PAST_ERR_BACKEND_FAILED=4
fi

# endregion

# region Internal helpers

#######################################
# Print usage information.
#
# Outputs:
#   Usage text to stdout.
#######################################
function __ps_usage() {
  cat <<'EOF'
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

Environment:
  COPY_PAST_BACKEND   Force a specific backend
                      (wl-clipboard | xclip | xsel).
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
  command -v "$1" >/dev/null 2>&1
}

# endregion

# region Backend detection

#######################################
# Detect the best available clipboard "read" backend.
#
# When COPY_PAST_BACKEND is set, that backend is used
# (and its absence is a hard error).
# Otherwise we prefer Wayland's wl-paste when a Wayland session is detected,
# then fall back to xclip, and finally to xsel.
#
# Arguments:
#   1: Name of the array variable (nameref) to store the command.
#
# Returns:
#   0: On success.
#   PAST_ERR_NO_BACKEND: If no backend is available.
#   PAST_ERR_USAGE: If COPY_PAST_BACKEND has an unknown value.
#######################################
function __ps_detect_backend() {
  # Bash nameref: writes inside the function reach the caller's
  # variable named in $1.
  local -n _backend_command="$1"

  # Step 1: honour an explicit override from the environment.
  #
  # We deliberately omit --no-newline here, because wl-paste 2.2.1
  # has a known bug: it drops the last line when the clipboard
  # content does not end with \n. Instead, we always run wl-paste
  # in its default mode (which appends one \n) and cancel that
  # trailing byte ourselves in __ps_read_wl_paste below.
  case "${COPY_PAST_BACKEND-}" in
    '') ;; # No override; fall through to auto-detection below.

    wl-clipboard | wayland | wl-paste)
      if __ps_have_cmd wl-paste; then
        _backend_command=(wl-paste)
        return 0
      fi
      return "$PAST_ERR_NO_BACKEND"
      ;;

    xclip)
      if __ps_have_cmd xclip; then
        _backend_command=(xclip -selection clipboard -out)
        return 0
      fi
      return "$PAST_ERR_NO_BACKEND"
      ;;

    xsel)
      if __ps_have_cmd xsel; then
        _backend_command=(xsel --clipboard --output)
        return 0
      fi
      return "$PAST_ERR_NO_BACKEND"
      ;;

    *)
      __ps_error \
        "Unknown COPY_PAST_BACKEND value: '${COPY_PAST_BACKEND}' (use wl-clipboard, xclip, or xsel)" \
        "$PAST_ERR_USAGE" \
        || return "$?"
      ;;
  esac

  # Step 2: auto-detection.
  if { [[ -n ${WAYLAND_DISPLAY-} ]] \
    || [[ ${XDG_SESSION_TYPE-} == 'wayland' ]]; } \
    && __ps_have_cmd wl-paste; then
    _backend_command=(wl-paste)
    return 0
  fi

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

# endregion

# region wl-paste reader

#######################################
# Read clipboard via wl-paste,
# then strip the trailing newline that wl-paste appends.
# Preserves any newlines that were genuinely part of the clipboard content.
#
# Implementation note:
#   Command substitution $(…) strips trailing newlines,
#   so we use a sentinel character ('x')
#   and capture the exit code of wl-paste itself
#   (NOT the trailing printf, which would mask failures).
#
# Arguments:
#   1..N: backend command and its arguments (typically 'wl-paste').
#
# Returns:
#   0: On success; clipboard content written to stdout.
#   PAST_ERR_BACKEND_FAILED: If wl-paste returns non-zero.
#######################################
function __ps_read_wl_paste() {
  local raw exit_code

  # Capture trick:
  #   The earlier implementation appended a constant 'x' marker.
  #   That hid wl-paste's exit code, because the LAST command in the
  #   subshell (the printf) always returned 0, and `$(…) || …` only
  #   sees that final status.
  #
  #   We now encode wl-paste's exit code into the marker itself
  #   (e.g. "x0" on success, "x1" on failure). This way the marker
  #   acts both as the trailing-newline guard for $(…) AND as a
  #   side-channel for the real backend status.
  raw="$(
    "$@"
    printf 'x%d' "$?"
  )"

  # Recover wl-paste's exit code:
  # everything after the LAST 'x' in the captured output is the rc,
  # and everything before that 'x' is the real clipboard payload.
  exit_code="${raw##*x}"
  raw="${raw%x*}"

  if [[ -z $exit_code || $exit_code -ne 0 ]]; then
    return "$PAST_ERR_BACKEND_FAILED"
  fi

  # wl-paste (without --no-newline) ALWAYS appends one \n to the
  # output. Strip that one byte; any newlines that were genuinely
  # part of the clipboard content remain untouched.
  raw="${raw%$'\n'}"
  printf '%s' "$raw"
}

# endregion

# region Public API

#######################################
# Main function to read from clipboard.
#
# Arguments:
#   [-h | --help]
#
# Returns:
#   0: On success.
#   Non-zero: On error (see header for code list).
#######################################
function past() {
  # region Argument parsing
  #
  # past has no options other than --help, so we only need a small
  # guard: anything other than -h/--help (or no args at all) goes
  # straight to the read path; an unknown positional argument is a
  # usage error rather than being silently ignored.
  if [[ ${1-} == '-h' || ${1-} == '--help' ]]; then
    __ps_usage
    return 0
  fi

  if [[ -n ${1-} ]]; then
    __ps_error "Unknown argument: $1" "$PAST_ERR_USAGE" \
      || return "$?"
  fi
  # endregion

  # region Backend resolution
  #
  # `cmd || rc=$?` keeps $? readable; `if ! cmd` would clobber it.
  local -a clipboard_backend_cmd
  local -i _detect_rc=0
  __ps_detect_backend clipboard_backend_cmd || _detect_rc=$?

  if [[ $_detect_rc -ne 0 ]]; then
    if [[ $_detect_rc -eq $PAST_ERR_USAGE ]]; then
      # __ps_detect_backend already printed the error.
      return "$_detect_rc"
    fi

    local error_msg='No clipboard backend found. '
    error_msg+='Install wl-clipboard, xclip, or xsel.'

    __ps_error "$error_msg" \
      "$PAST_ERR_NO_BACKEND" \
      || return "$?"
  fi
  # endregion

  # region Read clipboard
  #
  # wl-paste needs the trailing-newline workaround,
  # so it goes through __ps_read_wl_paste.
  # xclip and xsel emit clipboard bytes verbatim,
  # so we just exec them directly.
  if [[ ${clipboard_backend_cmd[0]} == 'wl-paste' ]]; then
    if ! __ps_read_wl_paste "${clipboard_backend_cmd[@]}"; then
      __ps_error 'Clipboard backend failed to read.' \
        "$PAST_ERR_BACKEND_FAILED" \
        || return "$?"
    fi
    return 0
  fi

  if ! "${clipboard_backend_cmd[@]}"; then
    __ps_error 'Clipboard backend failed to read.' \
      "$PAST_ERR_BACKEND_FAILED" \
      || return "$?"
  fi
  # endregion
}

# endregion

# region Execution guard
#
# When the file is executed directly (e.g. via /usr/local/bin/past),
# BASH_SOURCE[0] equals $0 and we run the function.
# When sourced (e.g. from ~/.bashrc), only the function definitions
# become available in the shell, and nothing else happens.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  past "$@"
  exit "$?"
fi
# endregion

### End of file
