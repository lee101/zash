true | false | true; echo ${PIPESTATUS[@]}
( exit 5 ) | ( exit 6 ); echo ${PIPESTATUS[0]} ${PIPESTATUS[1]}
