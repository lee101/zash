mkdir real; ln -s real lnk
cd lnk
basename "$PWD"
pwd -P | xargs basename
pwd -L | xargs basename
