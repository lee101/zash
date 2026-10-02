f() { echo from f; }
f > f.txt
cat f.txt
g() { cat; }
g < a.txt | head -1
