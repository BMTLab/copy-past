#!/usr/bin/env bash

# Print the system clipboard to stdout, on Wayland or X11.
#
# Usage: past [OPTIONS] > FILE, or "$(past)";
#   `source past.sh` in ~/.bashrc gives the function past instead.
# Effects: none: past only reads the CLIPBOARD selection;
#   it needs a Wayland or X11 session.
# Dependencies: wl-paste (wl-clipboard), xclip or xsel.
# Settings: COPY_PAST_BACKEND, the backend to use:
#   wl-clipboard, xclip or xsel (default: the first one found).
# Exit codes: 0 success, 1 PAST_ERR_GENERAL, 2 PAST_ERR_USAGE,
#   3 PAST_ERR_NO_BACKEND, 4 PAST_ERR_BACKEND_FAILED,
#   5 PAST_ERR_TYPE_MISMATCH, 70 PAST_ERR_INTERNAL.
# See: past --help, README.md, tests/.
#
# How it works:
#   past prints the clipboard as it is, with no newline of its own.
#   wl-paste adds a newline to text, and its --no-newline
#   cuts the last line in wl-clipboard 2.2.1 and older,
#   so past runs plain wl-paste and removes that one newline.
#   A binary MIME type, such as image/png, skips this step,
#   since a bash variable cannot hold NUL bytes.
#
# Version: 2.0.1

# region Exit codes

# A shell may source this file again, for example to reload ~/.bashrc,
# so each readonly constant is set only once.
# bashsupport disable=BP5001

if [[ ! -v PAST_ERR_GENERAL ]]; then
  readonly PAST_ERR_GENERAL=1
fi

if [[ ! -v PAST_ERR_USAGE ]]; then
  readonly PAST_ERR_USAGE=2
fi

if [[ ! -v PAST_ERR_NO_BACKEND ]]; then
  readonly PAST_ERR_NO_BACKEND=3
fi

if [[ ! -v PAST_ERR_BACKEND_FAILED ]]; then
  readonly PAST_ERR_BACKEND_FAILED=4
fi

if [[ ! -v PAST_ERR_TYPE_MISMATCH ]]; then
  readonly PAST_ERR_TYPE_MISMATCH=5
fi

if [[ ! -v PAST_ERR_INTERNAL ]]; then
  readonly PAST_ERR_INTERNAL=70
fi

# endregion Exit codes

# region Internal helpers

#######################################
# Print the usage.
#
# Outputs:
#   The usage, to stdout.
#######################################
function __ps_usage() {
  command cat <<'EOF'
past - print system clipboard to stdout

Description:
  Detects the display server and outputs the clipboard content
  using wl-paste, xclip, or xsel.

Usage:
  past > output.txt
  echo "Clipboard contains: $(past)"
  past | cat
  past --image > screenshot.png
  past --help

Options:
  -h, --help            Show this help message.
      --type MIME       Request a specific MIME type from the backend
                        (e.g., application/json, image/png, text/html).
  -j, --json            Shortcut for --type application/json.
      --image[=FORMAT]  Read binary image data with the matching
                        image/<format> MIME type (default png).
  -d, --debug, --verbose
                        Print structured debug events on stderr
                        (lines prefixed with '[past debug]').
                        Has no effect on stdout or the payload.

Settings:
  COPY_PAST_BACKEND     Force a specific backend
                        (wl-clipboard | xclip | xsel).

Exit codes:
  0   success
  1   PAST_ERR_GENERAL: a general error
  2   PAST_ERR_USAGE: an unknown argument or a bad value
  3   PAST_ERR_NO_BACKEND: no clipboard backend found
  4   PAST_ERR_BACKEND_FAILED: the clipboard backend failed to read
  5   PAST_ERR_TYPE_MISMATCH: a MIME type that the backend cannot take
  70  PAST_ERR_INTERNAL: a bug in past
EOF
}

#######################################
# Print a message to stderr and return its code.
#
# Arguments:
#   1: The exit code.
#   2...: The lines of the message.
#
# Outputs:
#   Each line after 'past: ', to stderr.
#
# Returns:
#   The code in $1.
#######################################
function __ps_fail() {
  local -ir code="$1"
  shift

  printf 'past: %s\n' "$@" >&2

  return "${code}"
}

#######################################
# End a run that failed where no code planned it: the ERR trap calls it.
# It passes on unchanged a code that past returns, the 141 of a closed pipe,
# and the internal code of a subshell that has already reported.
#
# Arguments:
#   1: The status of the failed command.
#   2: Its line.
#   3: The command.
#######################################
function __ps_internal_error() {
  if [[ "${FUNCNAME[1]:-main}" == 'main' || "${FUNCNAME[1]}" == 'past' ]] \
    || (($1 == 141 || $1 == PAST_ERR_INTERNAL)); then
    exit "$1"
  fi

  printf 'past: internal error at line %s (status %s): %s\n' \
    "$2" "$1" "$3" >&2

  exit "${PAST_ERR_INTERNAL}"
}

#######################################
# Print a line of the debug log to stderr, when the log is on.
#
# The format is the one of __cp_debug in copy.sh,
# so both halves of a round trip log alike:
# [past debug] event=NAME key=value key='a value'.
# Without --debug, past prints nothing to stderr.
#
# Arguments:
#   1: 1 when the log is on, 0 when it is off.
#   2: The name of the event.
#   3...: The fields, each as key=value.
#
# Outputs:
#   The line, to stderr.
#######################################
function __ps_debug() {
  local -ir is_debug="$1"
  local line="[past debug] event=$2"
  local field key value

  if ((! is_debug)); then
    return 0
  fi

  shift 2
  for field in "$@"; do
    key="${field%%=*}"
    value="${field#*=}"
    if [[ "${value}" == *[[:space:]]* ]]; then
      line+=" ${key}='${value}'"
    else
      line+=" ${field}"
    fi
  done

  printf '%s\n' "${line}" >&2
}

#######################################
# Tell whether a command exists.
#
# Arguments:
#   1: The name of the command.
#
# Returns:
#   0 when it exists, 1 otherwise.
#######################################
function __ps_has_command() {
  command -v "$1" >/dev/null 2>&1
}

# endregion Internal helpers

# region Backend detection

#######################################
# Find the clipboard backend to read with.
#
# COPY_PAST_BACKEND names the backend, and then that backend must exist;
# an unknown name is a usage error, not a missing backend.
# Otherwise a Wayland session takes wl-paste first;
# then come xclip and xsel.
# wl-paste runs without --no-newline,
# which cuts the last line in wl-clipboard 2.2.1:
# __ps_read_wl_paste removes the newline that wl-paste adds instead.
#
# Arguments:
#   1: The name of the array that takes the command.
#
# Globals:
#   COPY_PAST_BACKEND, WAYLAND_DISPLAY, XDG_SESSION_TYPE: read.
#
# Returns:
#   0 on success, PAST_ERR_NO_BACKEND when no backend exists,
#   PAST_ERR_USAGE when COPY_PAST_BACKEND names no backend.
#######################################
function __ps_detect_backend() {
  local -n _detected_command_ref=$1

  case "${COPY_PAST_BACKEND:-}" in
    '') ;;
    wl-clipboard | wayland | wl-paste)
      if __ps_has_command wl-paste; then
        _detected_command_ref=(wl-paste)

        return 0
      fi

      return "${PAST_ERR_NO_BACKEND}"
      ;;
    xclip)
      if __ps_has_command xclip; then
        _detected_command_ref=(xclip -selection clipboard -out)

        return 0
      fi

      return "${PAST_ERR_NO_BACKEND}"
      ;;
    xsel)
      if __ps_has_command xsel; then
        _detected_command_ref=(xsel --clipboard --output)

        return 0
      fi

      return "${PAST_ERR_NO_BACKEND}"
      ;;
    *)
      __ps_fail "${PAST_ERR_USAGE}" \
        "unknown COPY_PAST_BACKEND value: '${COPY_PAST_BACKEND}'" \
        'set it to wl-clipboard, xclip or xsel, or unset it' \
        || return
      ;;
  esac

  if [[ -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == 'wayland' ]] \
    && __ps_has_command wl-paste; then
    _detected_command_ref=(wl-paste)

    return 0
  fi

  if __ps_has_command xclip; then
    _detected_command_ref=(xclip -selection clipboard -out)

    return 0
  fi

  if __ps_has_command xsel; then
    _detected_command_ref=(xsel --clipboard --output)

    return 0
  fi

  return "${PAST_ERR_NO_BACKEND}"
}

#######################################
# Add the MIME type to a backend command, as the backend spells it:
# wl-paste takes --type MIME, xclip takes -t MIME, and xsel takes none.
#
# Arguments:
#   1: The name of the backend command array.
#   2: The MIME type, such as application/json.
#
# Returns:
#   0 on success, PAST_ERR_TYPE_MISMATCH when the backend takes no MIME type.
#######################################
function __ps_apply_mime() {
  local -n _typed_command_ref=$1
  local -r mime_type="$2"

  case "${_typed_command_ref[0]}" in
    wl-paste) _typed_command_ref+=(--type "${mime_type}") ;;
    xclip) _typed_command_ref+=(-t "${mime_type}") ;;
    xsel)
      __ps_fail "${PAST_ERR_TYPE_MISMATCH}" \
        "xsel does not support MIME types such as '${mime_type}'" \
        'use wl-clipboard or xclip for them; COPY_PAST_BACKEND picks the backend' \
        || return
      ;;
    *)
      __ps_fail "${PAST_ERR_INTERNAL}" \
        "internal error: no MIME option for the backend '${_typed_command_ref[0]}'" \
        'please report this bug' \
        || return
      ;;
  esac
}

# endregion Backend detection

# region wl-paste reader

#######################################
# Print the clipboard through wl-paste, without the newline it adds.
#
# $(...) drops every trailing newline, so x and the status of wl-paste
# follow the output; the status after the last x tells a failure,
# and the text before it keeps its own newlines.
# A variable cannot hold NUL bytes, so this works for text only:
# a binary MIME type never comes here.
#
# Arguments:
#   $@: The backend command, wl-paste and its options.
#
# Outputs:
#   The text of the clipboard, to stdout.
#
# Returns:
#   0 on success, PAST_ERR_BACKEND_FAILED when wl-paste fails.
#######################################
function __ps_read_wl_paste() {
  local captured status_text
  local -i backend_status=0

  captured="$(
    command "$@" || backend_status=$?
    printf 'x%d' "${backend_status}"
  )"
  status_text="${captured##*x}"
  captured="${captured%x*}"

  if [[ ! "${status_text}" =~ ^[0-9]+$ ]] || ((status_text != 0)); then
    return "${PAST_ERR_BACKEND_FAILED}"
  fi

  # Plain wl-paste always adds one newline: remove that one only.
  printf '%s' "${captured%$'\n'}"
}

# endregion wl-paste reader

# region Option model

#######################################
# Set the options of past to their defaults.
#
# The options live in a map of the caller, so each call of past
# starts clean, even in a shell that sourced the file long ago.
#
# Arguments:
#   1: The name of the map that takes the options:
#      is_debug and should_show_help, each 0 or 1, and mime_type.
#######################################
function __ps_init_options() {
  local -n _default_options_ref=$1

  _default_options_ref=(
    ['mime_type']=''
    ['is_debug']=0
    ['should_show_help']=0
  )
}

#######################################
# Turn an image format, such as jpg or svg, into its MIME type,
# as __cp_image_format_to_mime in copy.sh does,
# so both halves of a round trip agree.
#
# Arguments:
#   1: The name of the variable that takes the MIME type.
#   2: The format; it is not empty.
#######################################
function __ps_image_format_to_mime() {
  local -n _mime_type_ref=$1
  local -r image_format="$2"

  case "${image_format}" in
    jpg | jpeg) _mime_type_ref='image/jpeg' ;;
    svg) _mime_type_ref='image/svg+xml' ;;
    *) _mime_type_ref="image/${image_format}" ;;
  esac
}

# endregion Option model

# region Argument parsing

#######################################
# Read the MIME type of --type MIME or --type=MIME.
#
# Arguments:
#   1: The name of the options map.
#   2: The name of the variable that takes how many arguments the flag used.
#   3: The flag.
#   4: The argument after the flag, if there is one.
#
# Returns:
#   0 on success, PAST_ERR_USAGE when the MIME type is missing or empty.
#######################################
function __ps_parse_type_flag() {
  local -n _type_options_ref=$1
  local -n _used_count_ref=$2
  local -r flag="$3"
  local mime_type

  if [[ "${flag}" == --type=* ]]; then
    mime_type="${flag#*=}"
    _used_count_ref=1
  else
    mime_type="${4:-}"
    _used_count_ref=2
  fi

  if [[ -z "${mime_type}" ]]; then
    __ps_fail "${PAST_ERR_USAGE}" '--type requires a MIME type, such as text/html' \
      'see: past --help' || return
  fi

  _type_options_ref['mime_type']="${mime_type}"
}

#######################################
# Read the format of --image or --image=FORMAT; png when none is given.
#
# Arguments:
#   1: The name of the options map.
#   2: The flag.
#
# Returns:
#   0 on success, PAST_ERR_USAGE when the format is empty.
#######################################
function __ps_parse_image_flag() {
  local -n _image_options_ref=$1
  local -r flag="$2"
  local image_format='png' image_mime_type=''

  if [[ "${flag}" == --image=* ]]; then
    image_format="${flag#*=}"
  fi

  if [[ -z "${image_format}" ]]; then
    __ps_fail "${PAST_ERR_USAGE}" '--image=FORMAT requires a format, such as png' \
      'see: past --help' || return
  fi

  __ps_image_format_to_mime image_mime_type "${image_format}"
  _image_options_ref['mime_type']="${image_mime_type}"
}

#######################################
# Read the options of past from its command line.
#
# past takes no text, so any word that is no option is a usage error.
# --help ends the parsing at once.
#
# Arguments:
#   1: The name of the options map.
#   2...: The command line.
#
# Returns:
#   0 on success, PAST_ERR_USAGE on an unknown argument or a bad value.
#######################################
function __ps_parse_arguments() {
  local -n _parsed_options_ref=$1
  local -r options_name="$1"
  local -i used_count=0
  shift

  while (($# > 0)); do
    case "$1" in
      -h | --help)
        _parsed_options_ref['should_show_help']=1

        return 0
        ;;
      --type | --type=*)
        __ps_parse_type_flag "${options_name}" used_count "$@" || return
        shift "$((used_count - 1))"
        ;;
      --json | -j) _parsed_options_ref['mime_type']='application/json' ;;
      --image | --image=*)
        __ps_parse_image_flag "${options_name}" "$1" || return
        ;;
      -d | --debug | --verbose) _parsed_options_ref['is_debug']=1 ;;
      *)
        __ps_fail "${PAST_ERR_USAGE}" "unknown argument: $1" 'see: past --help' \
          || return
        ;;
    esac
    shift
  done
}

#######################################
# Tell whether a MIME type is binary: image/* or application/octet-stream.
#
# A binary payload skips the newline fix of wl-paste,
# since removing a last 0x0A byte would break a PNG.
# Everything else, JSON and text/* too, counts as text.
#
# Arguments:
#   1: The MIME type; it may be empty.
#
# Returns:
#   0 when the type is binary, 1 otherwise.
#######################################
function __ps_is_binary_mime() {
  case "$1" in
    image/* | application/octet-stream) return 0 ;;
    *) return 1 ;;
  esac
}

# endregion Argument parsing

# region Backend wiring

#######################################
# Find the backend command, and add the MIME type that the user gave.
#
# Arguments:
#   1: The name of the array that takes the backend command.
#   2: The MIME type of the user; empty for none.
#
# Returns:
#   0 on success, PAST_ERR_USAGE on an unknown COPY_PAST_BACKEND,
#   PAST_ERR_NO_BACKEND when no backend is installed,
#   PAST_ERR_TYPE_MISMATCH when the backend takes no MIME type.
#######################################
function __ps_resolve_backend() {
  local -r mime_type="$2"
  local -i detect_status=0

  __ps_detect_backend "$1" || detect_status=$?

  # __ps_detect_backend has already reported an unknown backend.
  if ((detect_status == PAST_ERR_USAGE)); then
    return "${detect_status}"
  fi
  if ((detect_status != 0)); then
    __ps_fail "${PAST_ERR_NO_BACKEND}" 'no clipboard backend found' \
      'install wl-clipboard, xclip or xsel' \
      || return
  fi

  if [[ -n "${mime_type}" ]]; then
    __ps_apply_mime "$1" "${mime_type}" || return
  fi
}

# endregion Backend wiring

# region Read pipeline

#######################################
# Print the clipboard to stdout.
#
# wl-paste with a text MIME type goes through __ps_read_wl_paste,
# to remove the newline that wl-paste adds.
# wl-paste with a binary MIME type runs as it is,
# since that fix would lose the NUL bytes;
# xclip and xsel print the clipboard as it is anyway.
#
# Arguments:
#   1: 1 when the MIME type is binary, 0 otherwise.
#   2...: The backend command.
#
# Outputs:
#   The clipboard, to stdout.
#
# Returns:
#   0 on success, PAST_ERR_BACKEND_FAILED when the backend fails.
#######################################
function __ps_print_clipboard() {
  local -ir is_binary_mime="$1"
  shift

  if [[ "$1" == 'wl-paste' ]] && ((! is_binary_mime)); then
    if ! __ps_read_wl_paste "$@"; then
      __ps_fail "${PAST_ERR_BACKEND_FAILED}" 'the clipboard backend failed to read' \
        'see its message above; COPY_PAST_BACKEND picks another backend' \
        || return
    fi

    return 0
  fi

  if ! command "$@"; then
    __ps_fail "${PAST_ERR_BACKEND_FAILED}" 'the clipboard backend failed to read' \
      'see its message above; COPY_PAST_BACKEND picks another backend' \
      || return
  fi
}

# endregion Read pipeline

# region Public API

#######################################
# Print the clipboard.
#
# Each step lives in a helper, so the body reads as a list of steps.
# The state lives in this function and goes to the helpers by name,
# so each call starts clean, even in a shell that sourced the file.
#
# Arguments:
#   $@: The options; see __ps_usage.
#
# Outputs:
#   The clipboard, to stdout.
#
# Returns:
#   0 on success, or an exit code from the header.
#######################################
function past() {
  local -A options=()
  local -a backend_command=()
  local -i is_binary_mime=0

  __ps_init_options options
  __ps_parse_arguments options "$@" || return
  if ((options['should_show_help'])); then
    __ps_usage

    return 0
  fi

  __ps_debug "${options['is_debug']}" 'options-parsed' \
    "mime=${options['mime_type']:-<none>}"

  # The read step needs to know whether to fix the newline of wl-paste.
  if __ps_is_binary_mime "${options['mime_type']}"; then
    is_binary_mime=1
  fi
  __ps_debug "${options['is_debug']}" 'mime-classified' \
    "is-binary=${is_binary_mime}"

  __ps_resolve_backend backend_command "${options['mime_type']}" || return
  __ps_debug "${options['is_debug']}" 'backend-resolved' \
    "backend=${backend_command[0]}"

  if [[ "${backend_command[0]}" == 'wl-paste' ]] && ((! is_binary_mime)); then
    __ps_debug "${options['is_debug']}" 'read-strategy' \
      'mode=wl-paste-newline-strip'
  else
    __ps_debug "${options['is_debug']}" 'read-strategy' 'mode=direct-exec'
  fi

  __ps_print_clipboard "${is_binary_mime}" "${backend_command[@]}"
}

# endregion Public API

# region Execution guard

# Sourced, the file only defines the function past;
# run as a program, it runs past in strict mode.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -o errexit -o nounset -o pipefail -o errtrace
  shopt -s inherit_errexit
  trap '__ps_internal_error "$?" "${LINENO}" "${BASH_COMMAND}"' ERR
  trap 'exit 130' INT
  trap 'exit 143' TERM

  past "$@"
fi

# endregion Execution guard

### End
