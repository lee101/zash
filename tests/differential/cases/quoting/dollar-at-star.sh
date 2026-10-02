set -- "a b" c
printf '<%s>' "$@"; echo
printf '<%s>' "$*"; echo
printf '<%s>' $@; echo
printf '<%s>' $*; echo
