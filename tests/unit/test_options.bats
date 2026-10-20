#!/usr/bin/env bats

# Tests how copy.sh and past.sh read and check their options.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

function setup() {
  setup_fake_backends
  load_scripts
}

# region Defaults

@test "__cp_init_options sets every option of copy to its default" {
  local -A options=(
    ['is_raw']=9 ['should_trim']=9 ['should_append']=9
    ['should_detect_mime']=9 ['is_debug']=9 ['should_show_help']=9
    ['mime_type']='dirty'
  )

  # Arrange: every option starts with a wrong value.

  # Act
  __cp_init_options options

  # Assert
  ((options['is_raw'] == 0))
  ((options['should_trim'] == 0))
  ((options['should_append'] == 0))
  ((options['should_detect_mime'] == 1))
  ((options['is_debug'] == 0))
  ((options['should_show_help'] == 0))
  [[ -z "${options['mime_type']}" ]]
}

@test "__ps_init_options sets every option of past to its default" {
  local -A options=(
    ['is_debug']=9 ['should_show_help']=9 ['mime_type']='dirty'
  )

  # Arrange: every option starts with a wrong value.

  # Act
  __ps_init_options options

  # Assert
  ((options['is_debug'] == 0))
  ((options['should_show_help'] == 0))
  [[ -z "${options['mime_type']}" ]]
}

# endregion Defaults

# region --type

#######################################
# Check that a --type flag gives its MIME type
# and uses the right number of arguments.
#
# Arguments:
#   1: The parser: __cp_parse_type_flag or __ps_parse_type_flag.
#   2: The MIME type expected.
#   3: How many arguments the flag uses.
#   4...: The flag, and the argument after it, if any.
#######################################
function type_flag_gives_its_mime_type() {
  local -r parser="$1"
  local -r expected_mime="$2"
  local -ir expected_count="$3"
  local -A options=(['mime_type']='')
  local -i used_count=0
  shift 3

  # Arrange: the flag and its argument are the input.

  # Act
  "${parser}" options used_count "$@"

  # Assert
  [[ "${options['mime_type']}" == "${expected_mime}" ]]
  ((used_count == expected_count))
}

#######################################
# Check that a --type flag without a MIME type is a usage error.
#
# Arguments:
#   1: The parser: __cp_parse_type_flag or __ps_parse_type_flag.
#   2: The name of the usage code, COPY_ERR_USAGE or PAST_ERR_USAGE.
#   3...: The flag, and the argument after it, if any.
#######################################
function type_flag_refuses_an_empty_mime_type() {
  local -r parser="$1"
  local -r usage_code_name="$2"
  local -ir usage_code="${!usage_code_name}"
  local -A options=(['mime_type']='')
  local -i used_count=0
  shift 2

  # Arrange: the flag without a MIME type is the input.

  # Act
  run --separate-stderr "${parser}" options used_count "$@"

  # Assert
  ((status == usage_code))
  [[ "${stderr}" == *'--type requires a MIME type'* ]]
}

for tool_prefix in cp:COPY ps:PAST; do
  parser_name="__${tool_prefix%%:*}_parse_type_flag"
  usage_name="${tool_prefix#*:}_ERR_USAGE"
  bats_test_function \
    --description "${parser_name} reads --type=text/html as one argument" \
    -- type_flag_gives_its_mime_type "${parser_name}" 'text/html' 1 \
    '--type=text/html'
  bats_test_function \
    --description "${parser_name} reads --type application/xml as two arguments" \
    -- type_flag_gives_its_mime_type "${parser_name}" 'application/xml' 2 \
    '--type' 'application/xml'
  bats_test_function \
    --description "${parser_name} refuses --type without a value" \
    -- type_flag_refuses_an_empty_mime_type "${parser_name}" "${usage_name}" \
    '--type'
  bats_test_function \
    --description "${parser_name} refuses --type= with an empty value" \
    -- type_flag_refuses_an_empty_mime_type "${parser_name}" "${usage_name}" \
    '--type='
done

# endregion --type

# region --image

#######################################
# Check that an --image flag gives the MIME type of its format.
#
# Arguments:
#   1: The parser: __cp_parse_image_flag or __ps_parse_image_flag.
#   2: The flag.
#   3: The MIME type expected.
#######################################
function image_flag_gives_its_mime_type() {
  local -r parser="$1"
  local -r flag="$2"
  local -r expected_mime="$3"
  local -A options=(['mime_type']='' ['is_raw']=0)

  # Arrange: the flag is the input.

  # Act
  "${parser}" options "${flag}"

  # Assert
  [[ "${options['mime_type']}" == "${expected_mime}" ]]
}

for parser_name in __cp_parse_image_flag __ps_parse_image_flag; do
  bats_test_function --description "${parser_name} reads --image as image/png" \
    -- image_flag_gives_its_mime_type "${parser_name}" '--image' 'image/png'
  bats_test_function \
    --description "${parser_name} reads --image=jpg as image/jpeg" \
    -- image_flag_gives_its_mime_type "${parser_name}" '--image=jpg' 'image/jpeg'
  bats_test_function \
    --description "${parser_name} reads --image=svg as image/svg+xml" \
    -- image_flag_gives_its_mime_type "${parser_name}" '--image=svg' 'image/svg+xml'
done

@test "__cp_parse_image_flag keeps an image payload raw" {
  local -A options=(['mime_type']='' ['is_raw']=0)

  # Arrange: the options start without a MIME type.

  # Act
  __cp_parse_image_flag options '--image'

  # Assert
  ((options['is_raw'] == 1))
}

@test "__cp_parse_image_flag refuses --image= and leaves the options alone" {
  local -A options=(['mime_type']='' ['is_raw']=0)
  local -r stderr_path="${BATS_TEST_TMPDIR}/stderr"
  local -i code=0

  # Arrange:
  # the call runs in this shell, not through run,
  # so the test sees what it does to the options.

  # Act
  __cp_parse_image_flag options '--image=' 2>"${stderr_path}" || code=$?

  # Assert
  ((code == COPY_ERR_USAGE))
  [[ "$(<"${stderr_path}")" == *'--image=FORMAT requires a format'* ]]
  ((options['is_raw'] == 0))
  [[ -z "${options['mime_type']}" ]]
}

# endregion --image

# region The command line of copy

@test "__cp_parse_arguments reads every option of a full command line" {
  local -A options=()
  local -a positional=()

  # Arrange
  __cp_init_options options

  # Act
  __cp_parse_arguments options positional \
    --raw --trim -a --debug --type=text/markdown -- leftover words

  # Assert
  ((options['is_raw'] == 1))
  ((options['should_trim'] == 1))
  ((options['should_append'] == 1))
  ((options['is_debug'] == 1))
  [[ "${options['mime_type']}" == 'text/markdown' ]]
  [[ "${positional[*]}" == 'leftover words' ]]
}

@test "__cp_parse_arguments reads --type MIME across two arguments" {
  local -A options=()
  local -a positional=()

  # Arrange
  __cp_init_options options

  # Act
  __cp_parse_arguments options positional --type text/html hello

  # Assert
  [[ "${options['mime_type']}" == 'text/html' ]]
  [[ "${positional[*]}" == 'hello' ]]
}

#######################################
# Check that a JSON flag of copy sets application/json and keeps it raw,
# and leaves auto-detection to the check of the options.
#
# Arguments:
#   1: The flag: -j or --json.
#######################################
function json_flag_sets_json_and_raw() {
  local -r flag="$1"
  local -A options=()
  local -a positional=()

  # Arrange
  __cp_init_options options

  # Act
  __cp_parse_arguments options positional "${flag}"

  # Assert
  [[ "${options['mime_type']}" == 'application/json' ]]
  ((options['is_raw'] == 1))
  ((options['should_detect_mime'] == 1))
}

for flag_name in -j --json; do
  bats_test_function \
    --description "__cp_parse_arguments reads ${flag_name} as application/json, raw" \
    -- json_flag_sets_json_and_raw "${flag_name}"
done

@test "__cp_parse_arguments takes the words after -- as text" {
  local -A options=()
  local -a positional=()

  # Arrange
  __cp_init_options options

  # Act
  __cp_parse_arguments options positional -- --not-a-flag

  # Assert
  [[ "${positional[*]}" == '--not-a-flag' ]]
  ((options['is_raw'] == 0))
}

@test "__cp_parse_arguments refuses an unknown option with the usage code" {
  local -A options=()
  local -a positional=()

  # Arrange
  __cp_init_options options

  # Act
  run --separate-stderr __cp_parse_arguments options positional --bogus

  # Assert
  ((status == COPY_ERR_USAGE))
  [[ "${stderr}" == *'unknown option: --bogus'* ]]
}

@test "__cp_parse_arguments stops at --help and asks for the help" {
  local -A options=()
  local -a positional=()

  # Arrange:
  # --bogus after --help would be an error,
  # so success shows that the parsing stops at --help.
  __cp_init_options options

  # Act
  __cp_parse_arguments options positional --help --bogus

  # Assert
  ((options['should_show_help'] == 1))
}

# endregion The command line of copy

# region The command line of past

@test "__ps_parse_arguments reads --json and --debug" {
  local -A options=()

  # Arrange
  __ps_init_options options

  # Act
  __ps_parse_arguments options --json --debug

  # Assert
  [[ "${options['mime_type']}" == 'application/json' ]]
  ((options['is_debug'] == 1))
}

@test "__ps_parse_arguments stops at --help and asks for the help" {
  local -A options=()

  # Arrange
  __ps_init_options options

  # Act
  __ps_parse_arguments options --help stray-word

  # Assert
  ((options['should_show_help'] == 1))
}

@test "__ps_parse_arguments refuses a word that is no option with the usage code" {
  local -A options=()

  # Arrange
  __ps_init_options options

  # Act
  run --separate-stderr __ps_parse_arguments options stray-word

  # Assert
  ((status == PAST_ERR_USAGE))
  [[ "${stderr}" == *'unknown argument: stray-word'* ]]
}

# endregion The command line of past

# region The debug flags

#######################################
# Check that a debug flag of copy turns on the debug log.
#
# Arguments:
#   1: The flag: -d, --debug or --verbose.
#######################################
function copy_debug_flag_turns_on_the_log() {
  local -r flag="$1"
  local -A options=()
  local -a positional=()

  # Arrange
  __cp_init_options options

  # Act
  __cp_parse_arguments options positional "${flag}"

  # Assert
  ((options['is_debug'] == 1))
}

#######################################
# Check that a debug flag of past turns on the debug log.
#
# Arguments:
#   1: The flag: -d, --debug or --verbose.
#######################################
function past_debug_flag_turns_on_the_log() {
  local -r flag="$1"
  local -A options=()

  # Arrange
  __ps_init_options options

  # Act
  __ps_parse_arguments options "${flag}"

  # Assert
  ((options['is_debug'] == 1))
}

for flag_name in -d --debug --verbose; do
  bats_test_function \
    --description "__cp_parse_arguments reads ${flag_name} as the debug flag" \
    -- copy_debug_flag_turns_on_the_log "${flag_name}"
  bats_test_function \
    --description "__ps_parse_arguments reads ${flag_name} as the debug flag" \
    -- past_debug_flag_turns_on_the_log "${flag_name}"
done

# endregion The debug flags

# region The check of the options

#######################################
# Check that an option for text refuses a binary MIME type.
#
# Arguments:
#   1: The option: should_append or should_trim.
#   2: The binary MIME type.
#   3: The text of the message expected.
#######################################
function text_option_refuses_binary_mime() {
  local -r option_key="$1"
  local -r mime_type="$2"
  local -r expected_message="$3"
  local -A options=()

  # Arrange
  __cp_init_options options
  options["${option_key}"]=1
  options['mime_type']="${mime_type}"

  # Act
  run --separate-stderr __cp_validate_options options

  # Assert
  ((status == COPY_ERR_TYPE_MISMATCH))
  [[ "${stderr}" == *"${expected_message}"* ]]
}

for mime_name in image/png application/octet-stream; do
  bats_test_function \
    --description "__cp_validate_options refuses --append with ${mime_name}" \
    -- text_option_refuses_binary_mime 'should_append' "${mime_name}" \
    '--append is only valid for text payloads'
  bats_test_function \
    --description "__cp_validate_options refuses --trim with ${mime_name}" \
    -- text_option_refuses_binary_mime 'should_trim' "${mime_name}" \
    '--trim is only valid for text payloads'
done

@test "__cp_validate_options turns auto-detection off for an explicit MIME type" {
  local -A options=()

  # Arrange
  __cp_init_options options
  options['mime_type']='application/json'

  # Act
  __cp_validate_options options

  # Assert
  ((options['should_detect_mime'] == 0))
}

@test "__cp_validate_options turns auto-detection off for --append" {
  local -A options=()

  # Arrange
  __cp_init_options options
  options['should_append']=1

  # Act
  __cp_validate_options options

  # Assert
  ((options['should_detect_mime'] == 0))
}

@test "__cp_validate_options keeps auto-detection on for plain options" {
  local -A options=()

  # Arrange
  __cp_init_options options

  # Act
  __cp_validate_options options

  # Assert
  ((options['should_detect_mime'] == 1))
}

# endregion The check of the options

### End
