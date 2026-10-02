set -o pipefail
! false | true; echo $?
! true | true; echo $?
