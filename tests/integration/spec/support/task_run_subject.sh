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
      local attempt json
      # `tkn task start --showlog` returns when the pod finishes, but the
      # controller writes .status.results (and .status.steps[].results) during
      # a final reconcile a moment later. Poll until the TaskRun reaches a
      # terminal Succeeded condition so results are guaranteed populated;
      # otherwise a fast describe races the controller and sees null results.
      # shellcheck disable=SC2034
      for attempt in $(seq 1 30); do
        json="$(tkn tr describe "${task_run_name}" -o json 2>/dev/null)" || { sleep 2; continue; }
        if printf '%s\n' "${json}" | jq --exit-status \
            '.status.conditions[]? | select(.type=="Succeeded") | .status != "Unknown"' \
            > /dev/null 2>&1; then
          SHELLSPEC_SUBJECT="${json}"
          break
        fi
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
