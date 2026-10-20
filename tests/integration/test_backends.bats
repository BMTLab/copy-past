#!/usr/bin/env bats

# Tests what each clipboard backend can do, as the README matrix promises.

# This file is the matrix in code:
# when a backend gains or loses a feature, the matrix and its test change together.
#
#   | Feature               | wl-clipboard | xclip | xsel |
#   | --------------------- | :----------: | :---: | :--: |
#   | plain text round trip |      yes     |  yes  |  yes |
#   | --type MIME           |      yes     |  yes  |  no  |
#   | --json (text MIME)    |      yes     |  yes  |  no  |
#   | --image (binary MIME) |      yes     |  yes  |  no  |
#   | newline fix of past   |      yes     |  no   |  no  |
#
# COPY_PAST_BACKEND picks each backend, so the host does not matter.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
  enable_fake_xclip
  enable_fake_xsel
}

# region COPY_PAST_BACKEND

#######################################
# Check that a value of COPY_PAST_BACKEND picks its backend for copy.
#
# Arguments:
#   1: The value of COPY_PAST_BACKEND.
#   2: The backend command expected.
#######################################
function backend_value_picks_its_backend() {
  local -r backend_value="$1"
  local -r expected_backend="$2"
  local -r payload="via ${backend_value}"

  # Arrange: the value of COPY_PAST_BACKEND is the input.

  # Act
  run --separate-stderr run_snippet '
    export COPY_PAST_BACKEND="$1"
    printf "%s" "$2" | copy --debug
  ' "${backend_value}" "${payload}"

  # Assert
  ((status == 0))
  assert_debug_event 'backend-resolved' "backend=${expected_backend}"
  [[ "$(print_clipboard)" == "${payload}" ]]
}

# Samples: "value|backend"; wayland and wl-copy name wl-clipboard too.
BACKEND_VALUES=(
  'wl-clipboard|wl-copy'
  'wayland|wl-copy'
  'wl-copy|wl-copy'
  'xclip|xclip'
  'xsel|xsel'
)

for backend_sample in "${BACKEND_VALUES[@]}"; do
  bats_test_function \
    --description "COPY_PAST_BACKEND=${backend_sample%%|*} makes copy run ${backend_sample#*|}" \
    -- backend_value_picks_its_backend "${backend_sample%%|*}" "${backend_sample#*|}"
done

@test "COPY_PAST_BACKEND=bogus is a usage error for copy" {
  # Arrange: bogus names no backend.

  # Act
  run --separate-stderr run_snippet '
    export COPY_PAST_BACKEND=bogus
    printf "%s" x | copy --no-auto
  '

  # Assert
  ((status == COPY_ERR_USAGE))
  [[ "${stderr}" == *'unknown COPY_PAST_BACKEND'* ]]
}

@test "COPY_PAST_BACKEND=bogus is a usage error for past" {
  # Arrange: bogus names no backend.

  # Act
  run --separate-stderr run_snippet '
    export COPY_PAST_BACKEND=bogus
    past
  '

  # Assert
  ((status == PAST_ERR_USAGE))
  [[ "${stderr}" == *'unknown COPY_PAST_BACKEND'* ]]
}

@test "COPY_PAST_BACKEND=xclip without xclip reports a missing backend" {
  local prelude bash_path

  # Arrange:
  # PATH holds only the fakes, without xclip,
  # so an xclip of the host cannot answer for the fake.
  prelude="$(print_snippet_prelude copy.sh)"
  bash_path="$(command -v bash)"
  rm -f -- "${FAKE_BIN}/xclip"

  # Act
  run --separate-stderr env -i HOME="${HOME}" PATH="${FAKE_BIN}" \
    COPY_PAST_BACKEND=xclip \
    "${bash_path}" -c "${prelude}"$'\n''printf x | copy' \
    no-xclip "${COPY_PAST_ROOT}"

  # Assert
  ((status == COPY_ERR_NO_BACKEND))
  [[ "${stderr}" == *'no clipboard backend found'* ]]
}

# endregion COPY_PAST_BACKEND

# region Plain text, on every backend

#######################################
# Check that a backend makes a round trip of plain text:
# all fakes share one clipboard file.
#
# Arguments:
#   1: The value of COPY_PAST_BACKEND.
#######################################
function backend_round_trips_plain_text() {
  local -r backend_value="$1"
  local -r payload="round-trip-${backend_value}"

  # Arrange: the value of COPY_PAST_BACKEND is the input.

  # Act
  run --separate-stderr run_snippet '
    export COPY_PAST_BACKEND="$1"
    printf "%s" "$2" | copy
    past
  ' "${backend_value}" "${payload}"

  # Assert
  ((status == 0))
  [[ "${output}" == "${payload}" ]]
}

for backend_name in wl-clipboard xclip xsel; do
  bats_test_function \
    --description "${backend_name} makes a round trip of plain text" \
    -- backend_round_trips_plain_text "${backend_name}"
done

# endregion Plain text, on every backend

# region MIME types, on wl-clipboard and xclip

#######################################
# Check that a backend with MIME types takes a MIME flag of copy.
#
# Arguments:
#   1: The value of COPY_PAST_BACKEND.
#   2: The flag: --json or --image.
#   3: The MIME type expected.
#######################################
function backend_takes_a_mime_flag() {
  local -r backend_value="$1"
  local -r flag="$2"
  local -r expected_mime="$3"

  # Arrange:
  # an explicit flag decides the MIME type, so the payload does not matter.

  # Act
  run --separate-stderr run_snippet '
    export COPY_PAST_BACKEND="$1"
    printf "%s" "{\"k\":1}" | copy --debug "$2"
  ' "${backend_value}" "${flag}"

  # Assert
  ((status == 0))
  assert_debug_event 'options-parsed' "mime=${expected_mime}"
}

for backend_name in wl-clipboard xclip; do
  bats_test_function --description "${backend_name} takes copy --json" \
    -- backend_takes_a_mime_flag "${backend_name}" --json application/json
  bats_test_function --description "${backend_name} takes copy --image" \
    -- backend_takes_a_mime_flag "${backend_name}" --image image/png
done

# endregion MIME types, on wl-clipboard and xclip

# region No MIME types on xsel

#######################################
# Check that xsel refuses a MIME flag of copy with the type-mismatch code.
#
# Arguments:
#   1: The flag: --json or --image.
#######################################
function xsel_refuses_a_copy_mime_flag() {
  local -r flag="$1"

  # Arrange: the flag is the input.

  # Act
  run --separate-stderr run_snippet '
    export COPY_PAST_BACKEND=xsel
    printf "%s" x | copy "$1"
  ' "${flag}"

  # Assert
  ((status == COPY_ERR_TYPE_MISMATCH))
  [[ "${stderr}" == *'xsel does not support MIME types'* ]]
}

for flag_name in --json --image; do
  bats_test_function --description "xsel refuses copy ${flag_name}" \
    -- xsel_refuses_a_copy_mime_flag "${flag_name}"
done

@test "xsel refuses past --type with the type-mismatch code" {
  # Arrange
  set_clipboard 'data'

  # Act
  run --separate-stderr run_snippet '
    export COPY_PAST_BACKEND=xsel
    past --type application/json
  '

  # Assert
  ((status == PAST_ERR_TYPE_MISMATCH))
  [[ "${stderr}" == *'xsel does not support MIME types'* ]]
}

# endregion No MIME types on xsel

# region The newline fix of wl-paste

#######################################
# Check how past reads: wl-paste with a text type needs the newline fix,
# while wl-paste with a binary type, xclip and xsel run as they are.
#
# Arguments:
#   1: The value of COPY_PAST_BACKEND.
#   2: The way of reading expected, as the debug log names it.
#   3...: The options of past.
#######################################
function past_reads_the_way_of_its_backend() {
  local -r backend_value="$1"
  local -r expected_mode="$2"

  # Arrange:
  # stdout goes away, so binary output stays out of the test log.
  set_clipboard 'placeholder'

  # Act
  run --separate-stderr run_snippet '
    export COPY_PAST_BACKEND="$1"
    shift
    past --debug "$@" >/dev/null
  ' "${backend_value}" "${@:3}"

  # Assert
  ((status == 0))
  assert_debug_event 'read-strategy' "mode=${expected_mode}"
}

bats_test_function \
  --description "past fixes the newline of wl-paste for text" \
  -- past_reads_the_way_of_its_backend wl-clipboard wl-paste-newline-strip
bats_test_function \
  --description "past runs wl-paste as it is for an image" \
  -- past_reads_the_way_of_its_backend wl-clipboard direct-exec --image
bats_test_function \
  --description "past runs xclip as it is" \
  -- past_reads_the_way_of_its_backend xclip direct-exec
bats_test_function \
  --description "past runs xsel as it is" \
  -- past_reads_the_way_of_its_backend xsel direct-exec

# endregion The newline fix of wl-paste

### End
