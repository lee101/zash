mkdir bin
printf '#!/bin/sh\necho local-ls\n' > bin/ls
chmod +x bin/ls
PATH=$PWD/bin:$PATH ls
