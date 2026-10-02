# cat: search
grep -rIn --exclude-dir=node_modules --exclude-dir=.git 'TODO' src/ts | head -20
