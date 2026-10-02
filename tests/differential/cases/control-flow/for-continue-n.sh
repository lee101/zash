for i in 1 2 3; do for j in a b; do [ $j = a ] && continue 2; echo never; done; done; echo end
