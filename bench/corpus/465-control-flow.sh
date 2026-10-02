# cat: control-flow
while read -r line; do echo "${line%%=*}"; done < data/kv.env | tail -3
