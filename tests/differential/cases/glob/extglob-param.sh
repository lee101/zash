shopt -s extglob
v=aaabbb
echo ${v##+(a)} ${v%%+(b)} ${v//+(a)/X}
