#!/usr/bin/env bash
# Fusionne des fichiers de résultats (refine ou map-reduce) en une seule liste.
#
# Les fichiers sont lus dans l'ordre donné (ou, pour un dossier, dans l'ordre
# naturel de leurs noms). Seuls les éléments de liste (lignes commençant par
# « * » ou « - ») sont conservés, dans l'ordre de première apparition ; une
# ligne déjà vue est ignorée. Les titres et tout autre texte sont ignorés.
# Le fichier produit reprend le titre le plus fréquent (ou celui donné par -t).
set -euo pipefail

usage() {
  echo "Usage : $0 [-t titre] [-o sortie.md] (dossier | fichier1.md fichier2.md ...)" >&2
  exit 1
}

titre=""
sortie=""
while getopts "t:o:h" opt; do
  case "$opt" in
    t) titre="$OPTARG" ;;
    o) sortie="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -ge 1 ] || usage

if [ $# -eq 1 ] && [ -d "$1" ]; then
  mapfile -t fichiers < <(find "$1" -maxdepth 1 -type f -name '*.md' | sort -V)
else
  fichiers=("$@")
fi
[ ${#fichiers[@]} -gt 0 ] || { echo "Aucun fichier à fusionner." >&2; exit 1; }
# Ne pas relire le fichier de sortie s'il est dans le dossier fusionné.
if [ -n "$sortie" ] && [ -e "$sortie" ]; then
  for i in "${!fichiers[@]}"; do
    [ "${fichiers[$i]}" -ef "$sortie" ] && unset 'fichiers[i]'
  done
  fichiers=("${fichiers[@]}")
fi

resultat=$(awk -v titre="$titre" -f extraction.awk "${fichiers[@]}")

if [ -n "$sortie" ]; then
  printf '%s\n' "$resultat" > "$sortie"
  echo "Fusion écrite dans $sortie" >&2
else
  printf '%s\n' "$resultat"
fi
