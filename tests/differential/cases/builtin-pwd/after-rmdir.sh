mkdir tmpd
cd tmpd
rmdir ../tmpd
pwd 2>/dev/null | sed 's|.*/||'
