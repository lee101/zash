# cat: control-flow
for f in tests/unit00/*; do b=${f##*/}; echo "${b%.*}"; done | head -3
