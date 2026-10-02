# cat: search
grep -rIn --exclude-dir=node_modules --exclude-dir=.git 'Errorf' src/go/pkg03 | head -20
