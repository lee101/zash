unset ref
x=1
ref=x
echo ${!ref} ${!ref:-d}
unset x
echo ${!ref:-default}
