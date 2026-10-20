#!/usr/bin/env bash

# Copy text or binary data to the system clipboard, on Wayland or X11.
#
# Usage: copy [OPTIONS] [TEXT...], or COMMAND | copy [OPTIONS];
#   `source copy.sh` in ~/.bashrc gives the function copy instead.
# Effects: replaces the CLIPBOARD selection,
#   or adds to its text with --append; needs a Wayland or X11 session;
#   --help changes nothing.
# Dependencies: wl-copy (wl-clipboard), xclip or xsel; sed;
#   jq, to detect JSON (optional); past.sh beside copy.sh, for --append.
# Settings: COPY_PAST_BACKEND, the backend to use:
#   wl-clipboard, xclip or xsel (default: the first one found).
# Exit codes: 0 success, 1 COPY_ERR_GENERAL, 2 COPY_ERR_USAGE,
#   3 COPY_ERR_NO_BACKEND, 4 COPY_ERR_BACKEND_FAILED,
#   5 COPY_ERR_TYPE_MISMATCH, 70 COPY_ERR_INTERNAL.
# See: copy --help, README.md, tests/.
#
# How it works:
#   The payload comes from stdin when stdin is no terminal,
#   and from the arguments, joined by spaces, otherwise.
#   ANSI escape sequences go, unless --raw keeps them.
#   The first bytes choose the MIME type:
#   the magic bytes of PNG, JPEG, GIF, BMP and WebP,
#   or JSON that jq parses; anything else is text/plain.
#   A Wayland session, by WAYLAND_DISPLAY or XDG_SESSION_TYPE,
#   takes wl-copy first; then come xclip and xsel.
#   wl-copy and xclip leave a process behind to serve the clipboard,
#   so the backend gets output of its own:
#   a caller of copy never waits for that process.
#
# Version: 2.0.1

# region Exit codes

# A shell may source this file again, for example to reload ~/.bashrc,
# so each readonly constant is set only once.
# bashsupport disable=BP5001

if [[ ! -v COPY_ERR_GENERAL ]]; then
  readonly COPY_ERR_GENERAL=1
fi

if [[ ! -v COPY_ERR_USAGE ]]; then
  readonly COPY_ERR_USAGE=2
fi

if [[ ! -v COPY_ERR_NO_BACKEND ]]; then
  readonly COPY_ERR_NO_BACKEND=3
fi

if [[ ! -v COPY_ERR_BACKEND_FAILED ]]; then
  readonly COPY_ERR_BACKEND_FAILED=4
fi

if [[ ! -v COPY_ERR_TYPE_MISMATCH ]]; then
  readonly COPY_ERR_TYPE_MISMATCH=5
fi

if [[ ! -v COPY_ERR_INTERNAL ]]; then
  readonly COPY_ERR_INTERNAL=70
fi

# endregion Exit codes

# region Internal helpers

#######################################
# Print the usage.
#
# Outputs:
#   The usage, to stdout.
#######################################
function __cp_usage() {
  command cat <<'EOF'
copy - write text or binary data to system clipboard

Description:
  Detects the display server (Wayland/X11) and uses the appropriate tool
  (wl-copy, xclip, or xsel) to copy data to the clipboard.

  By default, ANSI escape sequences (colors, bold, hyperlinks, etc.)
  are stripped so that pasted text works correctly in GUI applications.
  Use --raw (-r) to preserve escape sequences for terminal-to-terminal use.

Usage:
  copy [options] [text...]
  echo 'text' | copy
  cat image.png | copy --image
  copy --help

Options:
  -h, --help            Show this help message.
  -r, --raw             Preserve ANSI escape sequences (do not strip colors).
  -a, --append          Append to the existing clipboard content
                        instead of replacing it (text only).
      --trim            Trim leading and trailing whitespace before writing
                        (text only).
      --type MIME       Set the clipboard MIME type explicitly
                        (e.g., application/json, image/png, text/html).
                        Implies --raw for non-text types.
                        Always wins over auto-detection.
  -j, --json            Shortcut for --type application/json --raw;
                        trusts the user without parsing the payload.
      --image[=FORMAT]  Copy binary image data; FORMAT defaults to png
                        (jpg, jpeg, webp, gif, svg are also accepted).
                        Implies --raw.
      --no-auto         Disable the always-on auto-detection
                        and copy the payload as text/plain.
  -d, --debug, --verbose
                        Print structured debug events on stderr
                        (lines prefixed with '[copy debug]').
                        Has no effect on stdout or the payload.
  --                    End of options; remaining arguments are treated as text.

Settings:
  COPY_PAST_BACKEND     Force a specific backend
                        (wl-clipboard | xclip | xsel).

Exit codes:
  0   success
  1   COPY_ERR_GENERAL: a general error, such as no past for --append
  2   COPY_ERR_USAGE: an unknown option, a bad value, or no input
  3   COPY_ERR_NO_BACKEND: no clipboard backend found
  4   COPY_ERR_BACKEND_FAILED: the clipboard backend failed
  5   COPY_ERR_TYPE_MISMATCH: options that do not fit together,
      or a MIME type that the backend cannot take
  70  COPY_ERR_INTERNAL: a bug in copy

Examples:
  copy 'Hello World'                  # Copies: Hello World
  pwd | copy                          # Copies current path
  ls --color | copy -r                # Preserves color codes
  date | copy --append                # Appends date to current clipboard
  echo '  spaced  ' | copy --trim     # Copies: spaced
  cat data.json | copy                # Auto-detected as application/json
  cat data.json | copy -j             # Same, explicit (no jq parse)
  cat data.json | copy --no-auto      # Force text/plain
  cat picture.png | copy              # Auto-detected as image/png
  grim -g "$(slurp)" - | copy --image # Screenshot in clipboard (explicit)
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
#   Each line after 'copy: ', to stderr.
#
# Returns:
#   The code in $1.
#######################################
function __cp_fail() {
  local -ir code="$1"
  shift

  printf 'copy: %s\n' "$@" >&2

  return "${code}"
}

#######################################
# End a run that failed where no code planned it: the ERR trap calls it.
# It passes on unchanged a code that copy returns, the 141 of a closed pipe,
# and the internal code of a subshell that has already reported.
#
# Arguments:
#   1: The status of the failed command.
#   2: Its line.
#   3: The command.
#######################################
function __cp_internal_error() {
  if [[ "${FUNCNAME[1]:-main}" == 'main' || "${FUNCNAME[1]}" == 'copy' ]] \
    || (($1 == 141 || $1 == COPY_ERR_INTERNAL)); then
    exit "$1"
  fi

  printf 'copy: internal error at line %s (status %s): %s\n' \
    "$2" "$1" "$3" >&2

  exit "${COPY_ERR_INTERNAL}"
}

#######################################
# Print a line of the debug log to stderr, when the log is on.
#
# A line reads: [copy debug] event=NAME key=value key='a value'.
# Tests and people match single events in it,
# so the format is a contract: a value with whitespace gets single quotes.
# Without --debug, copy prints nothing to stderr,
# so it never disturbs a pipeline.
#
# Arguments:
#   1: 1 when the log is on, 0 when it is off.
#   2: The name of the event.
#   3...: The fields, each as key=value.
#
# Outputs:
#   The line, to stderr.
#######################################
function __cp_debug() {
  local -ir is_debug="$1"
  local line="[copy debug] event=$2"
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
function __cp_has_command() {
  command -v "$1" >/dev/null 2>&1
}

# endregion Internal helpers

# region Backend detection

#######################################
# Find the clipboard backend to write with.
#
# COPY_PAST_BACKEND names the backend, and then that backend must exist;
# an unknown name is a usage error, not a missing backend.
# Otherwise a Wayland session takes wl-copy first,
# since xclip would go through XWayland; then come xclip and xsel.
# The command holds no MIME type yet: __cp_apply_mime adds it.
#
# Arguments:
#   1: The name of the array that takes the command.
#
# Globals:
#   COPY_PAST_BACKEND, WAYLAND_DISPLAY, XDG_SESSION_TYPE: read.
#
# Returns:
#   0 on success, COPY_ERR_NO_BACKEND when no backend exists,
#   COPY_ERR_USAGE when COPY_PAST_BACKEND names no backend.
#######################################
function __cp_detect_backend() {
  local -n _detected_command_ref=$1

  case "${COPY_PAST_BACKEND:-}" in
    '') ;;
    wl-clipboard | wayland | wl-copy)
      if __cp_has_command wl-copy; then
        _detected_command_ref=(wl-copy)

        return 0
      fi

      return "${COPY_ERR_NO_BACKEND}"
      ;;
    xclip)
      if __cp_has_command xclip; then
        _detected_command_ref=(xclip -selection clipboard -in)

        return 0
      fi

      return "${COPY_ERR_NO_BACKEND}"
      ;;
    xsel)
      if __cp_has_command xsel; then
        _detected_command_ref=(xsel --clipboard --input)

        return 0
      fi

      return "${COPY_ERR_NO_BACKEND}"
      ;;
    *)
      __cp_fail "${COPY_ERR_USAGE}" \
        "unknown COPY_PAST_BACKEND value: '${COPY_PAST_BACKEND}'" \
        'set it to wl-clipboard, xclip or xsel, or unset it' \
        || return
      ;;
  esac

  if [[ -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == 'wayland' ]] \
    && __cp_has_command wl-copy; then
    _detected_command_ref=(wl-copy)

    return 0
  fi

  if __cp_has_command xclip; then
    _detected_command_ref=(xclip -selection clipboard -in)

    return 0
  fi

  if __cp_has_command xsel; then
    _detected_command_ref=(xsel --clipboard --input)

    return 0
  fi

  return "${COPY_ERR_NO_BACKEND}"
}

#######################################
# Add the MIME type to a backend command, as the backend spells it:
# wl-copy takes --type MIME, xclip takes -t MIME, and xsel takes none.
#
# Arguments:
#   1: The name of the backend command array.
#   2: The MIME type, such as application/json.
#
# Returns:
#   0 on success, COPY_ERR_TYPE_MISMATCH when the backend takes no MIME type.
#######################################
function __cp_apply_mime() {
  local -n _typed_command_ref=$1
  local -r mime_type="$2"

  case "${_typed_command_ref[0]}" in
    wl-copy) _typed_command_ref+=(--type "${mime_type}") ;;
    xclip) _typed_command_ref+=(-t "${mime_type}") ;;
    xsel)
      __cp_fail "${COPY_ERR_TYPE_MISMATCH}" \
        "xsel does not support MIME types such as '${mime_type}'" \
        'use wl-clipboard or xclip for them; COPY_PAST_BACKEND picks the backend' \
        || return
      ;;
    *)
      __cp_fail "${COPY_ERR_INTERNAL}" \
        "internal error: no MIME option for the backend '${_typed_command_ref[0]}'" \
        'please report this bug' \
        || return
      ;;
  esac
}

# endregion Backend detection

# region MIME sniffing

#######################################
# Find the first character of a file that is not whitespace.
#
# bash reads the file a block at a time,
# so no process has to read the whole payload.
#
# Arguments:
#   1: The name of the variable that takes the character;
#      it stays empty when the file holds only whitespace.
#   2: The path of the file.
#######################################
function __cp_find_first_visible_character() {
  local -n _character_ref=$1
  local -r file_path="$2"
  local block=''

  _character_ref=''
  while IFS= read -r -d '' -n 4096 block || [[ -n "${block}" ]]; do
    block="${block#"${block%%[![:space:]]*}"}"
    if [[ -n "${block}" ]]; then
      _character_ref="${block:0:1}"

      return 0
    fi
  done <"${file_path}"
}

#######################################
# Guess the MIME type of a payload from its first bytes.
#
# The magic bytes of PNG, JPEG, GIF, BMP and WebP come first:
# plain text never starts with them, so they are never wrong.
# Then JSON: the first character that is not whitespace is { or [,
# and jq parses the whole payload.
# Without jq the payload stays text, since shell code, logs
# and set literals look like JSON too often to guess without a parser.
# Anything else is text/plain.
# A file name never decides: a pipe has none.
#
# Arguments:
#   1: The name of the variable that takes the MIME type.
#   2: The path of the buffered payload.
#######################################
function __cp_sniff_mime() {
  local -n _mime_type_ref=$1
  local -r payload_path="$2"
  local magic_hex first_character

  # od prints the first 16 bytes as hex, enough for every signature;
  # WebP is a RIFF container with WEBP at byte 8.
  magic_hex="$(LC_ALL=C command od -An -tx1 -N 16 -- "${payload_path}")" \
    || return
  magic_hex="${magic_hex//[[:space:]]/}"
  case "${magic_hex}" in
    89504e47*) _mime_type_ref='image/png' ;;
    ffd8ff*) _mime_type_ref='image/jpeg' ;;
    47494638*) _mime_type_ref='image/gif' ;;
    424d*) _mime_type_ref='image/bmp' ;;
    52494646????????57454250*) _mime_type_ref='image/webp' ;;
    *) _mime_type_ref='' ;;
  esac
  if [[ -n "${_mime_type_ref}" ]]; then
    return 0
  fi

  __cp_find_first_visible_character first_character "${payload_path}"
  case "${first_character}" in
    '{' | '[')
      if __cp_has_command jq \
        && command jq -e '.' <"${payload_path}" >/dev/null 2>&1; then
        _mime_type_ref='application/json'

        return 0
      fi
      ;;
  esac

  _mime_type_ref='text/plain'
}

# endregion MIME sniffing

# region Text filters

#######################################
# Remove ANSI escape sequences from stdin.
#
# The patterns follow ECMA-48, the longest form first,
# so the short form never takes the ESC of a longer one:
#   - OSC: ESC ] and text up to BEL or ESC \,
#     such as a window title or an OSC 8 link;
#   - CSI: ESC [, parameters 0x30-0x3F, intermediates 0x20-0x2F,
#     and a final byte 0x40-0x7E, so private modes such as ESC[?25h go too;
#   - a short escape: ESC and one byte that is not [ or ], such as ESC c.
# $'...' puts the ESC and BEL bytes into the patterns:
# GNU and BSD sed both read them, but only GNU sed reads \xNN.
# LC_ALL=C makes sed match bytes, whatever the locale.
#
# Inputs:
#   The text, on stdin.
#
# Outputs:
#   The text without escape sequences, to stdout.
#######################################
function __cp_strip_ansi() {
  local -r escape=$'\033'
  local -r bell=$'\007'

  LC_ALL=C command sed -E \
    -e "s#${escape}\\][^${escape}${bell}]*(${bell}|${escape}\\\\)##g" \
    -e "s#${escape}\\[[0-9:;<=>?]*[ -/]*[@-~]##g" \
    -e "s#${escape}[^][]##g"
}

#######################################
# Remove the whitespace at both ends of stdin.
#
# bash trims the text by parameter expansion, without a process.
# Whitespace is [[:space:]]: space, tab, newline, CR, FF and VT.
# A bash variable cannot hold NUL bytes, so binary data would break;
# the options refuse --trim with a binary MIME type.
#
# Inputs:
#   The text, on stdin.
#
# Outputs:
#   The trimmed text, to stdout.
#######################################
function __cp_trim_whitespace() {
  local content=''

  # read -d '' reads all of stdin, and it returns 1 at the end of stdin.
  IFS= read -r -d '' content || true
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"

  printf '%s' "${content}"
}

#######################################
# Pass stdin through the filters that the options ask for,
# and then to the backend.
#
# The caller runs it in a subshell with pipefail,
# so a failure of any stage, sed, trim or the backend, is its status.
#
# Arguments:
#   1: 1 to keep ANSI escape sequences, 0 to remove them.
#   2: 1 to trim whitespace, 0 to keep it.
#   3...: The backend command.
#
# Inputs:
#   The payload, on stdin.
#######################################
function __cp_filter_and_write() {
  local -ir is_raw="$1"
  local -ir should_trim="$2"
  shift 2

  if ((is_raw && should_trim)); then
    __cp_trim_whitespace | __cp_run_backend "$@"
  elif ((is_raw)); then
    __cp_run_backend "$@"
  elif ((should_trim)); then
    __cp_strip_ansi | __cp_trim_whitespace | __cp_run_backend "$@"
  else
    __cp_strip_ansi | __cp_run_backend "$@"
  fi
}

# endregion Text filters

# region Append helpers

#######################################
# Find the command that reads the clipboard for --append.
#
# A shell that sourced past.sh has the function past, which comes first.
# Otherwise bash runs the past.sh that lies beside copy.sh.
#
# Arguments:
#   1: The name of the array that takes the command.
#
# Returns:
#   0 when a command is found, COPY_ERR_GENERAL otherwise.
#######################################
function __cp_resolve_past() {
  local -n _past_command_ref=$1
  local script_directory='.'

  if declare -F past >/dev/null; then
    _past_command_ref=(past)

    return 0
  fi

  if [[ "${BASH_SOURCE[0]}" == */* ]]; then
    script_directory="${BASH_SOURCE[0]%/*}"
  fi
  if [[ -r "${script_directory:-/}/past.sh" ]]; then
    _past_command_ref=(command bash "${script_directory:-/}/past.sh")

    return 0
  fi

  return "${COPY_ERR_GENERAL}"
}

#######################################
# Print the clipboard, for --append to put the new text after it.
#
# Outputs:
#   The text of the clipboard, to stdout.
#
# Returns:
#   0 on success, the status of past when it fails,
#   COPY_ERR_GENERAL when no past is found.
#######################################
function __cp_read_clipboard() {
  local -a past_command=()

  if ! __cp_resolve_past past_command; then
    __cp_fail "${COPY_ERR_GENERAL}" 'cannot find past for --append' \
      'install past beside copy, as make install does' \
      || return
  fi

  "${past_command[@]}"
}

# endregion Append helpers

# region Option model

#######################################
# Set the options of copy to their defaults.
#
# The options live in a map of the caller, so each call of copy
# starts clean, even in a shell that sourced the file long ago.
#
# Arguments:
#   1: The name of the map that takes the options:
#      is_raw, should_trim, should_append, should_detect_mime,
#      is_debug and should_show_help, each 0 or 1, and mime_type.
#######################################
function __cp_init_options() {
  local -n _default_options_ref=$1

  _default_options_ref=(
    ['is_raw']=0
    ['should_trim']=0
    ['should_append']=0
    ['should_detect_mime']=1
    ['is_debug']=0
    ['should_show_help']=0
    ['mime_type']=''
  )
}

#######################################
# Turn an image format, such as jpg or svg, into its MIME type.
#
# jpg and jpeg become image/jpeg, and svg becomes image/svg+xml;
# png, webp, gif, bmp, tiff and every other format become image/FORMAT,
# so the backend, not copy, rejects a format it does not know.
#
# Arguments:
#   1: The name of the variable that takes the MIME type.
#   2: The format; it is not empty.
#######################################
function __cp_image_format_to_mime() {
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
#   0 on success, COPY_ERR_USAGE when the MIME type is missing or empty.
#######################################
function __cp_parse_type_flag() {
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
    __cp_fail "${COPY_ERR_USAGE}" '--type requires a MIME type, such as text/html' \
      'see: copy --help' || return
  fi

  _type_options_ref['mime_type']="${mime_type}"
}

#######################################
# Read the format of --image or --image=FORMAT; png when none is given.
#
# An image is binary, so --image also keeps the payload raw:
# the ANSI filter would break it.
#
# Arguments:
#   1: The name of the options map.
#   2: The flag.
#
# Returns:
#   0 on success, COPY_ERR_USAGE when the format is empty.
#######################################
function __cp_parse_image_flag() {
  local -n _image_options_ref=$1
  local -r flag="$2"
  local image_format='png' image_mime_type=''

  if [[ "${flag}" == --image=* ]]; then
    image_format="${flag#*=}"
  fi

  if [[ -z "${image_format}" ]]; then
    __cp_fail "${COPY_ERR_USAGE}" '--image=FORMAT requires a format, such as png' \
      'see: copy --help' || return
  fi

  __cp_image_format_to_mime image_mime_type "${image_format}"
  _image_options_ref['mime_type']="${image_mime_type}"
  _image_options_ref['is_raw']=1
}

#######################################
# Read the options of copy from its command line.
#
# The options come first; the first word that is no option,
# or the word after --, starts the text.
# --help ends the parsing at once.
#
# Arguments:
#   1: The name of the options map.
#   2: The name of the array that takes the words of the text.
#   3...: The command line.
#
# Returns:
#   0 on success, COPY_ERR_USAGE on an unknown option or a bad value.
#######################################
function __cp_parse_arguments() {
  local -n _parsed_options_ref=$1
  local -n _positional_ref=$2
  local -r options_name="$1"
  local -i used_count=0
  shift 2

  while (($# > 0)); do
    case "$1" in
      -h | --help)
        _parsed_options_ref['should_show_help']=1

        return 0
        ;;
      -r | --raw) _parsed_options_ref['is_raw']=1 ;;
      -a | --append) _parsed_options_ref['should_append']=1 ;;
      --trim) _parsed_options_ref['should_trim']=1 ;;
      --type | --type=*)
        __cp_parse_type_flag "${options_name}" used_count "$@" || return
        shift "$((used_count - 1))"
        ;;
      -j | --json)
        _parsed_options_ref['mime_type']='application/json'
        _parsed_options_ref['is_raw']=1
        ;;
      --image | --image=*)
        __cp_parse_image_flag "${options_name}" "$1" || return
        ;;
      --no-auto) _parsed_options_ref['should_detect_mime']=0 ;;
      -d | --debug | --verbose) _parsed_options_ref['is_debug']=1 ;;
      --)
        shift
        break
        ;;
      -*)
        __cp_fail "${COPY_ERR_USAGE}" "unknown option: $1" 'see: copy --help' \
          || return
        ;;
      *) break ;;
    esac
    shift
  done

  _positional_ref=("$@")
}

# endregion Argument parsing

# region Option validation

#######################################
# Tell whether a MIME type is binary: image/* or application/octet-stream.
#
# A binary payload skips the ANSI and trim filters,
# and --append and --trim refuse it.
# Everything else, JSON and text/* too, counts as text.
#
# Arguments:
#   1: The MIME type; it may be empty.
#
# Returns:
#   0 when the type is binary, 1 otherwise.
#######################################
function __cp_is_binary_mime() {
  case "$1" in
    image/* | application/octet-stream) return 0 ;;
    *) return 1 ;;
  esac
}

#######################################
# Refuse the options that would break the data,
# and turn off auto-detection where the user decides.
#
# An explicit MIME type always wins over auto-detection.
# --append turns auto-detection off too:
# the old text of the clipboard comes first in the payload,
# so a guess from the new part alone would be wrong,
# and adding text to the clipboard is what --append means.
#
# Arguments:
#   1: The name of the options map.
#
# Returns:
#   0 on success, COPY_ERR_TYPE_MISMATCH when --append or --trim
#   meets a binary MIME type.
#######################################
function __cp_validate_options() {
  local -n _checked_options_ref=$1

  if __cp_is_binary_mime "${_checked_options_ref['mime_type']}"; then
    if ((_checked_options_ref['should_append'])); then
      __cp_fail "${COPY_ERR_TYPE_MISMATCH}" \
        "--append is only valid for text payloads, not for ${_checked_options_ref['mime_type']}" \
        'drop --append: binary data can only replace the clipboard' \
        || return
    fi
    if ((_checked_options_ref['should_trim'])); then
      __cp_fail "${COPY_ERR_TYPE_MISMATCH}" \
        "--trim is only valid for text payloads, not for ${_checked_options_ref['mime_type']}" \
        'drop --trim: binary data goes to the clipboard as it is' \
        || return
    fi
  fi

  if [[ -n "${_checked_options_ref['mime_type']}" ]] \
    || ((_checked_options_ref['should_append'])); then
    _checked_options_ref['should_detect_mime']=0
  fi
}

# endregion Option validation

# region Backend wiring

#######################################
# Find the backend command, and add the MIME type that the user gave.
#
# Arguments:
#   1: The name of the array that takes the backend command.
#   2: The MIME type of the user; empty for none.
#
# Returns:
#   0 on success, COPY_ERR_USAGE on an unknown COPY_PAST_BACKEND,
#   COPY_ERR_NO_BACKEND when no backend is installed,
#   COPY_ERR_TYPE_MISMATCH when the backend takes no MIME type.
#######################################
function __cp_resolve_backend() {
  local -r mime_type="$2"
  local -i detect_status=0

  __cp_detect_backend "$1" || detect_status=$?

  # __cp_detect_backend has already reported an unknown backend.
  if ((detect_status == COPY_ERR_USAGE)); then
    return "${detect_status}"
  fi
  if ((detect_status != 0)); then
    __cp_fail "${COPY_ERR_NO_BACKEND}" 'no clipboard backend found' \
      'install wl-clipboard, xclip or xsel' \
      || return
  fi

  if [[ -n "${mime_type}" ]]; then
    __cp_apply_mime "$1" "${mime_type}" || return
  fi
}

#######################################
# Run the clipboard backend with output of its own.
#
# wl-copy and xclip leave a process behind
# that serves the clipboard until another program takes it,
# and that process keeps the stdout and stderr it got from copy.
# Were they the caller's, a capture such as $(copy), a pipe,
# or the shell tool of an AI agent would wait
# for as long as the clipboard holds the data.
# So the backend writes to /dev/null and to a file,
# and its error messages reach stderr from that file
# once the backend returns.
#
# Arguments:
#   $@: The backend command; the payload comes on stdin.
#
# Outputs:
#   The error messages of the backend, to stderr.
#
# Returns:
#   The status of the backend.
#######################################
function __cp_run_backend() {
  local errors_path
  local -i backend_status=0

  # Without a file for the errors, losing their text beats a hang.
  errors_path="$(command mktemp -t copy-errors.XXXXXX)" || errors_path='/dev/null'

  command "$@" >/dev/null 2>"${errors_path}" || backend_status=$?

  if [[ "${errors_path}" != '/dev/null' ]]; then
    if [[ -s "${errors_path}" ]]; then
      command cat -- "${errors_path}" >&2
    fi
    command rm -f -- "${errors_path}"
  fi

  return "${backend_status}"
}

# endregion Backend wiring

# region Input buffering

#######################################
# Buffer the payload in a temporary file, to sniff it and then write it.
#
# A piped stdin goes to the file as it is;
# otherwise the words of the text go there, joined by spaces.
# No input at all is a usage error.
#
# Arguments:
#   1: The name of the variable that takes the path of the file.
#   2...: The words of the text, in argument mode.
#
# Returns:
#   0 on success, COPY_ERR_USAGE when there is no input.
#######################################
function __cp_buffer_input() {
  local -n _buffer_path_ref=$1
  shift

  _buffer_path_ref="$(command mktemp -t copy-auto.XXXXXX)" || return

  if [[ ! -t 0 ]]; then
    command cat >"${_buffer_path_ref}" || return

    return 0
  fi

  if (($# > 0)); then
    (
      IFS=' '
      echo "$*"
    ) >"${_buffer_path_ref}"

    return 0
  fi

  command rm -f -- "${_buffer_path_ref}"
  _buffer_path_ref=''
  __cp_usage >&2
  __cp_fail "${COPY_ERR_USAGE}" 'no input' \
    'pass the text as arguments, or pipe it to stdin' \
    || return
}

#######################################
# Write a buffered payload to the backend as it is, with no filter,
# and remove the buffer.
#
# A binary payload takes this way, since the filters would break it.
#
# Arguments:
#   1: The path of the buffered payload.
#   2...: The backend command.
#
# Returns:
#   0 on success, COPY_ERR_BACKEND_FAILED when the backend fails.
#######################################
function __cp_write_buffer_raw() {
  local -r buffer_path="$1"
  local -i write_status=0
  shift

  __cp_run_backend "$@" <"${buffer_path}" || write_status=$?
  command rm -f -- "${buffer_path}"

  if ((write_status != 0)); then
    __cp_fail "${COPY_ERR_BACKEND_FAILED}" 'the clipboard backend failed' \
      'see its message above; COPY_PAST_BACKEND picks another backend' \
      || return
  fi
}

# endregion Input buffering

# region Auto-detection orchestration

#######################################
# Sniff the MIME type of the buffered payload, and route the payload.
#
# A binary payload goes to the backend as it is, with its MIME type,
# and the variable in $2 takes 1.
# A text payload becomes the stdin of the shell, through exec,
# so the text pipeline reads the same bytes.
# The buffer is removed on both ways.
#
# Arguments:
#   1: The name of the backend command array.
#   2: The name of the variable that takes 1 when the payload is written.
#   3: The path of the buffered payload.
#   4: 1 when the debug log is on.
#
# Returns:
#   0 on success, COPY_ERR_BACKEND_FAILED when the backend fails.
#######################################
function __cp_run_auto_detect() {
  local -n _auto_command_ref=$1
  local -n _is_written_ref=$2
  local -r buffer_path="$3"
  local -ir is_debug="$4"
  local sniffed_mime=''
  local -i mime_status=0

  _is_written_ref=0
  __cp_sniff_mime sniffed_mime "${buffer_path}" || return
  __cp_debug "${is_debug}" 'auto-detect' "mime=${sniffed_mime}"

  if [[ "${sniffed_mime}" == 'text/plain' ]]; then
    __cp_debug "${is_debug}" 'auto-detect-text' \
      'action=fall-through-to-pipeline'
    exec <"${buffer_path}"
    command rm -f -- "${buffer_path}"

    return 0
  fi

  if ! __cp_apply_mime "$1" "${sniffed_mime}"; then
    mime_status=$?
    command rm -f -- "${buffer_path}"

    return "${mime_status}"
  fi

  __cp_debug "${is_debug}" 'auto-detect-binary' \
    "mime=${sniffed_mime}" 'action=stream-buffer'
  __cp_write_buffer_raw "${buffer_path}" "${_auto_command_ref[@]}" || return
  _is_written_ref=1
}

# endregion Auto-detection orchestration

# region Append prelude

#######################################
# Save the clipboard in a temporary file, for --append.
#
# Arguments:
#   1: The name of the variable that takes the path of the file;
#      it stays empty without --append.
#   2: 1 with --append, 0 without it.
#
# Returns:
#   0 on success, COPY_ERR_BACKEND_FAILED when the clipboard cannot be read.
#######################################
function __cp_capture_prelude() {
  local -n _prelude_path_ref=$1
  local -ir should_append="$2"

  _prelude_path_ref=''
  if ((! should_append)); then
    return 0
  fi

  _prelude_path_ref="$(command mktemp -t copy-append.XXXXXX)" || return
  if ! __cp_read_clipboard >"${_prelude_path_ref}"; then
    command rm -f -- "${_prelude_path_ref}"
    _prelude_path_ref=''
    __cp_fail "${COPY_ERR_BACKEND_FAILED}" \
      'cannot read the clipboard for --append' 'run past alone to see why' \
      || return
  fi
}

#######################################
# Print the saved clipboard, if there is one, and then stdin.
#
# The saved clipboard skips the filters downstream:
# it is the old text, which needs no cleaning;
# only the new payload goes through them.
#
# Arguments:
#   1: The path of the saved clipboard; empty for none.
#
# Inputs:
#   The new payload, on stdin.
#
# Outputs:
#   The old text and the new payload, to stdout.
#######################################
function __cp_stream_with_prelude() {
  local -r prelude_path="$1"

  if [[ -n "${prelude_path}" ]]; then
    command cat -- "${prelude_path}" || return
  fi
  command cat
}

# endregion Append prelude

# region Pipeline runners

#######################################
# Write stdin to the clipboard through the filters, under pipefail.
#
# The pipeline: stdin | __cp_stream_with_prelude | __cp_filter_and_write.
# pipefail stays in the subshell, so the caller's shell keeps its options.
#
# Arguments:
#   1: 1 to keep ANSI escape sequences.
#   2: 1 to trim whitespace.
#   3: The path of the saved clipboard; empty for none.
#   4...: The backend command.
#
# Inputs:
#   The payload, on stdin.
#
# Returns:
#   0 on success, COPY_ERR_BACKEND_FAILED when a stage fails.
#######################################
function __cp_run_pipeline() {
  local -ir is_raw="$1"
  local -ir should_trim="$2"
  local -r prelude_path="$3"
  local -i write_status=0
  shift 3

  (
    set -o pipefail
    __cp_stream_with_prelude "${prelude_path}" \
      | __cp_filter_and_write "${is_raw}" "${should_trim}" "$@"
  ) || write_status=$?

  if ((write_status != 0)); then
    __cp_fail "${COPY_ERR_BACKEND_FAILED}" 'the clipboard backend failed' \
      'see its message above; COPY_PAST_BACKEND picks another backend' \
      || return
  fi
}

#######################################
# Write the words of the text to the clipboard, joined by spaces.
#
# The joined text goes through the same pipeline as a piped payload.
# IFS=' ' stays in a subshell, so the caller keeps its own IFS.
#
# Arguments:
#   1: 1 to keep ANSI escape sequences.
#   2: 1 to trim whitespace.
#   3: The path of the saved clipboard; empty for none.
#   4: The name of the backend command array.
#   5...: The words of the text.
#
# Returns:
#   0 on success, COPY_ERR_USAGE when there are no words,
#   COPY_ERR_BACKEND_FAILED when a stage fails.
#######################################
function __cp_run_argument_mode() {
  local -ir is_raw="$1"
  local -ir should_trim="$2"
  local -r prelude_path="$3"
  local -n _argument_command_ref=$4
  local input_text
  local -i write_status=0
  shift 4

  if (($# == 0)); then
    __cp_usage >&2
    __cp_fail "${COPY_ERR_USAGE}" 'no input' \
      'pass the text as arguments, or pipe it to stdin' \
      || return
  fi

  input_text="$(
    IFS=' '
    echo "$*"
  )"

  (
    set -o pipefail
    printf '%s' "${input_text}" \
      | __cp_stream_with_prelude "${prelude_path}" \
      | __cp_filter_and_write "${is_raw}" "${should_trim}" \
        "${_argument_command_ref[@]}"
  ) || write_status=$?

  if ((write_status != 0)); then
    __cp_fail "${COPY_ERR_BACKEND_FAILED}" 'the clipboard backend failed' \
      'see its message above; COPY_PAST_BACKEND picks another backend' \
      || return
  fi
}

# endregion Pipeline runners

# region Public API

#######################################
# Write text or binary data to the clipboard.
#
# Each step lives in a helper, so the body reads as a list of steps.
# The state lives in this function and goes to the helpers by name,
# so each call starts clean, even in a shell that sourced the file.
#
# Arguments:
#   $@: The options and the words of the text; see __cp_usage.
#
# Inputs:
#   The payload, on stdin, when stdin is no terminal.
#
# Returns:
#   0 on success, or an exit code from the header.
#######################################
function copy() {
  local -A options=()
  local -a positional=() backend_command=()
  local buffer_path='' prelude_path=''
  local -i is_written=0 write_status=0

  __cp_init_options options
  __cp_parse_arguments options positional "$@" || return
  if ((options['should_show_help'])); then
    __cp_usage

    return 0
  fi

  __cp_debug "${options['is_debug']}" 'options-parsed' \
    "raw=${options['is_raw']}" "trim=${options['should_trim']}" \
    "append=${options['should_append']}" \
    "auto=${options['should_detect_mime']}" \
    "mime=${options['mime_type']:-<none>}" \
    "positional-count=${#positional[@]}"

  __cp_validate_options options || return
  __cp_debug "${options['is_debug']}" 'options-validated' \
    "auto=${options['should_detect_mime']}"

  __cp_resolve_backend backend_command "${options['mime_type']}" || return
  __cp_debug "${options['is_debug']}" 'backend-resolved' \
    "backend=${backend_command[0]}"

  # Auto-detection writes a binary payload itself.
  # A text payload goes on to the pipeline through stdin,
  # however the user gave it, so the words of the text are spent.
  if ((options['should_detect_mime'])); then
    __cp_buffer_input buffer_path "${positional[@]}" || return
    __cp_debug "${options['is_debug']}" 'auto-detect-start' \
      "buffer=${buffer_path}"

    __cp_run_auto_detect backend_command is_written "${buffer_path}" \
      "${options['is_debug']}" || return
    if ((is_written)); then
      __cp_debug "${options['is_debug']}" 'done' 'mode=auto-binary'

      return 0
    fi
    positional=()
  fi

  __cp_capture_prelude prelude_path "${options['should_append']}" || return
  if ((options['should_append'])); then
    __cp_debug "${options['is_debug']}" 'prelude-captured' \
      "path=${prelude_path}"
  fi

  if [[ ! -t 0 ]] || ((options['should_detect_mime'])); then
    __cp_debug "${options['is_debug']}" 'pipeline-start' 'mode=pipe'
    __cp_run_pipeline "${options['is_raw']}" "${options['should_trim']}" \
      "${prelude_path}" "${backend_command[@]}" \
      || write_status=$?
  else
    __cp_debug "${options['is_debug']}" 'pipeline-start' 'mode=argument'
    __cp_run_argument_mode "${options['is_raw']}" "${options['should_trim']}" \
      "${prelude_path}" backend_command "${positional[@]}" \
      || write_status=$?
  fi

  if [[ -n "${prelude_path}" ]]; then
    command rm -f -- "${prelude_path}"
  fi

  if ((write_status == 0)); then
    __cp_debug "${options['is_debug']}" 'done' 'mode=pipeline'
  fi

  return "${write_status}"
}

# endregion Public API

# region Execution guard

# Sourced, the file only defines the function copy;
# run as a program, it runs copy in strict mode.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -o errexit -o nounset -o pipefail -o errtrace
  shopt -s inherit_errexit
  trap '__cp_internal_error "$?" "${LINENO}" "${BASH_COMMAND}"' ERR
  trap 'exit 130' INT
  trap 'exit 143' TERM

  copy "$@"
fi

# endregion Execution guard

### End
