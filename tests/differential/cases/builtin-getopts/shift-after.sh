set -- -a -b x rest1 rest2
while getopts "ab:" o; do :; done
shift $((OPTIND-1))
echo "$@"
