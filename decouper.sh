#!/usr/bin/env bash
# Découpe un document en tranches, une fois pour toutes, dans un dossier de
# travail : travail/tranches/001.md, 002.md...
#
# Le numéro d'une tranche est ainsi une référence stable : toutes les séries
# de résultats (une par question) portent sur les mêmes tranches, et on peut
# viser un intervalle de tranches (option -d/-a des scripts d'extraction).
#
# Sans -t, la taille des tranches est la plus grande qui convienne à tous les
# modèles retenus pour une question d'au plus QUESTION_MAX caractères, arrondie
# à la centaine inférieure. Avec -t, la taille donnée est refusée si elle
# dépasse ce maximum.
set -euo pipefail
ici="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ici/lib/commun.sh"

# Caractères prévus pour le texte fixe du prompt hors question : section
# VARIABLE, titres de sections, consigne. Le plus long (refine) en fait
# environ 200.
TEXTE_FIXE_CAR=500

usage() {
  cat >&2 <<EOF
Usage : $0 [-t taille] [-m modèle]... document.md dossier_de_travail
  -t taille   taille maximale d'une tranche, en caractères
  -m modèle   modèle à prendre en compte (répétable) ; par défaut, tous les
              modèles d'extraction installés (refine, map-reduce,
              premier-dernier ; fr et en)
EOF
  exit 1
}

taille=""
modeles=()
while getopts "t:m:h" opt; do
  case "$opt" in
    t) taille="$OPTARG" ;;
    m) modeles+=("$OPTARG") ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 2 ] || usage
src="$1"
travail="$2"

[ -r "$src" ] || erreur "Document illisible : $src"
[ ! -e "$travail/decoupage.txt" ] ||
  erreur "$travail est déjà découpé (voir $travail/decoupage.txt). Les séries de résultats s'appuient sur ces tranches : pour un autre découpage, choisis un autre dossier de travail."
if [ -n "$taille" ]; then
  [[ "$taille" =~ ^[0-9]+$ ]] || erreur "Taille invalide : $taille"
fi

if [ ${#modeles[@]} -eq 0 ]; then
  for mode in refine map-reduce premier-dernier; do
    for langue in fr en; do
      if ollama show "$mode-$langue" > /dev/null 2>&1; then
        modeles+=("$mode-$langue")
      else
        echo "Modèle $mode-$langue absent : ignoré." >&2
      fi
    done
  done
  [ ${#modeles[@]} -gt 0 ] ||
    erreur "Aucun modèle d'extraction installé : crée-les d'abord (voir LISEZMOI.md)."
else
  for m in "${modeles[@]}"; do
    verifier_modele "$m" "$ici/${m%-*}/$m.Modelfile"
  done
fi

# Taille maximale commune à tous les modèles retenus. refine relit ses notes
# précédentes : il réserve deux fois num_predict.
max=""
for m in "${modeles[@]}"; do
  k=1
  case "$m" in refine-*) k=2 ;; esac
  b=$(budget_tranche "$m" $((QUESTION_MAX + TEXTE_FIXE_CAR)) "$k")
  if [ -z "$max" ] || [ "$b" -lt "$max" ]; then max=$b; fi
done
echo "Taille maximale pour ces modèles, avec une question d'au plus $QUESTION_MAX caractères : $max caractères." >&2
# Ce plancher vise un réglage des modèles qui ne laisse presque plus de place
# au texte. Une taille plus petite donnée avec -t reste permise (tests).
[ "$max" -ge 500 ] ||
  erreur "Taille de tranche maximale trop petite ($max caractères) : augmente num_ctx ou CIBLE_CTX, réduis num_predict ou QUESTION_MAX."

if [ -n "$taille" ]; then
  [ "$taille" -le "$max" ] ||
    erreur "Taille $taille trop grande : $max caractères au plus pour ces modèles. Choisis une taille plus petite, ou retiens moins de modèles (-m)."
else
  taille=$((max / 100 * 100))
fi
[ "$taille" -ge 1 ] || erreur "Taille invalide : $taille"

mkdir -p "$travail"
decouper "$src" "$travail/tranches" "$taille"
nb=$(find "$travail/tranches" -maxdepth 1 -type f -name '*.md' | wc -l)
{
  echo "document=$src"
  echo "taille=$taille"
  echo "question_max=$QUESTION_MAX"
  echo "modeles=${modeles[*]}"
  echo "tranches=$nb"
  echo "date=$(date '+%Y-%m-%d %H:%M:%S')"
} > "$travail/decoupage.txt"
echo "$nb tranches de $taille caractères au plus dans $travail/tranches." >&2
