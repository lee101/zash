[[ "key=value" =~ ^([^=]+)=(.*)$ ]]
echo ${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${#BASH_REMATCH[@]}
