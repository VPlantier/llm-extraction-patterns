#!/usr/bin/env bash
# Extraction « refine » : le document est lu tranche par tranche et le modèle
# réécrit à chaque étape des notes cumulées (notes N = f(tranche N, notes N-1)).
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
dossier="${4:-resultats-refine}"
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
[ -r "$src" ] || erreur "Document illisible : $src"
verifier_modele "$modele" "$ici/$modele.Modelfile"

# Prompt de la tranche : prompt index extrait notes.
prompt() {
  prompt_complet "$1" "$consigne" "$t_extrait" "$2" "$t_notes" "$3" \
    "$t_question" <(printf '%s\n' "$question")
}
# Texte fixe (hors extrait et notes), pour le budget.
fixe=$(prompt "$INDEX_BUDGET" /dev/null /dev/null)
max_car=$(budget_tranche "$modele" "$fixe" 2)
[ "$max_car" -gt 500 ] || erreur "Contexte trop petit pour $modele : augmente num_ctx ou CIBLE_CTX, ou réduis num_predict / la question."
echo "Tranches : $MAX_MOTS mots et $max_car caractères au plus." >&2

mkdir -p "$dossier"
decouper "$src" "$dossier/tranches" "$MAX_MOTS" "$max_car"

echo "$vide" > "$dossier/note_000.md"
i=0
suiv="$dossier/note_000.md"
for f in "$dossier"/tranches/*.md; do
  prec="$dossier/note_$(printf %03d "$i").md"
  i=$((i + 1))
  suiv="$dossier/note_$(printf %03d "$i").md"
  if [ -s "$suiv" ]; then
    echo "Tranche $f déjà faite, on passe" >&2
    continue
  fi
  avant_appel
  echo "Tranche $f -> $suiv" >&2

  # En cas d'échec de l'appel (réponse coupée, contexte dépassé), le script
  # s'arrête ici sans rien écrire : une reprise refera cette tranche.
  nouvelle=$(prompt "$(indice_tranche "$f")" "$f" "$prec" | appeler_modele "$modele")

  mots_prec=$(wc -w < "$prec")
  mots_new=$(echo "$nouvelle" | wc -w)
  if [ "$mots_new" -lt $((mots_prec / 2)) ]; then
    echo "  Attention : $suiv fait $mots_new mots contre $mots_prec avant, perte d'informations possible" >&2
  fi

  # Écriture puis renommage : un fichier présent est toujours complet.
  echo "$nouvelle" > "$suiv.tmp"
  mv "$suiv.tmp" "$suiv"
done
echo "Dernière version : $suiv" >&2

# Union de toutes les versions : récupère les éléments perdus en route.
"$RACINE/fusion.sh" -o "$dossier/fusion.md" "$dossier"
