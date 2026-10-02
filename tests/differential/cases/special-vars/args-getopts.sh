while getopts "ab:c" o; do echo "opt=$o arg=${OPTARG:-}"; done
shift $((OPTIND-1))
echo "rest: $@"
