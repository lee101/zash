set -- -abc
while getopts "abc" o; do echo $o; done
