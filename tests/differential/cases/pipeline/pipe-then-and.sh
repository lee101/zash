echo a | grep -q a && echo matched
echo a | grep -q z || echo nomatch
