# cat: search
grep -rIn --exclude-dir=node_modules --exclude-dir=.git 'fetch_user' tests | head -50
