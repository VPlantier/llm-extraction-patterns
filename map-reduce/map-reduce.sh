#!/usr/bin/env bash
# Extraction « map-reduce » : chaque tranche est traitée isolément (map), sans
# que les résultats des étapes précédentes soient renvoyés au modèle ; les
# résultats sont ensuite fusionnés sans doublons (reduce, par fusion.sh).
set -euo pipefail
ici="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ici/../lib/commun.sh"

if [ $# -lt 3 ]; then
  echo "Usage : $0 fr|en document.md \"question\" [dossier]" >&2
  exit 1
fi

langue="$1"
src="$2"
question="$3"
dossier="${4:-resultats-map-reduce}"
modele="map-reduce-$langue"

case "$langue" in
  fr) t_extrait="EXTRAIT"; t_question="QUESTION"
      consigne="Extrais maintenant de cet extrait les éléments qui répondent à la question, au format demandé." ;;
  en) t_extrait="EXCERPT"; t_question="QUESTION"
      consigne="Now extract from this excerpt the items that answer the question, in the required format." ;;
  *)  erreur "Langue invalide : $langue (fr ou en)" ;;
esac
[ -r "$src" ] || erreur "Document illisible : $src"
verifier_modele "$modele" "$ici/$modele.Modelfile"

# Prompt de la tranche : prompt index extrait.
prompt() {
  prompt_complet "$1" "$consigne" "$t_extrait" "$2" "$t_question" <(printf '%s\n' "$question")
}
# Texte fixe (hors extrait), pour le budget.
fixe=$(prompt "$INDEX_BUDGET" /dev/null)
max_car=$(budget_tranche "$modele" "$fixe" 1)
[ "$max_car" -gt 500 ] || erreur "Contexte trop petit pour $modele : augmente num_ctx ou réduis num_predict / la question."
echo "Tranches : $MAX_MOTS mots et $max_car caractères au plus." >&2

mkdir -p "$dossier/map"
decouper "$src" "$dossier/tranches" "$MAX_MOTS" "$max_car"

for f in "$dossier"/tranches/*.md; do
  res="$dossier/map/$(basename "$f")"
  if [ -s "$res" ]; then
    echo "Tranche $f déjà faite, on passe" >&2
    continue
  fi
  avant_appel
  echo "Tranche $f -> $res" >&2
  reponse=$(prompt "$(indice_tranche "$f")" "$f" | appeler_modele "$modele")
  echo "$reponse" > "$res"
done

"$RACINE/fusion.sh" -o "$dossier/final.md" "$dossier/map"
echo "Résultat final : $dossier/final.md" >&2
