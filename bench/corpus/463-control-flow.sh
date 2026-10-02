# cat: control-flow
i=0; while true; do i=$((i+1)); [ $i -ge 5 ] && break; done; echo $i
