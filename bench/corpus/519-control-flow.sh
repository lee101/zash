# cat: control-flow
getopts_test() { while getopts 'ab:' o; do echo "opt $o $OPTARG"; done; }; getopts_test -a -b val
