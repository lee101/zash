printf 'a,b,c' | { mapfile -t -d , a; echo ${#a[@]} ${a[2]}; }
