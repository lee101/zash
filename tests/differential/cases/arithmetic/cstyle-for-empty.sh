i=0
for ((;;)); do i=$((i+1)); [ $i -ge 3 ] && break; done; echo $i
