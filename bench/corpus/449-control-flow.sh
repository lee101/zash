# cat: control-flow
while read -r l; do echo "${l%% *}"; done < <(ls -1 src/rs/crate03/src | head -5)
