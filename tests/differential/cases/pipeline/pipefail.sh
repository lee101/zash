set -o pipefail
false | true; echo $?
true | false | true; echo $?
true | true; echo $?
