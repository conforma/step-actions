#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

shellspec_syntax 'shellspec_subject_taskrun'

shellspec_subject_taskrun() {
  # shellcheck disable=SC2034
  SHELLSPEC_META='text'
  SHELLSPEC_STDOUT=$(<"${SHELLSPEC_STDOUT_FILE}")
  if [ ${SHELLSPEC_STDOUT+x} ]; then
    local task_run_name=""
    # Extract the TaskRun name via regex so we don't depend on exact
    # token positions — handles extra whitespace or prefixed output.
    if [[ "${SHELLSPEC_STDOUT}" =~ TaskRun\ started:\ ([^[:space:]]+) ]]; then
      task_run_name="${BASH_REMATCH[1]}"
    fi

    if [ -n "${task_run_name}" ]; then
      local attempt
      # shellcheck disable=SC2034
      for attempt in 1 2 3 4 5; do
        SHELLSPEC_SUBJECT="$(tkn tr describe "${task_run_name}" -o json 2>/dev/null)" && break
        sleep 2
      done
      if [ -z "${SHELLSPEC_SUBJECT:-}" ]; then
        unset SHELLSPEC_SUBJECT ||:
      else
        shellspec_chomp SHELLSPEC_SUBJECT
      fi
    else
      unset SHELLSPEC_SUBJECT ||:
    fi
  else
    unset SHELLSPEC_SUBJECT ||:
  fi

  shellspec_off UNHANDLED_STDOUT

  eval shellspec_syntax_dispatch modifier ${1+'"$@"'}
}
