# cat: control-flow
for f in src/ts/svc01/*; do b=${f##*/}; echo "${b%.*}"; done | head -3
