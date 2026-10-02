v=path/to/file.tar.gz
echo ${v%.*} ${v%%.*} ${v%/*} ${v%%/*} ${v%nomatch}
