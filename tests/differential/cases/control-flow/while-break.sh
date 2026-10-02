i=0
while true; do i=$((i+1)); [ $i -ge 4 ] && break; done
echo $i
