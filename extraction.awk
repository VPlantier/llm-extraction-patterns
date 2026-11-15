
# Normalisation : puce « * », espaces simples, pas d espace en fin de ligne.
function norm(s) {
    gsub(/^[ \t]+|[ \t]+$/, "", s)
    gsub(/[ \t]+/, " ", s)
    return s
}
/^[ \t]*#+[ \t]/ {
	t = norm($0);
	ordre[++nbt] = t
	nt[t]++

}
/^[ \t]*[*-][ \t]+[^ \t]/ {
	l = norm($0)
	sub(/^[*-] /, "* ", l)
	p = ""
	if (l ~ /\(.*\)$/) {
		p = l
		if (match(p, /\(.*\)/)){
			p = substr(p, RSTART, RLENGTH)
		}
		sub(/ *\(.*\)$/, "", l)
	}
	if (!(l in vu)) {
		vu[l] = ++nb;
		elements[nb] = l
		parentheses[nb] = p
	} else if (length(parentheses[vu[l]]) <= length(p)){
		parentheses[vu[l]] = p
	}
}
END {
	if (titre == "") {
		for (i = 1; i <= nbt; i++)
			if (nt[ordre[i]] > meilleur) {
				meilleur = nt[ordre[i]]
				titre = ordre[i]
			}
	} else if (titre !~ /^#/) {
		titre = "# " titre
	}
	if (titre != "")
		print titre "\n"
	for (i = 1; i <= nb; i++){
		if (parentheses[i] == "")
			print elements[i]
		else
			print elements[i] " " parentheses[i]
	}
	printf "%d éléments distincts\n", nb > "/dev/stderr"
}
