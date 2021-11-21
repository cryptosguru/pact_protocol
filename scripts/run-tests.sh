#!/usr/bin/env bash
#
# Usage: run-tests.sh [-vv] [FILE_PATTERN]
set -eo pipefail

DIR="$(dirname $(dirname \"$0\"))/test"
VERBOSE=0

# Simple argument parsing.
# https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash
POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"
case $key in
  -v)
  VERBOSE=1
  shift
  ;;
  -vv)
  VERBOSE=2
  shift
  ;;
  *)    # unknown option
  POSITIONAL+=("$1") # save it in an array for later
  shift
  ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters

FILE_PATTERN=${1-*.repl}
EXIT_CODE=0
SUCCESS_REGEX="(success:)"
WARNING_REGEX="(Warning:)"
FAILURE_REGEX="(FAILURE:|error:|Load failed)"
TRACE_REGEX="(Trace:)"

for TEST_FILE in `find $DIR -name "$FILE_PATTERN" -type f`; do
  TEST_OUTPUT=`pact -t $TEST_FILE 2>&1 || true`

  # Print all output.
  if [ $VERBOSE -eq 2 ]; then
    echo -e "$TEST_OUTPUT\n"
  fi

  SUCCESSES=`echo "$TEST_OUTPUT" | grep -E "$SUCCESS_REGEX" || true`
  WARNINGS=`echo "$TEST_OUTPUT" | grep -E "$WARNING_REGEX" || true`

  # Exclude "trace" lines to avoid double-counting failure lines.
  FAILURES=`echo "$TEST_OUTPUT" | grep -Ev $TRACE_REGEX | grep -E "$FAILURE_REGEX" || true`

  # Count passes, warnings, and fails.
  SUCCESS_COUNT=`[[ ! -z "$SUCCESSES" ]] && echo "$SUCCESSES" | wc -l | tr -d ' ' || echo "0"`
  WARNING_COUNT=`[[ ! -z "$WARNINGS" ]] && echo "$WARNINGS" | wc -l | tr -d ' ' || echo "0"`
  FAILURE_COUNT=`[[ ! -z "$FAILURES" ]] && echo "$FAILURES" | wc -l | tr -d ' ' || echo "0"`

  # Print all warnings and failures.
  if [ $VERBOSE -eq 1 ]; then
    [[ ! -z "$WARNINGS" ]] && echo -e "$WARNINGS\n"
    [[ ! -z "$FAILURES" ]] && echo -e "$FAILURES\n"
  fi

  # Print result summary.
  RESULT_STRING="$TEST_FILE: \033[32m$SUCCESS_COUNT passing.\033[0m"
  if [ "$WARNING_COUNT" != "0" ]; then
    RESULT_STRING="$RESULT_STRING \033[33m$WARNING_COUNT warnings.\033[0m"
  fi
  if [ "$FAILURE_COUNT" != "0" ]; then
    RESULT_STRING="$RESULT_STRING \033[31m$FAILURE_COUNT failed.\033[0m"
  fi
  echo -e "$RESULT_STRING\n"

  # Fail when any expect statements fail.
  if [ $FAILURE_COUNT -gt 0 ]; then
    EXIT_CODE=1
  fi
done

exit $EXIT_CODE
