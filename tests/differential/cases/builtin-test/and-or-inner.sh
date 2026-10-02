[ -e a.txt -a -e b.txt ] && echo both
[ -e a.txt -a -e nonexistent ] || echo notboth
[ -e nonexistent -o -e a.txt ] && echo either
