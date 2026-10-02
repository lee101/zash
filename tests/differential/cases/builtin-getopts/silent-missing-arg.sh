set -- -b
while getopts ":b:" o; do echo "o=$o OPTARG=$OPTARG"; done
