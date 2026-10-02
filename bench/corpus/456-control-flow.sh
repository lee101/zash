# cat: control-flow
for f in src/js/comp02/*; do b=${f##*/}; echo "${b%.*}"; done | head -3
