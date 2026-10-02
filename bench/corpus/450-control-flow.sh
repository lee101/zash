# cat: control-flow
for f in src/rs/crate03/src/*; do echo "${f##*/}"; done | head -3
