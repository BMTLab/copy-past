#!/bin/bash

# Name: copy.sh
# Author: Nikita Neverov (BMTLab)
# Version: 1.2.0 # x-release-please-version
# Date: 2026-05-17
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
#         If stdin is piped, it takes precedence over arguments
#         (streaming mode).
#         No trailing newline is appended by the script itself.
#
#   ANSI handling:
#     - By default, ANSI/VT escape sequences
#       (CSI colors, OSC links, short ESC controls)
#       are stripped before writing to the clipboard,
#       so pasting in GUI applications produces clean text.
#     - Use --raw / -r to preserve escape sequences verbatim.
#
#   Backend override:
#     - Set COPY_PAST_BACKEND={wl-clipboard|xclip|xsel}
#       to force a specific backend, bypassing the auto-detection.
#       Useful when multiple backends are installed,
#       or when debugging X11 vs Wayland behaviour.
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
#      Invalid usage, unknown option, or unknown backend override.
#   3: COPY_ERR_NO_BACKEND
#      No suitable clipboard utility found (wl-copy, xclip, xsel).
#   4: COPY_ERR_BACKEND_FAILED
#      The clipboard utility (or the ANSI-stripping stage)
#      returned a non-zero exit code.
#
# Disclaimer:
#   This script is provided "as is", without any warranty.
#   Ensure required dependencies (wl-clipboard, xclip, or xsel)
#   are installed on your system.

# region Error codes
#
# These constants are guarded against re-declaration,
# so the script can be sourced repeatedly in the same shell
# (for example, when reloading .bashrc) without tripping `readonly`.
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

# endregion

# region Internal helpers

#######################################
# Print usage information.
#
# Outputs:
#   Usage text to stdout.
#######################################
function __cp_usage() {
  cat <<'EOF'
copy - write text to system clipboard

Description:
  Detects the display server (Wayland/X11) and uses the appropriate tool
  (wl-copy, xclip, or xsel) to copy data to the clipboard.

  By default, ANSI escape sequences (colors, bold, hyperlinks, etc.)
  are stripped so that pasted text works correctly in GUI applications.
  Use --raw (-r) to preserve escape sequences for terminal-to-terminal use.

Usage:
  copy [options] [text...]
  echo 'text' | copy
  copy --help

Options:
  -h, --help    Show this help message.
  -r, --raw     Preserve ANSI escape sequences (do not strip colors).
  --            End of options; remaining arguments are treated as text.

Environment:
  COPY_PAST_BACKEND   Force a specific backend
                      (wl-clipboard | xclip | xsel).

Examples:
  copy 'Hello World'    # Copies: Hello World
  pwd | copy            # Copies current path
  ls --color | copy -r  # Copies with color codes preserved
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
#   0: If exists.
#   1: Otherwise.
#######################################
function __cp_have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# endregion

# region Backend detection

#######################################
# Detect the best available clipboard backend command.
#
# When COPY_PAST_BACKEND is set, that backend is used
# (and its absence is a hard error).
# Otherwise we prefer Wayland's wl-copy when a Wayland session is detected,
# then fall back to xclip, and finally to xsel.
#
# Arguments:
#   1: Name of the array variable (nameref) to store the command.
#
# Returns:
#   0: On success (backend found).
#   COPY_ERR_NO_BACKEND: If no backend is available.
#   COPY_ERR_USAGE: If COPY_PAST_BACKEND has an unknown value.
#######################################
function __cp_detect_backend() {
  # Bash nameref: writes inside the function reach the caller's
  # variable named in $1. Lets us return an array without resorting
  # to global state or stdout-based serialisation.
  local -n _backend_command="$1"

  # Step 1: honour an explicit override from the environment.
  # An unknown value is treated as a usage error (rc=2),
  # not as "no backend found" (rc=3),
  # because the user clearly expressed a preference.
  case "${COPY_PAST_BACKEND-}" in
    '') ;; # No override; fall through to auto-detection below.

    wl-clipboard | wayland | wl-copy)
      if __cp_have_cmd wl-copy; then
        _backend_command=(wl-copy)
        return 0
      fi
      return "$COPY_ERR_NO_BACKEND"
      ;;

    xclip)
      if __cp_have_cmd xclip; then
        _backend_command=(xclip -selection clipboard -in)
        return 0
      fi
      return "$COPY_ERR_NO_BACKEND"
      ;;

    xsel)
      if __cp_have_cmd xsel; then
        _backend_command=(xsel --clipboard --input)
        return 0
      fi
      return "$COPY_ERR_NO_BACKEND"
      ;;

    *)
      __cp_error \
        "Unknown COPY_PAST_BACKEND value: '${COPY_PAST_BACKEND}' (use wl-clipboard, xclip, or xsel)" \
        "$COPY_ERR_USAGE" \
        || return "$?"
      ;;
  esac

  # Step 2: auto-detection.
  # Wayland is checked first because a Wayland session
  # may also have xclip available via XWayland,
  # but the native wl-clipboard avoids round-tripping through Xwayland.
  if { [[ -n ${WAYLAND_DISPLAY-} ]] \
    || [[ ${XDG_SESSION_TYPE-} == 'wayland' ]]; } \
    && __cp_have_cmd wl-copy; then
    _backend_command=(wl-copy)
    return 0
  fi

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

# endregion

# region ANSI stripping

#######################################
# Strip ANSI/VT escape sequences from stdin.
#
# Implements the ECMA-48 grammar so that all standard escape forms
# are recognised, not just basic SGR colors:
#
#   - OSC sequences:
#       ESC ] <any chars except ESC/BEL> (BEL | ESC \)
#       Covers e.g. window titles (ESC]0;…) and OSC 8 hyperlinks.
#   - CSI sequences:
#       ESC [ <params 0x30-0x3F> <intermediates 0x20-0x2F> <final 0x40-0x7E>
#       The parameter range includes private markers (?, <, =, >),
#       so cursor-mode toggles like ESC[?25h are stripped too.
#   - Short escapes:
#       ESC <single byte not [ or ]>
#       e.g. ESC c (full reset), ESC 7 (save cursor).
#
#   The patterns are applied in order, longer forms first,
#   so the short-escape catch-all does not consume
#   the leading ESC of a CSI/OSC sequence.
#
#   Uses bash $'…' to inject the literal escape character;
#   this keeps the substitution portable
#   between GNU sed and BSD/macOS sed
#   (the \xNN notation is a GNU extension).
#   LC_ALL=C ensures byte-level matching
#   regardless of the user's locale.
#
# Outputs:
#   Cleaned text to stdout.
#######################################
function __cp_strip_ansi() {
  # Inject literal ESC (0x1B) and BEL (0x07) bytes via $'…'.
  # Doing it this way makes the regex readable (no \x1b clutter)
  # and works the same on GNU sed and BSD sed.
  local -r esc=$'\033'
  local -r bel=$'\007'

  # The triple sed pipeline applies the longest-match patterns first:
  #   1. OSC sequences (terminated by either BEL or ESC \)
  #   2. CSI sequences (parameters, intermediates, final byte)
  #   3. Short ESC <single byte> sequences (must run last,
  #      otherwise it would consume the leading ESC of CSI/OSC).
  LC_ALL=C sed -E \
    -e "s#${esc}\\][^${esc}${bel}]*(${bel}|${esc}\\\\)##g" \
    -e "s#${esc}\\[[0-9:;<=>?]*[ -/]*[@-~]##g" \
    -e "s#${esc}[^][]##g"
}

#######################################
# Internal pipeline runner.
#
# Reads stdin and writes to the chosen backend,
# optionally piping through __cp_strip_ansi first.
# Pulled into its own function so the caller
# can wrap the whole thing in `(set -o pipefail; …)`
# and have any stage's failure (sed, backend)
# propagate as the subshell's exit code.
#
# Arguments:
#   1:    raw_mode flag (0 = strip ANSI, 1 = preserve verbatim).
#   2..N: backend command and its arguments.
#######################################
function __cp_emit() {
  local -ir raw_mode=$1
  shift

  if ((raw_mode)); then
    "$@"
  else
    __cp_strip_ansi | "$@"
  fi
}

# endregion

# region Public API

#######################################
# Main function to write to clipboard.
#
# Arguments:
#   [options] [text...] or read from stdin.
#
# Options:
#   -r, --raw   Do not strip ANSI escape sequences.
#
# Returns:
#   0: On success.
#   Non-zero: On error (see header for code list).
#######################################
function copy() {
  # Restrict word splitting to newline/tab inside this function.
  # Stops accidental space-splitting on user input, while still
  # allowing arrays-from-newlines patterns where they are intended.
  # When we need space-joining (echo "$*"), we override IFS locally.
  local IFS=$'\n\t'
  local -i raw_mode=0

  # region Option parsing
  #
  # Standard GNU-style:
  #   -h / --help  : print usage and exit 0
  #   -r / --raw   : disable ANSI stripping
  #   --           : end of options, the rest is text
  #   -*           : unknown option, exit 2
  #
  # Plain words break the loop and reach the "argument mode" branch
  # below. Multiple -r flags are idempotent (raw_mode stays 1).
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        __cp_usage
        return 0
        ;;
      -r | --raw)
        raw_mode=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        __cp_error "Unknown option: $1" "$COPY_ERR_USAGE" \
          || return "$?"
        ;;
      *)
        break
        ;;
    esac
  done
  # endregion

  # region Backend resolution
  #
  # We deliberately use `cmd || rc=$?` rather than `if ! cmd`,
  # because `if !` resets $? before we can read it
  # (the `!` itself is the most recent command in the pipeline).
  local -a clipboard_backend_cmd
  local -i _detect_rc=0

  __cp_detect_backend clipboard_backend_cmd || _detect_rc=$?

  if [[ $_detect_rc -ne 0 ]]; then
    # Usage errors (unknown override) are already reported
    # by __cp_detect_backend; we just propagate the code.
    if [[ $_detect_rc -eq $COPY_ERR_USAGE ]]; then
      return "$_detect_rc"
    fi

    local error_msg='No clipboard backend found. '
    error_msg+='Install wl-clipboard, xclip, or xsel.'

    __cp_error "$error_msg" \
      "$COPY_ERR_NO_BACKEND" \
      || return "$?"
  fi
  # endregion

  # region Pipe mode
  #
  # `[[ ! -t 0 ]]` is true when stdin is NOT a terminal,
  # i.e. someone is piping data in. The pipeline runs in a subshell
  # so that `set -o pipefail` does not leak into the caller's shell.
  if [[ ! -t 0 ]]; then
    if ! (
      set -o pipefail
      __cp_emit "$raw_mode" "${clipboard_backend_cmd[@]}"
    ); then
      __cp_error 'Clipboard backend failed during pipe operation.' \
        "$COPY_ERR_BACKEND_FAILED" \
        || return "$?"
    fi
    return 0
  fi
  # endregion

  # region Argument mode
  #
  # No piped stdin: the remaining positional args become the payload.
  # Empty argv at this point means the user invoked `copy` with no
  # input at all, which is a usage error.
  if [[ $# -eq 0 ]]; then
    local error_msg='No input provided. '
    error_msg+='Pass text as arguments or pipe via stdin.'

    __cp_usage >&2
    __cp_error "$error_msg" \
      "$COPY_ERR_USAGE" \
      || return "$?"
  fi

  # Join arguments with single spaces, mirroring `echo "$*"` semantics.
  # Done in a subshell so the temporary `IFS=' '` does not affect
  # the surrounding code (which keeps `IFS=$'\n\t'`).
  local -r input_text="$(
    IFS=' '
    echo "$*"
  )"

  if ! (
    set -o pipefail
    printf '%s' "$input_text" \
      | __cp_emit "$raw_mode" "${clipboard_backend_cmd[@]}"
  ); then
    __cp_error 'Clipboard backend failed.' \
      "$COPY_ERR_BACKEND_FAILED" \
      || return "$?"
  fi
  # endregion
}

# endregion

# region Execution guard
#
# When the file is executed directly (chmod +x ./copy.sh, or via
# a /usr/local/bin/copy symlink), BASH_SOURCE[0] equals $0 and we
# run the function with the user's arguments.
# When sourced (e.g. from ~/.bashrc), this branch is skipped
# and only the function definitions become available in the shell.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  copy "$@"
  exit "$?"
fi
# endregion

### End of file
