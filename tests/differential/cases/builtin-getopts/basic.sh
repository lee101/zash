set -- -a -b val file
while getopts "ab:" o; do echo "$o ${OPTARG-}"; done
echo "OPTIND=$OPTIND"
