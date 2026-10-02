echo 'echo inner' > in.sh
echo '. ./in.sh; echo outer' > out.sh
. ./out.sh
