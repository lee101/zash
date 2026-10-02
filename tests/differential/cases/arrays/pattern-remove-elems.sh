a=(file1.txt file2.txt file3.log)
echo ${a[@]%.*}
echo ${a[@]#file}
