for i in 1 2; do for j in a b c; do [ $j = b ] && break; echo $i$j; done; done
