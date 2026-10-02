mkdir -p real/inner; ln -s real/inner lnk
cd lnk
cd ..
basename "$PWD"
