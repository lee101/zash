mkdir real; ln -s real lnk
cd lnk
pwd -L | sed 's|.*/||'
pwd -P | sed 's|.*/||'
