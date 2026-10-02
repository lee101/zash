f() { local OPTIND=1 o; while getopts "ab:" o; do echo "$o:${OPTARG:-}"; done; echo "rest: ${@:$OPTIND}"; }
f -a -b val x y
