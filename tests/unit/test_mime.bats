#!/usr/bin/env bats

# Tests how copy.sh and past.sh choose, check and pass on MIME types.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

# region Image formats

#######################################
# Check that an image format turns into its MIME type.
#
# Arguments:
#   1: The function: __cp_image_format_to_mime or __ps_image_format_to_mime.
#   2: The format.
#   3: The MIME type expected.
#######################################
function image_format_turns_into_its_mime_type() {
  # Arrange: the format is the input.
  local -r mapper="$1"
  local -r image_format="$2"
  local -r expected_mime="$3"
  local mime_type=''

  # Act
  "${mapper}" mime_type "${image_format}"

  # Assert
  [[ "${mime_type}" == "${expected_mime}" ]]
}

# Samples: "format|MIME type"; an unknown format passes on as it is,
# so the backend can refuse it with its own message.
IMAGE_FORMATS=(
  'jpg|image/jpeg'
  'jpeg|image/jpeg'
  'svg|image/svg+xml'
  'png|image/png'
  'webp|image/webp'
  'gif|image/gif'
  'bmp|image/bmp'
  'tiff|image/tiff'
  'avif|image/avif'
)

for mapper_name in __cp_image_format_to_mime __ps_image_format_to_mime; do
  for image_sample in "${IMAGE_FORMATS[@]}"; do
    bats_test_function \
      --description "${mapper_name} turns ${image_sample%%|*} into ${image_sample#*|}" \
      -- image_format_turns_into_its_mime_type "${mapper_name}" \
      "${image_sample%%|*}" "${image_sample#*|}"
  done
done

# endregion Image formats

# region Binary or text

#######################################
# Check that a MIME type counts as binary or as text.
#
# Arguments:
#   1: The predicate: __cp_is_binary_mime or __ps_is_binary_mime.
#   2: The MIME type; it may be empty.
#   3: 0 when the type is binary, 1 when it is text.
#######################################
function mime_type_counts_as_binary_or_text() {
  # Arrange: the MIME type is the input.
  local -r predicate="$1"
  local -r mime_type="$2"
  local -ir expected_status="$3"

  # Act
  run "${predicate}" "${mime_type}"

  # Assert
  ((status == expected_status))
}

for predicate_name in __cp_is_binary_mime __ps_is_binary_mime; do
  for mime_name in image/png image/jpeg image/svg+xml application/octet-stream; do
    bats_test_function \
      --description "${predicate_name} counts ${mime_name} as binary" \
      -- mime_type_counts_as_binary_or_text "${predicate_name}" "${mime_name}" 0
  done
  for mime_name in '' text/plain text/html application/json application/xml; do
    bats_test_function \
      --description "${predicate_name} counts '${mime_name}' as text" \
      -- mime_type_counts_as_binary_or_text "${predicate_name}" "${mime_name}" 1
  done
done

# endregion Binary or text

# region MIME types for the backend

@test "__cp_apply_mime adds --type to wl-copy" {
  # Arrange
  local -a backend_command=(wl-copy)

  # Act
  __cp_apply_mime backend_command 'application/json'

  # Assert
  [[ "${backend_command[*]}" == 'wl-copy --type application/json' ]]
}

@test "__cp_apply_mime adds -t to xclip after its own options" {
  # Arrange
  local -a backend_command=(xclip -selection clipboard -in)

  # Act
  __cp_apply_mime backend_command 'text/html'

  # Assert
  [[ "${backend_command[*]}" == 'xclip -selection clipboard -in -t text/html' ]]
}

@test "__ps_apply_mime adds --type to wl-paste" {
  # Arrange
  local -a backend_command=(wl-paste)

  # Act
  __ps_apply_mime backend_command 'image/png'

  # Assert
  [[ "${backend_command[*]}" == 'wl-paste --type image/png' ]]
}

@test "__ps_apply_mime adds -t to xclip after its own options" {
  # Arrange
  local -a backend_command=(xclip -selection clipboard -out)

  # Act
  __ps_apply_mime backend_command 'application/json'

  # Assert
  [[ "${backend_command[*]}" == 'xclip -selection clipboard -out -t application/json' ]]
}

#######################################
# Check that xsel refuses every MIME type, text ones too:
# a user who names a type wants a typed write.
#
# Arguments:
#   1: The function: __cp_apply_mime or __ps_apply_mime.
#   2: The name of the code expected, such as COPY_ERR_TYPE_MISMATCH.
#   3: The MIME type.
#######################################
function xsel_refuses_a_mime_type() {
  # Arrange
  local -r applier="$1"
  local -ir expected_code="${!2}"
  local -r mime_type="$3"
  local -a backend_command=(xsel --clipboard --input)

  # Act
  run --separate-stderr "${applier}" backend_command "${mime_type}"

  # Assert
  ((status == expected_code))
  [[ "${stderr}" == *'xsel does not support MIME types'* ]]
}

for mime_name in text/html image/png; do
  bats_test_function \
    --description "__cp_apply_mime refuses ${mime_name} for xsel" \
    -- xsel_refuses_a_mime_type __cp_apply_mime COPY_ERR_TYPE_MISMATCH "${mime_name}"
  bats_test_function \
    --description "__ps_apply_mime refuses ${mime_name} for xsel" \
    -- xsel_refuses_a_mime_type __ps_apply_mime PAST_ERR_TYPE_MISMATCH "${mime_name}"
done

# endregion MIME types for the backend

# region Sniffing

#######################################
# Check that the first bytes of a payload give its MIME type.
#
# Arguments:
#   1: The bytes, as hex.
#   2: The MIME type expected.
#######################################
function magic_bytes_give_the_mime_type() {
  # Arrange
  local -r payload_hex="$1"
  local -r expected_mime="$2"
  local -r payload_path="${BATS_TEST_TMPDIR}/payload.bin"
  local mime_type=''
  xxd -r -p <<<"${payload_hex}" >"${payload_path}"

  # Act
  __cp_sniff_mime mime_type "${payload_path}"

  # Assert
  [[ "${mime_type}" == "${expected_mime}" ]]
}

# Samples: "hex|MIME type|name"; WebP is RIFF, a size and WEBP.
MAGIC_BYTES=(
  '89504E470D0A1A0A|image/png|PNG'
  'FFD8FFE0|image/jpeg|JPEG'
  '47494638|image/gif|GIF'
  '424D|image/bmp|BMP'
  '52494646100000005745425065787472|image/webp|WebP'
)

for magic_sample in "${MAGIC_BYTES[@]}"; do
  magic_rest="${magic_sample#*|}"
  bats_test_function --description \
    "__cp_sniff_mime reads the magic bytes of ${magic_sample##*|} as ${magic_rest%%|*}" \
    -- magic_bytes_give_the_mime_type "${magic_sample%%|*}" "${magic_rest%%|*}"
done

@test "__cp_sniff_mime reads plain text as text/plain" {
  # Arrange
  local -r payload_path="${BATS_TEST_TMPDIR}/plain.txt"
  local mime_type=''
  printf 'just some text\n' >"${payload_path}"

  # Act
  __cp_sniff_mime mime_type "${payload_path}"

  # Assert
  [[ "${mime_type}" == 'text/plain' ]]
}

#######################################
# Check what JSON detection makes of a payload; it needs jq.
#
# Arguments:
#   1: The payload, as printf prints it with %b.
#   2: The MIME type expected.
#######################################
function json_detection_reads_the_payload() {
  # Arrange
  local -r payload="$1"
  local -r expected_mime="$2"
  local -r payload_path="${BATS_TEST_TMPDIR}/payload.txt"
  local mime_type=''
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed; JSON detection needs it'
  fi
  printf '%b' "${payload}" >"${payload_path}"

  # Act
  __cp_sniff_mime mime_type "${payload_path}"

  # Assert
  [[ "${mime_type}" == "${expected_mime}" ]]
}

bats_test_function \
  --description "__cp_sniff_mime reads valid JSON as application/json" \
  -- json_detection_reads_the_payload '{"hello":"world"}' 'application/json'
bats_test_function \
  --description "__cp_sniff_mime reads a JSON array as application/json" \
  -- json_detection_reads_the_payload '[1, 2, 3]' 'application/json'
bats_test_function \
  --description "__cp_sniff_mime keeps text/plain for a brace that jq cannot parse" \
  -- json_detection_reads_the_payload '{ trap cleanup EXIT; }' 'text/plain'
bats_test_function \
  --description "__cp_sniff_mime keeps text/plain when text comes before a brace" \
  -- json_detection_reads_the_payload 'value: {"a":1}' 'text/plain'
bats_test_function \
  --description "__cp_sniff_mime keeps text/plain for JSON after a NUL byte" \
  -- json_detection_reads_the_payload '\0{"a":1}' 'text/plain'

@test "__cp_sniff_mime finds JSON after any run of leading whitespace" {
  # Arrange:
  # the first byte that is not whitespace decides,
  # however far into the payload it comes.
  local -r payload_path="${BATS_TEST_TMPDIR}/padded.json"
  local mime_type=''
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed; JSON detection needs it'
  fi
  {
    printf ' \t\r\n'
    printf '%10000s' ''
    printf '%s' '{"padded":true}'
  } >"${payload_path}"

  # Act
  __cp_sniff_mime mime_type "${payload_path}"

  # Assert
  [[ "${mime_type}" == 'application/json' ]]
}

# endregion Sniffing

# region Backends with a MIME type

@test "__cp_resolve_backend takes wl-copy under Wayland and adds the MIME type" {
  # Arrange
  local -a backend_command=()

  # Act
  __cp_resolve_backend backend_command 'application/json'

  # Assert
  [[ "${backend_command[*]}" == 'wl-copy --type application/json' ]]
}

@test "__cp_resolve_backend refuses a binary MIME type for xsel" {
  # Arrange:
  # COPY_PAST_BACKEND picks xsel on any host;
  # CI has a real xclip, which detection would pick first.
  # The MIME type fails before xsel runs, so the fake only has to exist.
  local -a backend_command=()
  enable_fake_xsel
  export COPY_PAST_BACKEND=xsel

  # Act
  run --separate-stderr __cp_resolve_backend backend_command 'image/png'

  # Assert
  ((status == COPY_ERR_TYPE_MISMATCH))
}

@test "__ps_resolve_backend takes wl-paste under Wayland and adds the MIME type" {
  # Arrange
  local -a backend_command=()

  # Act
  __ps_resolve_backend backend_command 'application/json'

  # Assert
  [[ "${backend_command[*]}" == 'wl-paste --type application/json' ]]
}

# endregion Backends with a MIME type

### End
