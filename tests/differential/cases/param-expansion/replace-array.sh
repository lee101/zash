a=(foo bar baz foo)
echo ${a[@]/foo/X} ${a[@]//a/A} ${a[@]/#b/B}
