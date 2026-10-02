v=path/to/file.tar.gz
echo ${v#*/} ${v##*/} ${v#path} ${v##*.} ${v#nomatch}
