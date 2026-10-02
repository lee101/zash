for i in 1 2 3; do echo $i; done > l.txt
cat l.txt
while read -r x; do echo "got $x"; done < l.txt
