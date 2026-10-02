exec > exec.txt
echo captured
exec >&2
cat exec.txt
