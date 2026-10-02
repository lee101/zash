for i in 1 2 3; do echo $i; [ $i -eq 2 ] && exit 5; done
echo never
