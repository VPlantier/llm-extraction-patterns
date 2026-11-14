# Fonctions communes aux scripts d'extraction (à sourcer, pas à exécuter).
#
# Variables d'environnement reconnues :
#   MAX_MOTS       taille maximale d'une tranche, en mots            (défaut 2000)
#   MIN_MOTS       taille minimale avant de couper sur un titre      (défaut MAX_MOTS/4)
#   CAR_PAR_TOKEN  ratio prudent caractères/token pour les estimations (défaut 2.5 ;
#                  ~4,3 mesuré sur du français avec gemma4)
#   MARGE_TOKENS   réserve pour le gabarit de conversation et les en-têtes (défaut 256)
#   TEMP_MAX       température (°C) au-delà de laquelle on fait une pause (défaut 90)

MAX_MOTS="${MAX_MOTS:-2000}"
MIN_MOTS="${MIN_MOTS:-$((MAX_MOTS / 4))}"
CAR_PAR_TOKEN="${CAR_PAR_TOKEN:-2.5}"
MARGE_TOKENS="${MARGE_TOKENS:-256}"
TEMP_MAX="${TEMP_MAX:-90}"

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

erreur() { echo "$*" >&2; exit 1; }

# Vérifie que le modèle existe, sinon indique comment le créer.
verifier_modele() {
  local modele="$1" modelfile="$2"
  if ! ollama show "$modele" > /dev/null 2>&1; then
    erreur "Modèle $modele introuvable. Crée-le avec : ollama create $modele -f $modelfile"
  fi
}

# Valeur d'un paramètre du modèle (num_ctx, num_predict...), vide s'il n'est pas défini.
parametre_modele() {
  ollama show "$1" --parameters | awk -v n="$2" '$1 == n { print $2; exit }'
}

# Nombre maximal de caractères d'une tranche pour que le prompt complet tienne
# dans le contexte :
#   num_ctx - k * num_predict - système - texte fixe - marge
# k = nombre de blocs de taille num_predict à réserver : 1 pour la réponse,
# 2 en refine (les notes relues sont une réponse précédente, donc bornées par
# num_predict, plus la nouvelle réponse).
budget_tranche() {
  local modele="$1" fixe="$2" k="$3" num_ctx num_predict sys_car fixe_car
  num_ctx=$(parametre_modele "$modele" num_ctx)
  num_predict=$(parametre_modele "$modele" num_predict)
  [ -n "$num_ctx" ] || erreur "Le modèle $modele doit définir PARAMETER num_ctx."
  [ -n "$num_predict" ] && [ "$num_predict" -gt 0 ] ||
    erreur "Le modèle $modele doit définir PARAMETER num_predict (> 0) : sans limite de réponse, la taille du prompt ne peut pas être garantie."
  sys_car=$(ollama show "$modele" --system | wc -m)
  fixe_car=$(printf '%s' "$fixe" | wc -m)
  awk -v ctx="$num_ctx" -v np="$num_predict" -v k="$k" -v s="$sys_car" \
      -v f="$fixe_car" -v r="$CAR_PAR_TOKEN" -v m="$MARGE_TOKENS" 'BEGIN {
    t = ctx - k * np - int((s + f) / r + 1) - m
    print (t > 0 ? int(t * r) : 0)
  }'
}

# Découpe un document Markdown en tranches dossier/001.md, 002.md...
# Une tranche ne dépasse jamais max_mots mots ni max_car caractères ; une
# ligne trop longue est elle-même coupée entre deux mots. On coupe de
# préférence sur un titre (# ou ##) dès que la tranche a au moins MIN_MOTS mots.
decouper() {
  local src="$1" dossier="$2" max_mots="$3" max_car="$4"
  mkdir -p "$dossier"
  rm -f "$dossier"/*.md
  awk -v max="$max_mots" -v maxc="$max_car" -v min="$MIN_MOTS" -v d="$dossier" '
  function nouvelle() { if (f != "") close(f); n++; f = sprintf("%s/%03d.md", d, n); w = 0; c = 0 }
  function ajouter(ligne, nm, nc) {
    if (w > 0 && (w + nm > max || c + nc + 1 > maxc)) nouvelle()
    print ligne > f; w += nm; c += nc + 1
  }
  BEGIN { nouvelle() }
  {
    if (/^##? / && w >= min && w > 0) nouvelle()
    if (NF <= max && length($0) < maxc) { ajouter($0, NF, length($0)); next }
    # Ligne trop longue : on la recompose morceau par morceau.
    morceau = ""; nm = 0
    for (i = 1; i <= NF; i++) {
      mot = $i
      while (length(mot) >= maxc) {            # mot démesuré (URL, base64...)
        if (nm > 0) { ajouter(morceau, nm, length(morceau)); morceau = ""; nm = 0 }
        ajouter(substr(mot, 1, maxc - 1), 1, maxc - 1)
        mot = substr(mot, maxc)
      }
      essai = (nm ? morceau " " mot : mot)
      if (nm > 0 && (nm + 1 > max || length(essai) >= maxc)) {
        ajouter(morceau, nm, length(morceau)); essai = mot; nm = 0
      }
      morceau = essai; nm++
    }
    if (nm > 0) ajouter(morceau, nm, length(morceau))
  }' "$src"
}

verifier_batterie() {
  local bat niveau statut
  for bat in /sys/class/power_supply/BAT*; do
    if [ -r "$bat/capacity" ]; then
      niveau=$(cat "$bat/capacity")
      statut=$(cat "$bat/status")
      if [ "$statut" = "Discharging" ] && [ "$niveau" -lt 20 ]; then
        echo "Batterie à $niveau % et non branchée : arrêt. Relance le script une fois sur secteur." >&2
        exit 2
      fi
    fi
  done
}

temperature_max() {
  local max=0 z t tg
  for z in /sys/class/thermal/thermal_zone*/temp; do
    if [ -r "$z" ]; then
      t=$(( $(cat "$z") / 1000 ))
      if [ "$t" -gt "$max" ]; then max=$t; fi
    fi
  done
  if command -v nvidia-smi > /dev/null; then
    tg=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits | tr -d '\r' | awk '{v = $1 + 0; if (v > max) max = v} END {print int(max + 0.5)}')
    if [ "$tg" -gt "$max" ]; then max=$tg; fi
  fi
  echo "$max"
}

# À appeler avant chaque requête : batterie puis température.
avant_appel() {
  verifier_batterie
  while [ "$(temperature_max)" -ge "$TEMP_MAX" ]; do
    echo "  Température élevée, pause de 30 s..." >&2
    sleep 30
  done
}

# Envoie l'entrée standard au modèle et écrit la réponse sur la sortie standard.
# --nowordwrap : une ligne de liste ne doit jamais être coupée en deux.
appeler_modele() {
  ollama run "$1" --think=false --nowordwrap
}
