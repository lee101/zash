printf '#!/nonexistent/interp\necho hi\n' > bad.sh
chmod +x bad.sh
./bad.sh 2>&1 | sed 's/^[^:]*: //'
echo "status ${PIPESTATUS[0]}"
