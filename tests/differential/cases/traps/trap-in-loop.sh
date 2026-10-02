trap 'echo "caught at $i"' ERR
for i in 1 2 3; do [ $i -eq 2 ] && false; done
