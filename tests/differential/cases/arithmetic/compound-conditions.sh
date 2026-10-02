x=7
if (( x > 5 && x < 10 )); then echo mid; fi
if (( x < 5 || x == 7 )); then echo or; fi
if (( !(x == 7) )); then echo no; else echo yes; fi
