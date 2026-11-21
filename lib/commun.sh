# Fonctions communes aux scripts d'extraction (à sourcer, pas à exécuter).
#
# Variables d'environnement reconnues :
#   QUESTION_MAX   longueur maximale prévue d'une question, en caractères, pour
#                  calculer la taille des tranches au découpage (défaut 500)
#   CAR_PAR_TOKEN  ratio prudent caractères/token pour les estimations (défaut 2.5 ;
#                  ~4,3 mesuré sur du français avec gemma4)
#   MARGE_TOKENS   réserve pour le gabarit de conversation et les en-têtes (défaut 256)
#   RATIO_MAX      ratio caractères/token au-delà duquel la réponse est rejetée :
#                  le prompt a sans doute été tronqué (défaut 8 ; ~4 mesuré)
#   CIBLE_CTX      part maximale de num_ctx occupée par l'extrait, pour la
#                  qualité de l'extraction (défaut 0.35)
#   TEMP_MAX       température (°C) au-delà de laquelle on fait une pause (défaut 90)
#   PAUSE_MAX      durée maximale (s) d'une pause pour température : au-delà,
#                  arrêt du script (défaut 600)
#   OLLAMA_URL     adresse du serveur ollama          (défaut http://127.0.0.1:11434)
#   DEBUG_DOSSIER  si défini, dossier où chaque appel enregistre sa requête et
#                  la réponse brute d'ollama (voir appeler_modele)

QUESTION_MAX="${QUESTION_MAX:-500}"
CAR_PAR_TOKEN="${CAR_PAR_TOKEN:-2.5}"
MARGE_TOKENS="${MARGE_TOKENS:-256}"
RATIO_MAX="${RATIO_MAX:-8}"
CIBLE_CTX="${CIBLE_CTX:-0.35}"
TEMP_MAX="${TEMP_MAX:-90}"
PAUSE_MAX="${PAUSE_MAX:-600}"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
OLLAMA_URL="${OLLAMA_URL%/}"

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

erreur() { echo "$*" >&2; exit 1; }

for _commande in ollama curl jq; do
  command -v "$_commande" > /dev/null || erreur "Commande introuvable : $_commande (nécessaire aux scripts d'extraction)."
done
unset _commande

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

# Numéro d'une tranche d'après son nom : dossier/043.md -> 43.
indice_tranche() {
  local b
  b=$(basename "$1" .md)
  echo $((10#$b))
}

# Index fictif utilisé pour estimer le texte fixe : au moins aussi long que
# tout index réel.
INDEX_BUDGET=99999

# Écrit sur la sortie standard le prompt complet envoyé au modèle. La section
# VARIABLE, secondaire, vient en tête ; viennent ensuite les sections données
# puis la consigne :
#   === VARIABLE ===
#   index=<index>
#
#   === <titre> ===
#   <contenu du fichier>
#   (...)
#   <consigne>
# Usage : prompt_complet index consigne titre1 fichier1 [titre2 fichier2...]
# Un texte (la question...) se passe par substitution : <(printf '%s\n' "$texte").
# Pour le budget, appeler avec INDEX_BUDGET et /dev/null à la place des
# contenus variables (extrait, notes) : on obtient exactement le texte fixe.
prompt_complet() {
  local index="$1" consigne="$2"
  shift 2
  printf '=== VARIABLE ===\nindex=%s\n\n' "$index"
  while [ $# -ge 2 ]; do
    printf '=== %s ===\n' "$1"
    cat "$2"
    echo
    shift 2
  done
  printf '%s\n' "$consigne"
}

# Nombre maximal de caractères d'une tranche : le plus petit de deux plafonds,
# convertis en caractères avec CAR_PAR_TOKEN.
# 1. Limite dure, pour que le prompt complet tienne dans le contexte :
#      num_ctx - k * num_predict - système - texte fixe - marge
#    texte fixe = sortie de prompt_complet sans extrait ni notes (index compris),
#    passé en nombre de caractères.
#    k = nombre de blocs de taille num_predict à réserver : 1 pour la réponse,
#    2 en refine (les notes relues sont une réponse précédente, donc bornées par
#    num_predict, plus la nouvelle réponse).
# 2. Plafond de qualité : CIBLE_CTX * num_ctx. Un petit modèle oublie des
#    éléments et invente bien avant de remplir sa fenêtre ; ce plafond ne porte
#    que sur l'extrait, la partie que le modèle doit parcourir en entier.
# Les deux valeurs sont affichées sur la sortie d'erreur.
# Usage : budget_tranche modele caracteres_texte_fixe k
budget_tranche() {
  local modele="$1" fixe_car="$2" k="$3" num_ctx num_predict sys_car
  num_ctx=$(parametre_modele "$modele" num_ctx)
  num_predict=$(parametre_modele "$modele" num_predict)
  [ -n "$num_ctx" ] || erreur "Le modèle $modele doit définir PARAMETER num_ctx."
  [ -n "$num_predict" ] && [ "$num_predict" -gt 0 ] ||
    erreur "Le modèle $modele doit définir PARAMETER num_predict (> 0) : sans limite de réponse, la taille du prompt ne peut pas être garantie."
  sys_car=$(ollama show "$modele" --system | wc -m)
  awk -v modele="$modele" -v ctx="$num_ctx" -v np="$num_predict" -v k="$k" -v s="$sys_car" \
      -v f="$fixe_car" -v r="$CAR_PAR_TOKEN" -v m="$MARGE_TOKENS" \
      -v c="$CIBLE_CTX" 'BEGIN {
    if (!(c + 0 > 0 && c + 0 <= 1)) {
      print "CIBLE_CTX doit être un nombre compris entre 0 (exclu) et 1 : " c > "/dev/stderr"
      exit 1
    }
    t = ctx - k * np - int((s + f) / r + 1) - m
    dure = (t > 0 ? int(t * r) : 0)
    cible = int(c * ctx * r)
    printf "%s : tranche de %d caractères au plus (contexte), %d (CIBLE_CTX %s).\n", modele, dure, cible, c > "/dev/stderr"
    print (dure < cible ? dure : cible)
  }'
}

# Découpe un document Markdown en tranches dossier/001.md, 002.md...
# Une tranche ne dépasse jamais max_car caractères (fin de ligne comprise) ;
# une ligne trop longue est elle-même coupée entre deux mots. On coupe de
# préférence sur un titre (# ou ##) dès que la tranche atteint le quart de
# max_car.
decouper() {
  local src="$1" dossier="$2" max_car="$3"
  mkdir -p "$dossier"
  rm -f "$dossier"/*.md
  awk -v maxc="$max_car" -v min="$((max_car / 4))" -v d="$dossier" '
  function nouvelle() { if (f != "") close(f); n++; f = sprintf("%s/%03d.md", d, n); c = 0 }
  function ajouter(ligne, nc) {
    if (c > 0 && c + nc + 1 > maxc) nouvelle()
    print ligne > f; c += nc + 1
  }
  BEGIN { nouvelle() }
  {
    if (/^##? / && c >= min) nouvelle()
    if (length($0) < maxc) { ajouter($0, length($0)); next }
    # Ligne trop longue : on la recompose morceau par morceau.
    morceau = ""
    for (i = 1; i <= NF; i++) {
      mot = $i
      while (length(mot) >= maxc) {            # mot démesuré (URL, base64...)
        if (morceau != "") { ajouter(morceau, length(morceau)); morceau = "" }
        ajouter(substr(mot, 1, maxc - 1), maxc - 1)
        mot = substr(mot, maxc)
      }
      essai = (morceau != "" ? morceau " " mot : mot)
      if (morceau != "" && length(essai) >= maxc) {
        ajouter(morceau, length(morceau)); essai = mot
      }
      morceau = essai
    }
    if (morceau != "") ajouter(morceau, length(morceau))
  }' "$src"
}

# Prépare une série de résultats dans un dossier de travail découpé par
# decouper.sh. Une série (dossier travail/<nom>) regroupe les réponses à une
# question, un fichier par tranche, nommé comme la tranche (012.md).
# L'en-tête (mode, langue, question) est enregistré dans <nom>/question.txt :
# une série ne peut pas être reprise avec un autre en-tête.
# Définit les variables globales :
#   SERIE     dossier de la série
#   DE, A     numéros de la première et de la dernière tranche traitées
#   TRANCHES  fichiers des tranches DE à A, dans l'ordre
# À appeler directement (pas dans $(...)), sinon les variables sont perdues.
# Usage : preparer_serie travail nom entete [de] [a]
preparer_serie() {
  local travail="$1" nom="$2" entete="$3" toutes nb
  DE="${4:-1}"
  [ -f "$travail/decoupage.txt" ] ||
    erreur "$travail n'est pas un dossier de travail : lance d'abord decouper.sh."
  case "$nom" in
    "" | */* | . | .. | tranches) erreur "Nom de série invalide : $nom" ;;
  esac
  mapfile -t toutes < <(find "$travail/tranches" -maxdepth 1 -type f -name '*.md' | sort -V)
  nb=${#toutes[@]}
  [ "$nb" -gt 0 ] || erreur "Aucune tranche dans $travail/tranches."
  A="${5:-$nb}"
  [[ "$DE" =~ ^[0-9]+$ && "$A" =~ ^[0-9]+$ ]] || erreur "Intervalle invalide : $DE à $A."
  DE=$((10#$DE)); A=$((10#$A))
  [ "$DE" -ge 1 ] && [ "$DE" -le "$A" ] && [ "$A" -le "$nb" ] ||
    erreur "Intervalle invalide : $DE à $A (tranches 1 à $nb)."
  TRANCHES=("${toutes[@]:DE-1:A-DE+1}")

  SERIE="$travail/$nom"
  mkdir -p "$SERIE"
  if [ -f "$SERIE/question.txt" ]; then
    [ "$(cat "$SERIE/question.txt")" = "$entete" ] ||
      erreur "La série $SERIE a été créée pour une autre question ou un autre mode (voir $SERIE/question.txt) : choisis un autre nom de série."
  else
    printf '%s\n' "$entete" > "$SERIE/question.txt"
  fi
  echo "Série $SERIE, tranches $DE à $A (sur $nb)." >&2
}

# Vérifie que chaque tranche de TRANCHES tient dans le budget de ce modèle
# pour cette question. Le découpage a été dimensionné pour une question d'au
# plus QUESTION_MAX caractères ; une question plus longue, ou un modèle avec
# moins de contexte, peut ne plus convenir.
# Usage : verifier_tranches modele caracteres_texte_fixe k
verifier_tranches() {
  local modele="$1" fixe_car="$2" k="$3" max f n plus_grande=0 laquelle=""
  max=$(budget_tranche "$modele" "$fixe_car" "$k")
  for f in "${TRANCHES[@]}"; do
    n=$(wc -m < "$f")
    if [ "$n" -gt "$plus_grande" ]; then plus_grande=$n; laquelle=$f; fi
  done
  [ "$plus_grande" -le "$max" ] ||
    erreur "La tranche $laquelle fait $plus_grande caractères, $max au plus pour $modele avec cette question. Raccourcis la question, ou redécoupe le document dans un autre dossier de travail avec une taille plus petite (decouper.sh -t)."
}

# Numéro sur trois chiffres : 7 -> 007.
num() { printf '%03d' "$1"; }

# Contrôle du matériel : sans mesure fiable de la température et de la
# batterie, aucun appel au modèle. Un capteur absent, illisible ou qui donne une
# valeur impossible arrête le script avec un message, au lieu de désactiver le
# contrôle sans le dire.

erreur_materiel() {
  erreur "Contrôle du matériel impossible : $1. Aucun appel au modèle sans mesure fiable de la température et de la batterie."
}

# Températures valides, en °C : en dehors, le capteur est en panne (0, 127,
# -273... sont des valeurs d'erreur courantes).
TEMP_VALIDE_MIN=1
TEMP_VALIDE_MAX=124

# Écrit « capteur valeur », une ligne par capteur de température (°C) :
# capteurs hwmon (processeur, GPU AMD ou Intel, SSD...), zones thermiques, et
# GPU NVIDIA par nvidia-smi s'il est installé. Linux donne toujours ces valeurs
# en millièmes de degré Celsius, nvidia-smi en degrés Celsius.
# Échoue (erreur_materiel) si un capteur est illisible ou hors des valeurs
# valides, ou si aucun capteur n'est trouvé.
lire_temperatures() {
  local f v nom n=0 sortie
  for f in /sys/class/hwmon/hwmon*/temp*_input /sys/class/thermal/thermal_zone*/temp; do
    [ -e "$f" ] || continue
    case "$f" in
      */hwmon/*) nom="$(cat "${f%/*}/name" 2> /dev/null || echo hwmon)/$(basename "$f" _input)" ;;
      *) nom="$(cat "${f%/*}/type" 2> /dev/null || echo zone)" ;;
    esac
    v=$(cat "$f" 2> /dev/null) || erreur_materiel "capteur $nom illisible ($f)"
    [[ "$v" =~ ^-?[0-9]+$ ]] || erreur_materiel "capteur $nom : valeur « $v » non numérique ($f)"
    v=$((v / 1000))
    [ "$v" -ge "$TEMP_VALIDE_MIN" ] && [ "$v" -le "$TEMP_VALIDE_MAX" ] ||
      erreur_materiel "capteur $nom : $v °C, valeur impossible ($f)"
    echo "$nom $v"
    n=$((n + 1))
  done
  if command -v nvidia-smi > /dev/null; then
    sortie=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>&1) ||
      erreur_materiel "nvidia-smi en erreur : $sortie"
    while read -r v; do
      v=${v//[$' \r']/}
      [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || erreur_materiel "nvidia-smi : température « $v » non numérique"
      v=${v%%.*}
      [ "$v" -ge "$TEMP_VALIDE_MIN" ] && [ "$v" -le "$TEMP_VALIDE_MAX" ] ||
        erreur_materiel "nvidia-smi : $v °C, valeur impossible"
      echo "nvidia-smi $v"
      n=$((n + 1))
    done <<< "$sortie"
  fi
  [ "$n" -gt 0 ] || erreur_materiel "aucun capteur de température trouvé (/sys/class/hwmon, /sys/class/thermal, nvidia-smi)"
}

# Écrit « nom capacité statut », une ligne par batterie de l'ordinateur (rien
# pour un ordinateur fixe). Les batteries d'appareils (souris, casque...) sont
# ignorées. Échoue (erreur_materiel) si une batterie est illisible.
lire_batteries() {
  local p nom cap statut
  for p in /sys/class/power_supply/*; do
    [ "$(cat "$p/type" 2> /dev/null)" = Battery ] || continue
    [ "$(cat "$p/scope" 2> /dev/null)" != Device ] || continue
    nom=$(basename "$p")
    cap=$(cat "$p/capacity" 2> /dev/null) || erreur_materiel "batterie $nom : charge illisible ($p/capacity)"
    [[ "$cap" =~ ^[0-9]+$ ]] && [ "$cap" -le 100 ] ||
      erreur_materiel "batterie $nom : charge « $cap » impossible"
    statut=$(cat "$p/status" 2> /dev/null) || erreur_materiel "batterie $nom : état illisible ($p/status)"
    case "$statut" in
      Charging | Discharging | Full | "Not charging" | Unknown) ;;
      *) erreur_materiel "batterie $nom : état « $statut » inconnu" ;;
    esac
    echo "$nom $cap $statut"
  done
}

# Arrête le script (code 2) si une batterie se décharge sous 20 %.
verifier_batterie() {
  local batteries nom cap statut
  batteries=$(lire_batteries) || exit 1
  while read -r nom cap statut; do
    [ -n "$nom" ] || continue
    if [ "$statut" = Discharging ] && [ "$cap" -lt 20 ]; then
      echo "Batterie à $cap % et non branchée : arrêt. Relance le script une fois sur secteur." >&2
      exit 2
    fi
  done <<< "$batteries"
}

# Plus haute température : « valeur capteur ».
temperature_max() {
  awk '{ v = $NF; $NF = ""; sub(/ $/, ""); if (NR == 1 || v + 0 > m) { m = v + 0; c = $0 } }
       END { print m, c }' <<< "$1"
}

# À appeler une fois au lancement, avant tout appel au modèle : affiche les
# mesures et arrête le script si elles ne sont pas fiables.
etat_materiel() {
  local mesures batteries max capteur nom cap statut
  mesures=$(lire_temperatures) || exit 1
  batteries=$(lire_batteries) || exit 1
  read -r max capteur <<< "$(temperature_max "$mesures")"
  echo "Températures : $(wc -l <<< "$mesures") capteurs, la plus haute $max °C ($capteur) ; pause à $TEMP_MAX °C, arrêt après $PAUSE_MAX s de pause." >&2
  if [ -z "$batteries" ]; then
    echo "Batterie : aucune (ordinateur fixe)." >&2
  else
    while read -r nom cap statut; do
      echo "Batterie $nom : $cap %, $statut." >&2
    done <<< "$batteries"
  fi
  verifier_batterie
}

# À appeler avant chaque requête : batterie puis température. Pause tant que la
# température atteint TEMP_MAX, arrêt (code 2) si elle y reste plus de PAUSE_MAX s.
avant_appel() {
  local mesures max capteur debut=$SECONDS
  verifier_batterie
  while :; do
    mesures=$(lire_temperatures) || exit 1
    read -r max capteur <<< "$(temperature_max "$mesures")"
    [ "$max" -ge "$TEMP_MAX" ] || break
    if [ $((SECONDS - debut)) -ge "$PAUSE_MAX" ]; then
      echo "Température toujours à $max °C ($capteur) après $PAUSE_MAX s de pause : arrêt. Vérifie le refroidissement, puis relance : la reprise repart de cette tranche." >&2
      exit 2
    fi
    echo "  Température élevée ($max °C, $capteur), pause de 30 s..." >&2
    sleep 30
  done
}

# Prévient si le modèle ne tient pas entièrement dans la mémoire du GPU (VRAM).
# Ollama ne renvoie pas d'erreur dans ce cas : il place une partie des couches
# sur le processeur, et le modèle devient plus lent. Les poids du modèle
# comptent le plus ; num_ctx ajoute environ 670 Mo par tranche de 12 288 tokens
# avec gemma4 12B (sur 8 Go : 40 couches sur 49 avec num_ctx 4096, 39 avec 12288).
# « ollama ps » n'est pas fiable pour cela (ollama 0.40 : il affiche « 100% GPU »
# alors qu'une partie du modèle est sur le processeur). On lit donc le journal
# d'ollama : dernier chargement du fichier du modèle (ligne FROM du Modelfile),
# puis la ligne « offloaded N/M layers to GPU » qui suit.
# Ne vérifie rien (avec un message) si le journal est inaccessible : ollama
# lancé à la main avec « ollama serve », pas de systemd, droits insuffisants...
# Usage : verifier_vram modele
verifier_vram() {
  local modele="$1" fichier couches sur_gpu total
  fichier=$(ollama show --modelfile "$modele" 2> /dev/null | awk '$1 == "FROM" { print $2; exit }')
  if [ -n "$fichier" ] && command -v journalctl > /dev/null; then
    couches=$(journalctl -u ollama --since "-30min" --no-pager -o cat 2> /dev/null | awk -v f="$fichier" '
      index($0, "load_model: loading model") && index($0, f) { attente = 1; next }
      attente && match($0, /offloaded [0-9]+\/[0-9]+ layers/) {
        r = substr($0, RSTART + 10, RLENGTH - 17); attente = 0
      }
      END { print r }')
  fi
  if [ -z "${couches:-}" ]; then
    echo "  VRAM non vérifiée : chargement de $modele introuvable dans le journal d'ollama (journalctl -u ollama)." >&2
    return 0
  fi
  sur_gpu=${couches%/*}
  total=${couches#*/}
  if [ "$sur_gpu" -lt "$total" ]; then
    echo "  Attention : $sur_gpu couches sur $total de $modele tiennent dans la mémoire du GPU, les autres tournent sur le processeur (plus lent). Ferme les programmes qui utilisent le GPU, réduis num_ctx dans le Modelfile, ou, si même un petit num_ctx ne suffit pas, prends un modèle plus petit." >&2
  else
    echo "  VRAM : $modele tient entièrement dans la mémoire du GPU ($total couches)." >&2
  fi
}

# Affiche le ratio réel caractères/token du prompt qui vient d'être envoyé, et
# prévient s'il est inférieur à CAR_PAR_TOKEN : l'estimation du budget n'est
# alors pas prudente pour ce document.
# Échoue (code 1) s'il dépasse RATIO_MAX : le modèle a lu beaucoup moins de
# tokens que le texte n'en contient, le prompt a donc été tronqué. Contrôle de
# secours : la requête interdit déjà la troncature (voir appeler_modele).
# Caractères = prompt système + message, comme dans budget_tranche.
# Le ratio est approché : prompt_eval_count compte aussi les tokens du gabarit
# de conversation (ratio un peu trop bas), mais peut exclure un début de prompt
# déjà en cache (ratio trop haut). Voir TESTS-A-FAIRE.md.
# Usage : verifier_ratio modele requete_json prompt_eval_count
verifier_ratio() {
  local modele="$1" requete="$2" n_prompt="$3" n_car sys_car
  [ "$n_prompt" -gt 0 ] || return 0
  n_car=$(jq '.messages[0].content | length' <<< "$requete")
  sys_car=$(ollama show "$modele" --system | wc -m)
  awk -v c=$((n_car + sys_car)) -v t="$n_prompt" -v r="$CAR_PAR_TOKEN" -v rmax="$RATIO_MAX" 'BEGIN {
    ratio = c / t
    printf "  ratio mesuré : %.2f caractères/token (%d car. / %d tokens)\n", ratio, c, t
    if (ratio < r)
      printf "  Attention : ratio mesuré inférieur à CAR_PAR_TOKEN (%s) : le budget de contexte est sous-estimé pour ce document. Réduis CAR_PAR_TOKEN.\n", r
    if (ratio > rmax + 0) {
      printf "  Ratio mesuré supérieur à RATIO_MAX (%s) : le modèle a lu bien moins de tokens que le texte en contient : le prompt a sans doute été tronqué.\n", rmax
      exit 1
    }
  }' >&2
}

# Envoie l'entrée standard au modèle et écrit la réponse sur la sortie standard.
# Passe par l'API /api/chat plutôt que par « ollama run », qui ne dit pas
# pourquoi la génération s'est arrêtée. Le SYSTEM et les PARAMETER du Modelfile
# s'appliquent comme avec « ollama run ».
#
# Échoue (code 1, rien sur la sortie standard) si :
#   - le serveur ne répond pas ou renvoie une erreur, en particulier si le
#     prompt dépasse num_ctx (truncate: false) ou si prompt + réponse le
#     dépassent pendant l'écriture (shift: false) : sans ces deux champs,
#     ollama tronque le prompt à num_ctx/2 ou oublie le début du contexte,
#     sans le signaler ;
#   - la réponse a été coupée par num_predict (done_reason = length) ;
#   - prompt + num_predict dépasse num_ctx : le budget estimé était faux et
#     ollama a pu tronquer le prompt ou décaler le contexte ;
#   - le ratio caractères/token dépasse RATIO_MAX (troncature, contrôle de
#     secours).
# L'appelant ne doit donc enregistrer la réponse que si l'appel réussit.
#
# Limite connue : si ollama réutilise un début de prompt déjà en cache,
# prompt_eval_count peut ne compter que la partie nouvelle, et le second
# contrôle peut alors manquer un dépassement (à vérifier, voir TESTS-A-FAIRE.md).
#
# Si DEBUG_DOSSIER est défini, chaque appel y laisse trois fichiers, préfixés
# par la date, le modèle et le numéro de tranche (lu dans « index=<n> ») :
#   .requete.json  requête envoyée (rejouable avec curl --data-binary @fichier)
#   .prompt.txt    texte du message, lisible
#   .reponse.json  réponse complète d'ollama, même si l'appel est rejeté
appeler_modele() {
  local modele="$1" requete reponse champs raison n_prompt n_reponse num_ctx num_predict
  local vitesse chargement
  local base="" index ok
  requete=$(jq -Rs --arg m "$modele" \
    '{model: $m, messages: [{role: "user", content: .}], stream: false, think: false,
                       truncate: false, shift: false}') ||
    erreur "Impossible de construire la requête JSON."
  if [ -n "${DEBUG_DOSSIER:-}" ]; then
    mkdir -p "$DEBUG_DOSSIER"
    index=$(jq -r '.messages[0].content' <<< "$requete" | sed -n 's/^index=\([0-9][0-9]*\)$/\1/p' | head -n 1)
    base="$DEBUG_DOSSIER/$(date '+%Y%m%d-%H%M%S')-$BASHPID-$modele-tranche${index:-x}"
    printf '%s\n' "$requete" > "$base.requete.json"
    jq -r '.messages[0].content' <<< "$requete" > "$base.prompt.txt"
  fi
  if reponse=$(curl -sS --fail-with-body -X POST "$OLLAMA_URL/api/chat" \
      -H 'Content-Type: application/json' --data-binary @- <<< "$requete"); then
    ok=1
  else
    ok=0
  fi
  if [ -n "$base" ]; then printf '%s\n' "$reponse" > "$base.reponse.json"; fi
  [ "$ok" -eq 1 ] || erreur "Échec de l'appel à ollama ($OLLAMA_URL) : ${reponse:-pas de réponse}"

  champs=$(jq -r '[.done_reason // "", .prompt_eval_count // 0, .eval_count // 0,
      (if (.eval_duration // 0) > 0 then .eval_count / .eval_duration * 1e9 | floor else 0 end),
      ((.load_duration // 0) / 1e9 | floor)] | @tsv' <<< "$reponse") ||
    erreur "Réponse d'ollama illisible : $reponse"
  IFS=$'\t' read -r raison n_prompt n_reponse vitesse chargement <<< "$champs"
  num_ctx=$(parametre_modele "$modele" num_ctx)
  num_predict=$(parametre_modele "$modele" num_predict)
  echo "  prompt : $n_prompt tokens, réponse : $n_reponse tokens à $vitesse tokens/s (num_ctx $num_ctx, num_predict $num_predict)" >&2
  # Le modèle vient d'être chargé (en général au premier appel d'un script) :
  # vérifier qu'il tient dans la mémoire du GPU.
  if [ "$chargement" -ge 1 ]; then verifier_vram "$modele"; fi
  verifier_ratio "$modele" "$requete" "$n_prompt" ||
    erreur "Prompt tronqué par ollama ($n_prompt tokens lus) : redécoupe le document avec des tranches plus petites (decouper.sh -t). Rien n'est enregistré pour cette tranche."

  if [ "$raison" = "length" ]; then
    erreur "Réponse coupée par num_predict ($n_reponse tokens) : augmente num_predict, ou redécoupe le document avec des tranches plus petites (decouper.sh -t). Rien n'est enregistré pour cette tranche."
  fi
  if [ $((n_prompt + num_predict)) -gt "$num_ctx" ]; then
    erreur "Prompt de $n_prompt tokens + num_predict $num_predict > num_ctx $num_ctx : le prompt a pu être tronqué. Réduis CAR_PAR_TOKEN et redécoupe le document. Rien n'est enregistré pour cette tranche."
  fi
  jq -r '.message.content // ""' <<< "$reponse"
}
