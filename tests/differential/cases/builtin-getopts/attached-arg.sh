set -- -bvalue
while getopts "b:" o; do echo "$o $OPTARG"; done
