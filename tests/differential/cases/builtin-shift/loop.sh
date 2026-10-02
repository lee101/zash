set -- 1 2 3
while [ $# -gt 0 ]; do echo $1; shift; done
echo "left $#"
