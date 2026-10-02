shopt -s extglob
[[ abc == @(abc|def) ]] && echo at
[[ abc == !(def) ]] && echo not
