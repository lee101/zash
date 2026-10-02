pushd dir > /dev/null
basename "$PWD"
pushd sub > /dev/null
basename "$PWD"
popd > /dev/null
basename "$PWD"
dirs -v | wc -l | tr -d ' '
