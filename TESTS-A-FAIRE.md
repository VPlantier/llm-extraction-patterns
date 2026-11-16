# Propositions et tests à faire

## Problèmes observés

Trois limites peuvent être dépassées ; aucune n'est signalée par `ollama run`.

| Dépassement | Ce qu'ollama coupe | Conséquence |
|---|---|---|
| prompt > `num_ctx` | le **début** du prompt (le système en premier) | le modèle ne connaît plus le format ni les règles |
| prompt + réponse > `num_ctx` | la moitié la plus ancienne du contexte, pendant l'écriture | la suite de la réponse est écrite sans consignes ni début de l'extrait |
| réponse > `num_predict` | la **fin** de la réponse, parfois au milieu d'un mot | éléments perdus, dernière ligne incomplète gardée comme un élément |

Le code faisait seulement du dimensionnement préventif : il calculait une taille de
tranche à partir d'une estimation de 2,5 caractères par token. Après l'appel, il ne
vérifiait rien. Une réponse coupée ou fausse était enregistrée puis réutilisée, et
une reprise ne la refaisait pas.

Autre risque, de qualité cette fois : un petit modèle se dégrade (oublis,
hallucinations) bien avant de remplir sa fenêtre. Avec les réglages par défaut, le
prompt en occupait environ 30 %, mais rien n'empêchait d'aller beaucoup plus haut.

Enfin, la taille des tranches était recalculée à chaque lancement (modèle, longueur
de la question, réglages). Le numéro de tranche n'était donc pas un repère stable :
impossible de poser une seconde question sur les mêmes tranches ou de viser un
intervalle de tranches.

## Propositions

| # | Proposition | État |
|---|---|---|
| 1 | Appeler `/api/chat` (curl + jq) au lieu de `ollama run`, pour connaître `done_reason`, `prompt_eval_count` et `eval_count` | **écrit, non testé** |
| 2 | Vérifier chaque réponse : arrêt sans rien enregistrer si `done_reason` = `length` ou si `prompt_eval_count` + `num_predict` > `num_ctx` ; écriture dans un `.tmp` puis renommage | **écrit, non testé** |
| 3 | Afficher le ratio réel caractères/token de chaque prompt, et prévenir s'il est inférieur à `CAR_PAR_TOKEN` | **écrit, non testé** |
| 4 | `CIBLE_CTX` (part de `num_ctx` occupée par l'extrait, 0,35 par défaut) : la limite d'un modèle est la plus petite de la limite dure et de ce plafond de qualité | **écrit, non testé** |
| 5 | Consignes de longueur **par ligne**, sans limite sur le nombre d'éléments (le modèle omettrait des éléments sans le dire, et le « dernier » de premier-dernier serait faux) : idée générale ≤ 6 mots, précision ≤ 15 mots (refine, map-reduce), contexte ≤ 5 mots (premier-dernier), et consigne de raccourcir plutôt que d'omettre | **écrit, non testé** |
| 6 | Documentation (LISEZMOI.md, README.md) à jour pour les points 1 à 7 | fait |
| 7 | Découpage unique dans un dossier de travail (`decouper.sh`), une série de résultats par question, intervalle de tranches (`-d`/`-a`), notes de départ écrites à la main en refine | **écrit, non testé** |
| 8 | `DEBUG_DOSSIER` : chaque appel enregistre sa requête (rejouable avec `curl`), le prompt lisible et la réponse brute d'ollama, pour pouvoir tester sans lire le code | **écrit, non testé** |

À plus long terme : quand une tranche est rejetée, la redécouper en deux
automatiquement au lieu d'arrêter le script.

### Points 1 et 2 : appel par l'API et contrôle des réponses

- `appeler_modele` (`lib/commun.sh`) renvoie un code d'erreur et n'écrit rien sur la
  sortie standard quand la réponse est rejetée. Les trois scripts s'arrêtent alors
  sans enregistrer de fichier pour la tranche ; une reprise la refait.
- Les avertissements approximatifs de premier-dernier ont été retirés. Celui de refine
  (notes qui perdent plus de la moitié de leurs mots) est conservé : il signale que le
  modèle a peut-être abandonné des éléments, pas une coupure.
- Les scripts vérifient au démarrage que `ollama`, `curl` et `jq` sont présents.

Limite connue : si ollama réutilise un début de prompt déjà en cache (le prompt
système est le même à chaque appel), `prompt_eval_count` peut ne compter que la
partie nouvelle. Le contrôle du contexte et le ratio du point 3 peuvent alors être
faussés (test 2.2).

### Point 7 : découpage unique et séries

- `decouper.sh` découpe une fois pour toutes dans `travail/tranches/`. Sans `-t`, la
  taille est la plus grande qui convienne à tous les modèles retenus (`-m`) pour une
  question d'au plus `QUESTION_MAX` caractères ; avec `-t`, la taille est refusée si
  elle dépasse ce maximum. Un dossier déjà découpé n'est jamais redécoupé.
- `MAX_MOTS` et `MIN_MOTS` disparaissent : la taille est en caractères et enregistrée
  dans `travail/decoupage.txt`.
- Chaque mode écrit dans une série `travail/<nom>/`, un fichier par tranche nommé
  comme elle. `question.txt` empêche de reprendre une série avec une autre question.
- À chaque lancement, la plus grande tranche de l'intervalle est comparée à la limite
  du modèle pour la vraie question ; arrêt avant tout appel si elle dépasse.
- `-d`/`-a` limitent le traitement à un intervalle. En refine, les notes de départ
  sont le fichier `de-1` de la série : s'il existe (écrit à la main), il est utilisé
  tel quel. Pas d'enchaînement automatique, pour ne pas cumuler les hallucinations.
- Corrigé au passage : `fusion.sh` ne trouvait `extraction.awk` que lancé depuis la
  racine du dépôt.

# Tests à faire

Tout a été écrit sans ollama ni jq. Ce qui a déjà été vérifié sans eux est indiqué
en tête de section ; le reste est à faire sur une machine où ollama est installé.
Noter pour chaque test la version d'ollama (`ollama --version`) et le résultat obtenu.

Les commandes se lancent depuis la racine du dépôt, sous Linux.

**En cas d'échec d'un test :**

1. Noter la commande exacte, la sortie complète du terminal et le numéro du test.
2. Garder le dossier de travail et le dossier `DEBUG_DOSSIER` (ne pas les effacer) :
   la requête envoyée et la réponse brute d'ollama s'y trouvent.
3. Repérer la fonction concernée dans `lib/commun.sh` d'après le message :
   - appel au modèle, réponse rejetée, ratio : `appeler_modele`, `verifier_ratio` ;
   - « tranche ... fait N caractères » : `verifier_tranches`, `budget_tranche` ;
   - série, intervalle, `question.txt` : `preparer_serie` ;
   - taille ou contenu des tranches : `decouper` (et `decouper.sh`).
4. Pour un problème de qualité (réponse fausse ou incomplète) sans message d'erreur,
   comparer `.prompt.txt` et `.reponse.json` : le modèle a-t-il reçu le bon extrait et
   la bonne question ? Si oui, le problème vient du modèle ou du Modelfile, pas des scripts.

## 0. Préparation

- Installer les dépendances si besoin : `sudo apt install jq curl` (Debian/Ubuntu).
  Vérifier `curl --version` (7.76 ou plus récent).
- Garder une trace de chaque appel pendant tous les tests :
  ```bash
  export DEBUG_DOSSIER=$PWD/debug
  ```
- Journal du serveur ollama (pour le test 2.1) : `journalctl -u ollama -f` si ollama tourne
  comme service, sinon le terminal où `ollama serve` a été lancé.
- Recréer les six modèles (les Modelfiles ont changé) :
  ```bash
  for d in refine map-reduce premier-dernier; do
    for l in fr en; do ollama create "$d-$l" -f "$d/$d-$l.Modelfile"; done
  done
  ```
- Dossier de travail de référence :
  ```bash
  ./decouper.sh -t 300 exemples/debats.md travail-debats
  ```
- Document long, pour les tests de dépassement (`debats.md` ne fait qu'environ
  1 000 caractères). Il doit dépasser nettement `num_ctx` (12 288 tokens, soit environ
  50 000 caractères de français) : 120 copies font environ 120 000 caractères.
  ```bash
  for i in $(seq 120); do cat exemples/debats.md; echo; done > exemples-long.md
  ```
- Documents réels, dans `documents/` (non versionné ; il faut `pandoc`) :
  ```bash
  mkdir -p documents
  # Tests 6.5, 7.4, 8.x : long débat (référence de température : les « (Exclamations...) »,
  # « (Protestations...) » notées dans le texte). Couper à la main le menu et le pied de page.
  curl -sL "https://www.assemblee-nationale.fr/dyn/17/comptes-rendus/seance/session-ordinaire-de-2025-2026/premiere-seance-du-vendredi-24-octobre-2025" \
    | pandoc -f html -t gfm -o documents/seance.md
  # Test 7.2 : liste dense, avec un critère étroit (« un poisson »), pas « nourriture ».
  for l in B G J; do
    curl -sL "https://fr.wikisource.org/wiki/Dumas.-_Grand_dictionnaire_de_cuisine,_1873/Index_alphab%C3%A9tique_-_$l?action=render" | pandoc -f html -t gfm
  done > documents/dumas.md
  ```
  Test 5.5 : prendre un document chiffré proche des documents réellement traités (ou un
  article Wikipédia en tableaux, converti de la même façon avec `?action=render`).
- **Modèle modifié pour un test.** Les scripts appellent des modèles au nom fixe
  (`map-reduce-fr`...). Pour tester avec d'autres paramètres, on remplace
  temporairement le modèle, puis on le recrée à l'identique :
  ```bash
  sed 's/^PARAMETER num_predict .*/PARAMETER num_predict 16/' map-reduce/map-reduce-fr.Modelfile > /tmp/test.Modelfile
  ollama create map-reduce-fr -f /tmp/test.Modelfile
  # ... test ...
  ollama create map-reduce-fr -f map-reduce/map-reduce-fr.Modelfile
  ```
- **Requête de référence**, pour les tests à la main (1.x, 2.x) : lancer une fois map-reduce
  sur la tranche 2, puis garder la requête enregistrée.
  ```bash
  map-reduce/map-reduce.sh -d 2 -a 2 fr travail-debats ref "Quels sujets sont débattus ?"
  REQ=$(ls "$DEBUG_DOSSIER"/*map-reduce-fr-tranche2.requete.json | tail -n 1)
  # Rejouer une requête et afficher l'essentiel de la réponse :
  rejouer() { curl -s http://127.0.0.1:11434/api/chat --data-binary @"$1" |
              jq '{done_reason, prompt_eval_count, eval_count, contenu: .message.content}'; }
  rejouer "$REQ"
  ```

### Réponses de référence pour `exemples/debats.md`

Avec `./decouper.sh -t 300`, le document donne 4 tranches (vérifier avec `head` qu'elles
correspondent bien à ces paragraphes) :

| Tranche | Contenu | Sujets attendus | Température attendue |
|---|---|---|---|
| 1 | Séance du 12 mars, M. Dupont | réforme de la contribution foncière (sols productifs / non productifs) ; ajustement des droits de traites | basse : débat courtois (environ 10° à 30°) |
| 2 | M. Martin | prix du pain / du blé (doublé dans le Nord) ; suppression des droits d'entrée sur les farines | très haute : cris, menace de suspension (environ 80° à 100°) |
| 3 | Séance du 13 mars, M. Leroy | contribution foncière (opposition à la distinction des sols) | très haute : échange très tendu (environ 75° à 95°) |
| 4 | M. Bernard | fromages et vin de l'Est ; taxe sur le sel ; pommes de terre pour les hôpitaux | basse : calme, sans passion (environ 0° à 25°) |

- Les températures sont des ordres de grandeur : un écart de 20° n'est pas une erreur, une
  inversion (calme noté houleux) en est une.
- Sujet inventé (absent du texte) = erreur. Sujet manquant = erreur.
- La contribution foncière apparaît deux fois (tranches 1 et 3) avec des températures
  différentes : en refine, vérifier que les notes en gardent la trace sans créer deux
  sujets contradictoires sans explication.
- Premier-dernier, critère « un mot qui désigne une forme de nourriture ou d'aliment » :
  la tranche 1 doit répondre AUCUN ; mots attendus dans l'ordre : pain, blé, farines
  (tranche 2), fromages, vin, sel, pommes de terre (tranche 4). Résultat attendu :
  premier « pain », dernier « pommes de terre ». « Vin » et « sel » sont discutables ;
  leur absence n'est pas une erreur.

## 1. Appel par l'API au lieu de `ollama run`

- [ ] **1.1 Champs disponibles.** `rejouer "$REQ"` (voir 0) : les quatre champs
  `done_reason`, `prompt_eval_count`, `eval_count` et `contenu` sont remplis.
- [ ] **1.2 Désactivation du raisonnement.** Comparer avec et sans `think` :
  ```bash
  rejouer "$REQ"
  jq 'del(.think)' "$REQ" > /tmp/sans-think.json; rejouer /tmp/sans-think.json
  ```
  Avec `think: false`, aucun texte de raisonnement dans `contenu`. Noter les deux
  `eval_count`. Si ollama refuse `think` pour ce modèle, le noter : il faudra retirer le champ.
- [ ] **1.3 Prompt système et paramètres.** `rejouer "$REQ"` : la réponse doit suivre le
  format du Modelfile (titre `#` puis lignes `* **...**`), preuve que le SYSTEM est appliqué.
  Pour `num_predict` : le test 3.1 le vérifie.
- [ ] **1.4 Caractères spéciaux.**
  ```bash
  printf '# Essai\n\nIl dit « bonjour » et "salut", chemin C:\\dossier\\fichier, tab:\tici, émoji 🙂, accents éàçù.\n' > /tmp/speciaux.md
  ./decouper.sh -t 300 -m map-reduce-fr /tmp/speciaux.md travail-speciaux
  map-reduce/map-reduce.sh fr travail-speciaux s "Quels éléments sont cités ?"
  diff <(cat travail-speciaux/tranches/001.md) \
       <(sed -n '/^=== EXTRAIT ===$/,/^=== QUESTION ===$/p' "$(ls "$DEBUG_DOSSIER"/*map-reduce-fr-tranche1.prompt.txt | tail -n 1)" | sed '1d;$d' | sed '$d')
  ```
  Résultat attendu : aucune différence (le texte de la tranche se retrouve tel quel dans
  le prompt). Une différence d'une ligne vide en fin de bloc n'est pas une erreur.
- [ ] **1.5 Version de curl.** `--fail-with-body` demande curl 7.76 ou plus récent. Vérifier
  qu'une erreur du serveur (nom de modèle inexistant, par exemple) affiche le message d'ollama.
- [ ] **1.6 Sortie en tokens.** Vérifier que la ligne « prompt : N tokens, réponse : M tokens »
  s'affiche à chaque appel, avec des valeurs plausibles.
- [ ] **1.7 Même résultat qu'avant.** Sur la branche `main`, découper `debats.md` avec
  `MAX_MOTS=80 MIN_MOTS=20` et comparer ses tranches avec `travail-debats/tranches/` : si elles
  sont identiques, comparer la sortie de `premier-dernier` (température 0) des deux versions.
  Sinon, la comparaison n'a pas de sens.

## 2. Détection d'un prompt trop long

- [ ] **2.1 Troncature silencieuse d'origine.** Remplacer le texte de la requête de
  référence par le document long et l'envoyer, en surveillant le journal du serveur :
  ```bash
  jq --rawfile t exemples-long.md '.messages[0].content = $t' "$REQ" > /tmp/long.json
  rejouer /tmp/long.json
  ```
  Résultat attendu : pas d'erreur, un message du genre « truncating input prompt » dans le
  journal, et `prompt_eval_count` ≤ `num_ctx` (12288). Si ollama renvoie une erreur au lieu
  de tronquer, le noter : c'est un meilleur comportement, et le test 2.5 changera.
- [ ] **2.2 Effet du cache sur `prompt_eval_count`.** Envoyer deux fois de suite la même
  requête et comparer :
  ```bash
  rejouer "$REQ" | jq .prompt_eval_count
  rejouer "$REQ" | jq .prompt_eval_count
  ```
  Si la seconde valeur est nettement plus petite, le compteur n'inclut pas la partie en
  cache : le contrôle « prompt + num_predict > num_ctx » et le ratio du point 3 sont alors
  faussés, il faudra les revoir. Le noter dans tous les cas.
- [ ] **2.3 Option qui refuse la troncature.** Dans la documentation de l'API de la version
  installée (fichier `docs/api.md` du dépôt GitHub d'ollama, au tag de la version), chercher
  un champ de requête qui renvoie une erreur au lieu de tronquer (nom possible : `truncate`)
  ou qui empêche le décalage de contexte (nom possible : `shift`). Les noms ne sont pas
  garantis. Si un tel champ existe, l'ajouter à `/tmp/long.json` avec `jq` et refaire 2.1.
  S'il marche, le noter : on pourra l'ajouter dans `appeler_modele`.
- [ ] **2.4 Le contrôle au lancement arrête des tranches trop grandes.** Découper le document
  long avec une estimation volontairement fausse, puis lancer le mode avec les réglages
  normaux :
  ```bash
  CAR_PAR_TOKEN=10 CIBLE_CTX=1 ./decouper.sh -m map-reduce-fr exemples-long.md travail-trop-grand
  map-reduce/map-reduce.sh fr travail-trop-grand t "Quels sujets sont débattus ?"
  ```
  Résultat attendu : arrêt **avant tout appel**, avec un message qui indique la tranche
  trop grande et la limite.
- [ ] **2.5 Le contrôle après l'appel détecte un dépassement.** Même dossier, mais en
  lançant le mode avec la même estimation fausse, pour franchir le contrôle au lancement :
  ```bash
  CAR_PAR_TOKEN=10 CIBLE_CTX=1 map-reduce/map-reduce.sh fr travail-trop-grand t2 "Quels sujets sont débattus ?"
  ```
  Résultat attendu : l'avertissement du ratio (test 5.2), puis arrêt après le premier appel
  (« le prompt a pu être tronqué »), **aucun** fichier `t2/001.md`. Si le test 2.2 a montré
  l'effet du cache, ce contrôle peut ne pas se déclencher : le noter.

## 3. Détection d'une réponse coupée par `num_predict`

- [ ] **3.1** Remplacer `map-reduce-fr` par une version avec `num_predict 16` (voir 0) et
  lancer `map-reduce/map-reduce.sh fr travail-debats coupe "Quels sujets sont débattus ?"`.
  Résultat attendu : `done_reason` vaut `length`, le script s'arrête avec un message clair
  et n'écrit pas `travail-debats/coupe/001.md`. Recréer le modèle normal ensuite.
- [ ] **3.2** Même test en `refine` et en `premier-dernier` (pas de `<série>/NNN.md` écrit).
  En premier-dernier, vérifier en particulier que le script **s'arrête** : l'appel a lieu
  dans `$(elements ...)`, où `set -e` ne s'applique pas, et l'échec est propagé à la main.
- [ ] **3.3** Vérifier qu'une réponse normale (`done_reason` = `stop`) est enregistrée.

## 4. Reprise après un arrêt

- [ ] **4.1** Après un arrêt dû au test 3, recréer le modèle normal et relancer **la même
  commande** (même série, même question) : les tranches déjà faites sont sautées, la
  tranche en échec est retraitée.
- [ ] **4.2** Vérifier qu'aucun fichier `.tmp` ne reste dans le dossier de la série.
- [ ] **4.3** Supprimer un fichier `NNN.md` d'une série terminée et relancer : seule cette
  tranche est refaite (en refine, les suivantes existent déjà et sont sautées : le noter,
  car elles ne tiennent pas compte de la tranche refaite).

## 5. Mesure du ratio caractères/token

- [ ] **5.1** Vérifier que le script affiche, pour chaque appel, la ligne « ratio mesuré : ... »
  (caractères du système et du message ÷ `prompt_eval_count`).
- [ ] **5.2** Lancer un mode sur `travail-debats` avec `CAR_PAR_TOKEN=10` : l'avertissement
  « ratio mesuré inférieur à CAR_PAR_TOKEN » doit apparaître à chaque appel. Les tranches,
  petites, passent sans autre problème.
- [ ] **5.3** Vérifier que le ratio s'écrit avec un point décimal et non une virgule, quelle
  que soit la locale.
- [ ] **5.4** Si le test 2.2 montre que `prompt_eval_count` exclut la partie en cache, le
  ratio affiché est trop haut à partir du deuxième appel : comparer le ratio de la première
  tranche avec celui des suivantes.
- [ ] **5.5** Relever ce ratio sur `debats.md` et sur un document riche en chiffres, tableaux
  ou URL. S'il descend près de 2,5 ou en dessous, revoir la valeur par défaut de
  `CAR_PAR_TOKEN`.

## 6. Taille des tranches : limite dure et `CIBLE_CTX`

Déjà vérifié sans ollama : le calcul (avec `num_ctx` 12288 et `num_predict` 2048 : limite
dure environ 22 500 caractères, plafond environ 10 750) ; 0 et « abc » refusés pour
`CIBLE_CTX`.

- [ ] **6.1** `./decouper.sh exemples/debats.md travail-defaut` : vérifier les lignes
  « <modèle> : tranche de N caractères au plus (contexte), M (CIBLE_CTX 0.35) » pour chaque
  modèle, et que la taille retenue est la plus petite, arrondie à la centaine.
- [ ] **6.2** Même commande avec `CIBLE_CTX=1` dans un autre dossier : c'est la limite dure
  qui s'applique (refine, qui réserve deux fois `num_predict`, doit donner la plus petite).
- [ ] **6.3** Découper avec le `CIBLE_CTX` par défaut, puis lancer un mode avec
  `CIBLE_CTX=0.1` : le contrôle au lancement doit refuser les tranches.
- [ ] **6.4** Sur un dossier découpé sans `-t` (document long), lancer map-reduce sur une
  tranche, puis lire `prompt_eval_count` dans le `.reponse.json` de `DEBUG_DOSSIER`. Il doit
  rester sous `CIBLE_CTX × num_ctx` + environ 1 000 tokens (système et texte fixe), soit
  environ 5 300 avec les réglages par défaut.
- [ ] **6.5** Comparer la qualité de l'extraction (nombre d'éléments, valeurs inventées) sur
  un même document assez long découpé avec `CIBLE_CTX` à 0.25, 0.35 et 0.6 (trois dossiers
  de travail). Comparer aussi avec l'ancienne version (2000 mots, soit environ
  12 000 caractères par tranche).

## 7. Consignes de longueur données au modèle

- [ ] **7.1** Vérifier que les lignes respectent les limites (idée ≤ 6 mots, précision ≤ 15
  mots, contexte ≤ 5 mots) et que les sujets correspondent aux réponses de référence
  (section 0).
- [ ] **7.2** Sur un document dense (un dictionnaire) en `premier-dernier` et `map-reduce`,
  vérifier que le modèle n'omet aucun élément (comparer avec une liste faite à la main sur
  une tranche) et que `done_reason` reste `stop`.
- [ ] **7.3** Comparer le nombre d'éléments extraits avant et après ce changement sur
  `debats.md` : les limites de longueur ne doivent pas faire fusionner des éléments
  distincts.
- [ ] **7.4** En `refine`, vérifier que les notes restent sous les 800 mots annoncés au bout
  d'une dizaine de tranches (document long).

## 8. Découpage unique, séries et intervalles

Déjà vérifié sans ollama, en isolant les fonctions : découpage de `debats.md` avec une
taille de 300 (4 tranches de 221 à 274 caractères) ; ligne et mot démesurés coupés sous la
limite ; sélection d'un intervalle ; refus d'une autre question sur la même série, d'un
intervalle inversé ou trop grand, du nom de série `tranches` et d'un dossier non découpé.

- [ ] **8.1** Contenu de `decoupage.txt` (document, taille, modèles, nombre de tranches).
- [ ] **8.2** Avec un modèle absent : il est ignoré avec un message. Avec `-m` sur un modèle
  absent : arrêt avec la commande `ollama create` à lancer.
- [ ] **8.3** `decouper.sh -t` avec une taille trop grande : refus avec un message clair.
- [ ] **8.4** `decouper.sh -m map-reduce-fr` : la taille maximale doit être plus grande
  qu'avec tous les modèles.
- [ ] **8.5** Relancer `decouper.sh` sur un dossier déjà découpé : refus.
- [ ] **8.6** Question plus longue que `QUESTION_MAX` (par exemple 3 000 caractères) sur un
  dossier découpé sans `-t` : le contrôle au lancement doit arrêter le script avant tout
  appel.
- [ ] **8.7** Deux séries sur `travail-debats` (deux questions différentes) : les résultats ne
  se mélangent pas, `question.txt` est propre à chaque série.
- [ ] **8.8** Refine avec `-d 3 -a 4` et un fichier `002.md` écrit à la main dans une nouvelle
  série : le message « Notes de départ : ... (existant, utilisé tel quel) » apparaît, les
  notes de `003.md` reprennent les éléments écrits à la main, et `fusion_003-004.md` les
  contient.
- [ ] **8.9** Refine avec `-d 3` sans `002.md` : notes de départ créées vides.
- [ ] **8.10** Map-reduce et premier-dernier avec `-d`/`-a` : seules les tranches de
  l'intervalle sont traitées ; `final_<de>-<à>.md` porte les bons numéros.
- [ ] **8.11** L'index envoyé au modèle est le numéro de la tranche dans le document, y
  compris avec `-d` : après le test 8.8, `grep -H '^index=' "$DEBUG_DOSSIER"/*refine-fr-tranche3.prompt.txt`
  doit afficher `index=3`. Avec une question qui demande de citer l'extrait d'origine
  (« ... indique de quel extrait provient chaque sujet »), les numéros cités doivent
  correspondre au tableau de référence.
- [ ] **8.12** Document de plus de 999 tranches (`-t` petit sur le document long) : les noms
  passent à 4 chiffres ; vérifier l'ordre (`sort -V`) et la reprise.
- [ ] **8.13** Avec mawk au lieu de gawk : mawk compte les octets, les tranches sont plus
  petites que prévu (sans danger, mais à savoir).

## 9. Non-régression

- [ ] **9.1** Lancer les trois modes sur `travail-debats`, en `fr` et en `en`, avec la
  question des températures et le critère « nourriture ». Vérifier le format des résultats,
  la fusion (`fusion_*.md`, `final_*.md`) et le contenu par rapport aux réponses de
  référence (section 0).
- [ ] **9.5** `DEBUG_DOSSIER` : après un appel, les trois fichiers `.requete.json`,
  `.prompt.txt` et `.reponse.json` existent, le numéro de tranche du nom est le bon, et une
  requête rejetée (test 3.1) laisse aussi sa réponse. Sans `DEBUG_DOSSIER`, aucun fichier
  n'est créé.
- [ ] **9.2** Lancer `fusion.sh` depuis un autre dossier que la racine du dépôt.
- [ ] **9.3** Message d'erreur quand `curl` ou `jq` est absent.
- [ ] **9.4** Message d'erreur quand le serveur ollama n'est pas démarré.
