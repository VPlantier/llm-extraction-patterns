#!/usr/bin/env bash
# Extraction « map-reduce » : chaque tranche est traitée isolément (map), sans
# que les résultats des étapes précédentes soient renvoyés au modèle ; les
# résultats sont ensuite fusionnés sans doublons (reduce, par fusion.sh).
#
# La réponse pour la tranche N est dans travail/<série>/N.md, la fusion de
# l'intervalle dans travail/<série>/final_<de>-<à>.md.
set -euo pipefail
ici="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ici/../lib/commun.sh"

usage() {
  cat >&2 <<EOF
Usage : $0 [-d de] [-a à] fr|en dossier_de_travail série "question"
  -d, -a  numéros de la première et de la dernière tranche (défaut : toutes)
Le dossier de travail est créé par decouper.sh.
EOF
  exit 1
}

de=""
a=""
while getopts "d:a:h" opt; do
  case "$opt" in
    d) de="$OPTARG" ;;
    a) a="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 4 ] || usage
langue="$1"
travail="$2"
nom="$3"
question="$4"
modele="map-reduce-$langue"

case "$langue" in
  fr) t_extrait="EXTRAIT"; t_question="QUESTION"
      consigne="Extrais maintenant de cet extrait les éléments qui répondent à la question, au format demandé." ;;
  en) t_extrait="EXCERPT"; t_question="QUESTION"
      consigne="Now extract from this excerpt the items that answer the question, in the required format." ;;
  *)  erreur "Langue invalide : $langue (fr ou en)" ;;
esac
verifier_modele "$modele" "$ici/$modele.Modelfile"
etat_materiel
preparer_serie "$travail" "$nom" "$(printf 'mode=map-reduce\nlangue=%s\nquestion=%s' "$langue" "$question")" "$de" "$a"

# Prompt de la tranche : prompt index extrait.
prompt() {
  prompt_complet "$1" "$consigne" "$t_extrait" "$2" "$t_question" <(printf '%s\n' "$question")
}
# Texte fixe (hors extrait).
verifier_tranches "$modele" "$(prompt "$INDEX_BUDGET" /dev/null | wc -m)" 1

resultats=()
for f in "${TRANCHES[@]}"; do
  res="$SERIE/$(basename "$f")"
  resultats+=("$res")
  if [ -s "$res" ]; then
    echo "Tranche $f déjà faite, on passe" >&2
    continue
  fi
  avant_appel
  echo "Tranche $f -> $res" >&2
  # En cas d'échec de l'appel (réponse coupée, contexte dépassé), le script
  # s'arrête ici sans rien écrire : une reprise refera cette tranche.
  reponse=$(prompt "$(indice_tranche "$f")" "$f" | appeler_modele "$modele")
  # Écriture puis renommage : un fichier présent est toujours complet.
  echo "$reponse" > "$res.tmp"
  mv "$res.tmp" "$res"
done

final="$SERIE/final_$(num "$DE")-$(num "$A").md"
"$RACINE/fusion.sh" -o "$final" "${resultats[@]}"
echo "Résultat final : $final" >&2
