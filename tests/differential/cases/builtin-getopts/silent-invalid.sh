set -- -z
while getopts ":ab" o; do echo "o=$o OPTARG=$OPTARG"; done
