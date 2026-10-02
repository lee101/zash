p=/usr/local/lib/libfoo.so.1.2
echo "${p##*/}"
echo "${p%/*}"
b=${p##*/}
echo "${b%%.*}"
echo "${b#*.}"
