[ a.txt -nt b.txt ] || echo not-newer
[ a.txt -ef a.txt ] && echo same
[ a.txt -ef link.txt ] && echo linksame
[ a.txt -ot nonexistent ] && echo older-than-missing
