# cat: search
grep -rIn --exclude-dir=node_modules --exclude-dir=.git '#include' src | head -15
