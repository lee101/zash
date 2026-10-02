# cat: control-flow
for f in src/rs/crate03/src/*; do b=${f##*/}; echo "${b%.*}"; done | head -3
