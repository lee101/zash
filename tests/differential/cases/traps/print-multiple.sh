trap 'echo a' USR1
trap 'echo b' EXIT
trap -p | sort
