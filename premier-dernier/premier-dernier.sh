#!/usr/bin/env bash
# Extraction « premier-dernier » : trouve le premier et le dernier élément d'un
# document qui satisfont un critère donné (ex. le premier et le dernier mot
# d'un dictionnaire désignant une nourriture).
# Premier : on parcourt les tranches depuis le début jusqu'à en trouver une qui
# contient un élément. Dernier : idem en partant de la fin. Le modèle liste
# dans l'ordre tous les éléments de la tranche ; le script prend le premier
# (ou le dernier) de cette liste.
set -euo pipefail
ici="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ici/../lib/commun.sh"

if [ $# -lt 3 ]; then
  echo "Usage : $0 fr|en document.md \"critère\" [dossier]" >&2
  exit 1
fi

langue="$1"
src="$2"
critere="$3"
dossier="${4:-resultats-premier-dernier}"
modele="premier-dernier-$langue"

case "$langue" in
  fr) t_extrait="EXTRAIT"; t_critere="CRITÈRE"
      consigne="Liste maintenant, dans leur ordre d'apparition, tous les éléments de cet extrait qui satisfont le critère, ou réponds AUCUN." ;;
  en) t_extrait="EXCERPT"; t_critere="CRITERION"
      consigne="Now list, in order of appearance, every item of this excerpt that meets the criterion, or reply NONE." ;;
  *)  erreur "Langue invalide : $langue (fr ou en)" ;;
esac
[ -r "$src" ] || erreur "Document illisible : $src"
verifier_modele "$modele" "$ici/$modele.Modelfile"

# Prompt de la tranche : prompt index extrait.
prompt() {
  prompt_complet "$1" "$consigne" "$t_extrait" "$2" "$t_critere" <(printf '%s\n' "$critere")
}
# Texte fixe (hors extrait), pour le budget.
fixe=$(prompt "$INDEX_BUDGET" /dev/null)
max_car=$(budget_tranche "$modele" "$fixe" 1)
[ "$max_car" -gt 500 ] || erreur "Contexte trop petit pour $modele : augmente num_ctx ou réduis num_predict / le critère."
echo "Tranches : $MAX_MOTS mots et $max_car caractères au plus." >&2
num_predict=$(parametre_modele "$modele" num_predict)

mkdir -p "$dossier/reponses"
decouper "$src" "$dossier/tranches" "$MAX_MOTS" "$max_car"
mapfile -t tranches < <(printf '%s\n' "$dossier"/tranches/*.md)
nb=${#tranches[@]}

# Fait analyser une tranche (une seule fois, réponse mise en cache) et
# affiche ses éléments, un par ligne, puce normalisée en « * ».
elements() {
  local f="$1" res
  res="$dossier/reponses/$(basename "$f")"
  if [ ! -s "$res" ]; then
    avant_appel
    echo "Tranche $f -> $res" >&2
    prompt "$(indice_tranche "$f")" "$f" | appeler_modele "$modele" > "$res.tmp"
    echo >> "$res.tmp"
    mv "$res.tmp" "$res"
    # Réponse proche de la limite : la fin de la liste a pu être coupée.
    if [ "$(wc -m < "$res")" -gt $((num_predict * 3)) ]; then
      echo "  Attention : réponse très longue pour $f, la liste a pu être tronquée (réduis MAX_MOTS)." >&2
    fi
  fi
  sed -nE 's/^[[:space:]]*[*-][[:space:]]+([^[:space:]].*)$/* \1/p' "$res" | sed -E 's/[[:space:]]+$//'
}

premier=""; idx=-1
for ((k = 0; k < nb; k++)); do
  premier=$(elements "${tranches[k]}" | head -n 1)
  if [ -n "$premier" ]; then idx=$k; break; fi
done
if [ "$idx" -lt 0 ]; then
  : > "$dossier/final.md"
  echo "Aucun élément ne satisfait le critère." >&2
  exit 3
fi

dernier=""
for ((k = nb - 1; k >= idx; k--)); do
  dernier=$(elements "${tranches[k]}" | tail -n 1)
  [ -n "$dernier" ] && break
done

printf '%s\n%s\n' "$premier" "$dernier" > "$dossier/final.md"
echo "Premier (tranche $((idx + 1))/$nb) et dernier : $dossier/final.md" >&2
cat "$dossier/final.md"
