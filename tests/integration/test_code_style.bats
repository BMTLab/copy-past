#!/usr/bin/env bats

# Tests that copy.sh and past.sh follow the BMTLab shell style.

bats_require_minimum_version 1.11.0

load '../support/test_helper.bash'

# region Helpers

#######################################
# Print the header card of a script: its comment block after the shebang.
#
# Arguments:
#   1: The path of the script.
#
# Outputs:
#   The lines from the third one up to the first line that is no comment.
#######################################
function print_header() {
  local -r script_path="$1"
  local -a lines=()
  local line

  mapfile -t lines <"${script_path}"

  for line in "${lines[@]:2}"; do
    if [[ "${line}" != '#'* ]]; then
      break
    fi
    printf '%s\n' "${line}"
  done
}

#######################################
# Print each violation to stderr and fail, if there is any.
#
# Arguments:
#   1: What the violations break.
#   2...: The violations.
#
# Returns:
#   1 when there is a violation, 0 otherwise.
#######################################
function report_violations() {
  local -r rule="$1"
  shift

  if (($# == 0)); then
    return 0
  fi

  printf '%s:\n' "${rule}" >&2
  printf '  - %s\n' "$@" >&2

  return 1
}

# endregion Helpers

# region Tools

#######################################
# Check that bash reads a script without a syntax error.
#
# Arguments:
#   1: The file name of the script, such as copy.sh.
#######################################
function script_passes_bash_syntax_check() {
  local -r script_path="${COPY_PAST_ROOT}/$1"

  # Arrange: the script is the input.

  # Act
  run --separate-stderr bash -n "${script_path}"

  # Assert
  ((status == 0))
}

#######################################
# Check that shellcheck finds nothing in a script,
# with the rules of .shellcheckrc.
#
# Arguments:
#   1: The file name of the script.
#######################################
function script_passes_shellcheck() {
  local -r script_path="${COPY_PAST_ROOT}/$1"

  # Arrange
  if ! command -v shellcheck >/dev/null 2>&1; then
    skip 'shellcheck not installed'
  fi

  # Act
  run --separate-stderr shellcheck "${script_path}"

  # Assert
  printf '%s\n' "${output}" >&2
  ((status == 0))
}

#######################################
# Check that shfmt would not change a script.
#
# Arguments:
#   1: The file name of the script.
#######################################
function script_passes_shfmt() {
  local -r script_path="${COPY_PAST_ROOT}/$1"

  # Arrange
  if ! command -v shfmt >/dev/null 2>&1; then
    skip 'shfmt not installed'
  fi

  # Act
  run --separate-stderr shfmt -d -i 2 -ci -bn "${script_path}"

  # Assert
  printf '%s\n' "${output}" >&2
  ((status == 0))
}

# endregion Tools

# region Header card

#######################################
# Check that a script starts with the env shebang,
# and its header with one sentence.
#
# Arguments:
#   1: The file name of the script.
#######################################
function script_opens_with_shebang_and_sentence() {
  local -r script_path="${COPY_PAST_ROOT}/$1"
  local -a first_lines=()

  # Arrange
  mapfile -t -n 4 first_lines <"${script_path}"

  # Act: the first four lines are the input.

  # Assert
  [[ "${first_lines[0]}" == '#!/usr/bin/env bash' ]]
  [[ -z "${first_lines[1]}" ]]
  [[ "${first_lines[2]}" =~ ^#\ [A-Z].*\.$ ]]
  [[ "${first_lines[3]}" == '#' ]]
}

#######################################
# Check that the keys of a header card come in the order of the rule,
# from Usage to Version, and that Version closes the card.
#
# Arguments:
#   1: The file name of the script.
#######################################
function header_keeps_the_keys_in_order() {
  local -r script_path="${COPY_PAST_ROOT}/$1"
  local -ra rule_keys=(
    'Usage' 'Effects' 'Dependencies' 'Settings'
    'Exit codes' 'See' 'How it works' 'Version'
  )
  local -a header_lines=() header_keys=() keys_in_rule_order=()
  local line key header_list rule_list

  # Arrange
  mapfile -t header_lines < <(print_header "${script_path}")

  # Act: the keys as the header has them, and as the rule orders them.
  for line in "${header_lines[@]}"; do
    for key in "${rule_keys[@]}"; do
      if [[ "${line}" == "# ${key}:"* ]]; then
        header_keys+=("${key}")
      fi
    done
  done
  printf -v header_list '%s|' "${header_keys[@]}"
  for key in "${rule_keys[@]}"; do
    if [[ "|${header_list}" == *"|${key}|"* ]]; then
      keys_in_rule_order+=("${key}")
    fi
  done
  printf -v rule_list '%s|' "${keys_in_rule_order[@]}"

  # Assert
  [[ "${header_list}" == "${rule_list}" ]]
  [[ "${header_list}" == 'Usage|'*'Exit codes|'* ]]
  [[ "${header_lines[-1]}" =~ ^#\ Version:\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

#######################################
# Check that each exit code of a script is named in its header card,
# in its --help, and in a table of exit codes in the README.
#
# Arguments:
#   1: The file name of the script.
#######################################
function exit_codes_are_documented() {
  local -r script_path="${COPY_PAST_ROOT}/$1"
  local -a codes=() violations=()
  local header help_text readme code name value row_pattern help_pattern

  # Arrange
  header="$(print_header "${script_path}")"
  header="${header//$'\n#   '/ }"
  help_text="$(bash "${script_path}" --help)"
  readme="$(<"${COPY_PAST_ROOT}/README.md")"
  mapfile -t codes < <(
    sed -n -E 's/^ *readonly ([A-Z]+_ERR_[A-Z_]+)=([0-9]+)$/\1=\2/p' "${script_path}"
  )

  # Act
  for code in "${codes[@]}"; do
    name="${code%=*}"
    value="${code#*=}"
    if [[ "${header}" != *" ${value} ${name}"[,.]* ]]; then
      violations+=("${value} ${name}: missing from the header card")
    fi
    help_pattern="(^|"$'\n'")  ${value} +${name}:"
    if [[ ! "${help_text}" =~ ${help_pattern} ]]; then
      violations+=("${value} ${name}: missing from --help")
    fi
    row_pattern="\\| +\`${value}\` +\\| +\`${name}\` +\\|"
    if [[ ! "${readme}" =~ ${row_pattern} ]]; then
      violations+=("${value} ${name}: missing from the tables of README.md")
    fi
  done

  # Assert
  ((${#codes[@]} > 0))
  report_violations 'exit codes' "${violations[@]}"
}

#######################################
# Check that a script ends with the execution guard and ### End.
#
# Arguments:
#   1: The file name of the script.
#######################################
function script_ends_with_the_guard() {
  local -r script_path="${COPY_PAST_ROOT}/$1"
  local -a lines=()

  # Arrange
  mapfile -t lines <"${script_path}"

  # Act: the last lines are the input.

  # Assert
  [[ "${lines[-1]}" == '### End' ]]
  [[ "${lines[-3]}" == '# endregion Execution guard' ]]
  grep -qxF 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "${script_path}"
}

# endregion Header card

for script_name in copy.sh past.sh; do
  bats_test_function --description "${script_name} passes bash -n" \
    -- script_passes_bash_syntax_check "${script_name}"
  bats_test_function --description "${script_name} passes shellcheck" \
    -- script_passes_shellcheck "${script_name}"
  bats_test_function --description "${script_name} passes shfmt -d" \
    -- script_passes_shfmt "${script_name}"
  bats_test_function \
    --description "${script_name} starts with the env shebang and one sentence" \
    -- script_opens_with_shebang_and_sentence "${script_name}"
  bats_test_function \
    --description "${script_name} keeps the keys of its header card in order" \
    -- header_keeps_the_keys_in_order "${script_name}"
  bats_test_function \
    --description "${script_name} names each exit code in its header, help and README" \
    -- exit_codes_are_documented "${script_name}"
  bats_test_function \
    --description "${script_name} ends with the execution guard and ### End" \
    -- script_ends_with_the_guard "${script_name}"
done

### End
