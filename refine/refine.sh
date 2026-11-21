#!/usr/bin/env bash
# Extraction « refine » : les tranches sont lues dans l'ordre et le modèle
# réécrit à chaque étape des notes cumulées (notes N = f(tranche N, notes N-1)).
#
# Les notes après la tranche N sont dans travail/<série>/N.md. Les notes de
# départ sont le fichier qui précède la première tranche traitée (000.md, ou
# 011.md avec -d 12) : s'il existe, il est utilisé tel quel, ce qui permet de
# partir de notes écrites ou corrigées à la main ; sinon il est créé vide.
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
modele="refine-$langue"

case "$langue" in
  fr) t_extrait="EXTRAIT"; t_notes="NOTES ACTUELLES"; t_question="QUESTION"
      vide="(aucune note pour l'instant)"
      consigne="Réécris maintenant la version complète et mise à jour des notes, au format demandé." ;;
  en) t_extrait="EXCERPT"; t_notes="CURRENT NOTES"; t_question="QUESTION"
      vide="(no notes yet)"
      consigne="Now rewrite the complete, updated version of the notes, in the required format." ;;
  *)  erreur "Langue invalide : $langue (fr ou en)" ;;
esac
verifier_modele "$modele" "$ici/$modele.Modelfile"
etat_materiel
preparer_serie "$travail" "$nom" "$(printf 'mode=refine\nlangue=%s\nquestion=%s' "$langue" "$question")" "$de" "$a"

# Prompt de la tranche : prompt index extrait notes.
prompt() {
  prompt_complet "$1" "$consigne" "$t_extrait" "$2" "$t_notes" "$3" \
    "$t_question" <(printf '%s\n' "$question")
}
# Texte fixe (hors extrait et notes) ; les notes relues sont une réponse
# précédente, d'où k = 2.
verifier_tranches "$modele" "$(prompt "$INDEX_BUDGET" /dev/null /dev/null | wc -m)" 2

depart="$SERIE/$(num $((DE - 1))).md"
if [ -s "$depart" ]; then
  echo "Notes de départ : $depart (existant, utilisé tel quel)" >&2
else
  echo "$vide" > "$depart"
  echo "Notes de départ : $depart (vides)" >&2
fi

for f in "${TRANCHES[@]}"; do
  i=$(indice_tranche "$f")
  prec="$SERIE/$(num $((i - 1))).md"
  suiv="$SERIE/$(num "$i").md"
  if [ -s "$suiv" ]; then
    echo "Tranche $f déjà faite, on passe" >&2
    continue
  fi
  avant_appel
  echo "Tranche $f -> $suiv" >&2

  # En cas d'échec de l'appel (réponse coupée, contexte dépassé), le script
  # s'arrête ici sans rien écrire : une reprise refera cette tranche.
  nouvelle=$(prompt "$i" "$f" "$prec" | appeler_modele "$modele")

  mots_prec=$(wc -w < "$prec")
  mots_new=$(echo "$nouvelle" | wc -w)
  if [ "$mots_new" -lt $((mots_prec / 2)) ]; then
    echo "  Attention : $suiv fait $mots_new mots contre $mots_prec avant, perte d'informations possible" >&2
  fi

  # Écriture puis renommage : un fichier présent est toujours complet.
  echo "$nouvelle" > "$suiv.tmp"
  mv "$suiv.tmp" "$suiv"
done
echo "Dernière version : $SERIE/$(num "$A").md" >&2

# Union des versions de l'intervalle, notes de départ comprises : récupère
# les éléments perdus en route.
fichiers=()
for ((i = DE - 1; i <= A; i++)); do
  fichiers+=("$SERIE/$(num "$i").md")
done
"$RACINE/fusion.sh" -o "$SERIE/fusion_$(num "$DE")-$(num "$A").md" "${fichiers[@]}"
