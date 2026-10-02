case 'a*' in "a*") echo literal;; esac
case 'abc' in "a*") echo no;; *) echo star;; esac
