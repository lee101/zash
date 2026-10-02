( cd dir; echo $(basename $PWD) )
echo $(basename $PWD) | grep -c work
