# cat: control-flow
while read -r l; do echo "${l%% *}"; done < <(ls -1 tests/unit00 | head -5)
