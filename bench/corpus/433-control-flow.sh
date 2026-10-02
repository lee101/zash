# cat: control-flow
while read -r l; do echo "${l%% *}"; done < <(ls -1 src/ts/svc01 | head -5)
