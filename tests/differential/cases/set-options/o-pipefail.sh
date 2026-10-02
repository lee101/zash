set -o pipefail
false | true; echo $?
set +o pipefail
false | true; echo $?
