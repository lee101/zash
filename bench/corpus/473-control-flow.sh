# cat: control-flow
if [[ "abc123" =~ ^[a-z]+([0-9]+)$ ]]; then echo ${BASH_REMATCH[1]}; fi
