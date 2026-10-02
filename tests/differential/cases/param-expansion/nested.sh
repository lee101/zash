a=b
b=c
x=hello
echo ${x:-${a}} ${y:-${x:-z}} ${x/${x:0:1}/J}
