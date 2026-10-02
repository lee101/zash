# cat: git
git ls-tree -r HEAD --name-only | grep -c '\.go$'
