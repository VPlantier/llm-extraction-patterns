#!/usr/bin/env bash
# Extraction « premier-dernier » : trouve le premier et le dernier élément d'un
# document (ou d'un intervalle de tranches) qui satisfont un critère donné
# (ex. le premier et le dernier mot d'un dictionnaire désignant une nourriture).
# Premier : on parcourt les tranches depuis le début jusqu'à en trouver une qui
# contient un élément. Dernier : idem en partant de la fin. Le modèle liste
# dans l'ordre tous les éléments de la tranche ; le script prend le premier
# (ou le dernier) de cette liste.
#
# La réponse pour la tranche N est dans travail/<série>/N.md (seules les
# tranches nécessaires sont analysées), le résultat dans
# travail/<série>/final_<de>-<à>.md.
set -euo pipefail
ici="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ici/../lib/commun.sh"

usage() {
  cat >&2 <<EOF
Usage : $0 [-d de] [-a à] fr|en dossier_de_travail série "critère"
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
critere="$4"
modele="premier-dernier-$langue"

case "$langue" in
  fr) t_extrait="EXTRAIT"; t_critere="CRITÈRE"
      consigne="Liste maintenant, dans leur ordre d'apparition, tous les éléments de cet extrait qui satisfont le critère, ou réponds AUCUN." ;;
  en) t_extrait="EXCERPT"; t_critere="CRITERION"
      consigne="Now list, in order of appearance, every item of this excerpt that meets the criterion, or reply NONE." ;;
  *)  erreur "Langue invalide : $langue (fr ou en)" ;;
esac
verifier_modele "$modele" "$ici/$modele.Modelfile"
preparer_serie "$travail" "$nom" "$(printf 'mode=premier-dernier\nlangue=%s\ncritere=%s' "$langue" "$critere")" "$de" "$a"

# Prompt de la tranche : prompt index extrait.
prompt() {
  prompt_complet "$1" "$consigne" "$t_extrait" "$2" "$t_critere" <(printf '%s\n' "$critere")
}
# Texte fixe (hors extrait).
verifier_tranches "$modele" "$(prompt "$INDEX_BUDGET" /dev/null | wc -m)" 1
nb=${#TRANCHES[@]}

# Fait analyser une tranche (une seule fois, réponse enregistrée) et
# affiche ses éléments, un par ligne, puce normalisée en « * ».
# Échoue sans rien enregistrer si l'appel au modèle échoue (réponse coupée,
# contexte dépassé) : une reprise refera cette tranche.
# À appeler dans une affectation (liste=$(elements f)) et non dans un tube :
# l'échec arrête alors le script (set -e).
elements() {
  local f="$1" res
  res="$SERIE/$(basename "$f")"
  if [ ! -s "$res" ]; then
    avant_appel
    echo "Tranche $f -> $res" >&2
    # set -e ne s'applique pas dans $(...) : l'échec doit être traité ici.
    if ! prompt "$(indice_tranche "$f")" "$f" | appeler_modele "$modele" > "$res.tmp"; then
      rm -f "$res.tmp"
      return 1
    fi
    echo >> "$res.tmp"
    mv "$res.tmp" "$res"
  fi
  sed -nE 's/^[[:space:]]*[*-][[:space:]]+([^[:space:]].*)$/* \1/p' "$res" | sed -E 's/[[:space:]]+$//'
}

final="$SERIE/final_$(num "$DE")-$(num "$A").md"
premier=""; idx=-1
for ((k = 0; k < nb; k++)); do
  liste=$(elements "${TRANCHES[k]}")
  premier=$(head -n 1 <<< "$liste")
  if [ -n "$premier" ]; then idx=$k; break; fi
done
if [ "$idx" -lt 0 ]; then
  : > "$final"
  echo "Aucun élément ne satisfait le critère dans les tranches $DE à $A." >&2
  exit 3
fi

dernier=""
for ((k = nb - 1; k >= idx; k--)); do
  liste=$(elements "${TRANCHES[k]}")
  dernier=$(tail -n 1 <<< "$liste")
  [ -n "$dernier" ] && break
done

printf '%s\n%s\n' "$premier" "$dernier" > "$final"
echo "Premier (tranche $(indice_tranche "${TRANCHES[idx]}")) et dernier : $final" >&2
cat "$final"
