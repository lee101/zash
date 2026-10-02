cd -P link.txt 2>/dev/null; echo $?
mkdir real; ln -s real lnk
cd -P lnk
basename "$PWD"
