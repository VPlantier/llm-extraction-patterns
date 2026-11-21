# Modes d'extraction par LLM

Scripts bash pour extraire d'un long document Markdown ce qui répond à une
question, avec un modèle local servi par [ollama](https://ollama.com).
Le document est d'abord découpé en tranches, une fois pour toutes, dans un
dossier de travail. Chaque question est ensuite traitée sur ces tranches selon
l'un des trois modes ci-dessous.

| Mode | Dossier | Principe | Résultat (dans `travail/<série>/`) |
|------|---------|----------|----------|
| refine | `refine/` | Chaque tranche est lue avec les notes précédentes, que le modèle réécrit. | `NNN.md` (notes après la tranche NNN), `fusion_<de>-<à>.md` |
| map-reduce | `map-reduce/` | Chaque tranche est traitée isolément, sans renvoyer les résultats précédents, puis les résultats sont fusionnés. | `NNN.md` (réponse pour la tranche NNN), `final_<de>-<à>.md` |
| premier-dernier | `premier-dernier/` | Trouve le premier et le dernier élément qui satisfont un critère. | `NNN.md` (tranches analysées), `final_<de>-<à>.md` (deux lignes) |

Chaque dossier contient un script et deux définitions d'agent (`<mode>-fr.Modelfile`,
`<mode>-en.Modelfile`). Le nom du modèle ollama est celui du fichier.

## Installation

```bash
for d in refine map-reduce premier-dernier; do
  for l in fr en; do ollama create "$d-$l" -f "$d/$d-$l.Modelfile"; done
done
```

Il faut recréer le modèle après chaque modification d'un Modelfile.
Il faut bash, awk (gawk), ollama, curl (7.76 ou plus récent) et jq. Les scripts
appellent l'API d'ollama à l'adresse `OLLAMA_URL` (par défaut `http://127.0.0.1:11434`).

## Utilisation

### 1. Découper le document : `decouper.sh`

```bash
./decouper.sh [-t taille] [-m modèle]... document.md dossier_de_travail
```

Les tranches sont écrites dans `dossier_de_travail/tranches/001.md`, `002.md`...
et les paramètres du découpage dans `dossier_de_travail/decoupage.txt`.

- Sans `-t`, la taille (en caractères) est la plus grande qui convienne à tous les
  modèles installés, pour une question d'au plus `QUESTION_MAX` caractères. Le
  script affiche les limites de chaque modèle.
- Avec `-t`, la taille donnée est refusée si elle dépasse ce maximum.
- `-m` (répétable) restreint le calcul aux modèles que l'on compte utiliser.

Un dossier de travail ne se redécoupe pas : les numéros de tranches sont des
références stables pour toutes les séries de résultats. Pour un autre découpage,
on crée un autre dossier de travail.

On coupe de préférence sur un titre `#` ou `##` dès que la tranche atteint le
quart de la taille. Une ligne trop longue est coupée entre deux mots.

### 2. Poser une question : une série par question

```bash
refine/refine.sh [-d de] [-a à] fr|en dossier_de_travail série "question"
map-reduce/map-reduce.sh [-d de] [-a à] fr|en dossier_de_travail série "question"
premier-dernier/premier-dernier.sh [-d de] [-a à] fr|en dossier_de_travail série "critère"
```

- Les résultats vont dans `dossier_de_travail/série/`, un fichier par tranche, nommé
  comme la tranche. Plusieurs questions peuvent ainsi porter sur les mêmes tranches,
  chacune dans sa série.
- Le mode, la langue et la question sont enregistrés dans `série/question.txt` : une
  série ne peut pas être reprise avec une autre question.
- `-d` et `-a` limitent le traitement aux tranches `de` à `à` (par défaut, toutes).
- Avant de commencer, le script vérifie que chaque tranche de l'intervalle tient dans
  le contexte du modèle avec cette question. Sinon, il s'arrête : il faut raccourcir
  la question ou redécouper dans un autre dossier de travail.

Les scripts reprennent là où ils se sont arrêtés : une tranche dont le fichier
existe déjà est sautée. Pour refaire une tranche, supprime son fichier.

Au lancement, le script affiche les mesures du matériel (nombre de capteurs de
température, la plus haute, état de la batterie). Avant chaque appel, il s'arrête
si la batterie est sous 20 % et non branchée, et fait une pause tant que la
température atteint `TEMP_MAX` ; si elle y reste plus de `PAUSE_MAX` secondes, il
s'arrête (une reprise repart de la tranche en cours). Les températures sont lues
dans tous les capteurs de Linux (`/sys/class/hwmon` : processeur, GPU AMD ou Intel,
SSD... ; `/sys/class/thermal`) et par `nvidia-smi` s'il est installé.

**Pas de mesure fiable, pas d'appel au modèle** : le script s'arrête avec un message
si aucun capteur de température n'est trouvé (autre système que Linux, par exemple),
si un capteur est illisible ou donne une valeur impossible (hors de 1 à 124 °C,
comme le 127 °C d'un capteur en panne), si `nvidia-smi` est en erreur, ou si une
batterie est illisible. Un ordinateur sans batterie est accepté.

Chaque appel affiche la vitesse de génération (tokens/s). Quand un appel vient de
charger le modèle, le script vérifie dans le journal d'ollama (`journalctl -u ollama`)
que le modèle tient entièrement dans la mémoire du GPU, et prévient sinon : ollama
place alors une partie des couches sur le processeur, sans erreur, et le modèle
ralentit. `ollama ps` n'est pas fiable pour cela (il peut afficher « 100% GPU » à tort).
Sans accès au journal (ollama lancé à la main avec `ollama serve`), le contrôle est
sauté avec un message.

### 3. Approfondir sur un intervalle

Une fois un élément repéré dans la tranche n, on peut poser une question plus
précise sur un intervalle étroit autour de n, dans une nouvelle série. En refine,
les notes de départ sont le fichier qui précède la première tranche : `000.md`
sans `-d`, `011.md` avec `-d 12`. S'il existe, il est utilisé tel quel. On peut
donc l'écrire ou le corriger à la main avant de lancer le script. Sinon, il est
créé vide.

Reprendre la main entre deux passages, plutôt que d'enchaîner automatiquement les
résultats du modèle, évite d'accumuler ses hallucinations.

## Exemple

`exemples/debats.md` est un court compte rendu de débats. Une petite taille le découpe en 4 tranches :

```bash
./decouper.sh -t 300 exemples/debats.md travail-debats
refine/refine.sh fr travail-debats temperature "Quels sujets sont débattus ? Pour chaque sujet, indique la température du débat entre 0° (calme) et 100° (très houleux)."
premier-dernier/premier-dernier.sh fr travail-debats nourriture "un mot qui désigne une forme de nourriture ou d'aliment"
# Puis, sur la séance du 13 mars (tranches 3 et 4) seulement, avec des notes de
# départ écrites à la main dans travail-debats/fonciere/002.md :
refine/refine.sh -d 3 -a 4 fr travail-debats fonciere "Quelles positions sont exprimées sur la contribution foncière ?"
```

## Format des résultats

Les agents refine et map-reduce produisent un titre suivi d'une liste, une ligne par élément :

```
# Sujets débattus et température

* **Réforme de la contribution foncière** distinction entre sols productifs et non productifs (Température : 50°)
```

La partie entre parenthèses ne contient que les données que la question
demande explicitement pour chaque élément. Sans demande de ce type, elle est absente.

## Fusion : `fusion.sh`

```bash
./fusion.sh [-t titre] [-o sortie.md] (dossier | fichier1.md fichier2.md ...)
```

Le script lit les fichiers dans l'ordre et ignore les titres et le texte libre.
Il garde chaque élément de liste dans l'ordre de première apparition et ignore
une ligne identique déjà vue. Les espaces et la puce `*`/`-` sont normalisés.
Le titre retenu est le plus fréquent, sauf si `-t` en impose un.

- En refine, il est lancé automatiquement sur les notes de l'intervalle, notes de départ comprises (`fusion_<de>-<à>.md`). Il récupère ainsi les éléments que le modèle a perdus ou modifiés en route.
- En map-reduce, il constitue l'étape *reduce* (`final_<de>-<à>.md`).

## Garantie de la taille du contexte

ollama tronque sans prévenir un prompt plus long que `num_ctx`. La taille des
tranches est donc bornée, pour chaque modèle :

```
max_car = (num_ctx − k × num_predict − système − texte fixe − MARGE_TOKENS) × CAR_PAR_TOKEN
```

- `num_ctx`, `num_predict` et le prompt système sont lus dans le modèle (`ollama show`).
- Le texte fixe est le prompt produit par `prompt_complet` (`lib/commun.sh`) sans extrait ni notes, avec un index fictif de 5 chiffres : section `=== VARIABLE ===` / `index=<n>` (numéro de la tranche, 43 pour `043.md`) en tête, titres de sections, question et consigne. Au découpage, la question n'est pas encore connue : on compte `QUESTION_MAX` caractères pour elle, plus 500 pour le reste.
- `k = 1` (réservation pour la réponse). En refine, `k = 2` : les notes relues sont une réponse précédente, donc bornées par `num_predict`.
- `CAR_PAR_TOKEN` vaut 2,5 par défaut, un ratio prudent : on mesure environ 4,3 caractères par token sur du français avec gemma4.

C'est pourquoi chaque Modelfile doit définir `num_predict`.

Cette limite dure évite la troncature, mais pas la baisse de qualité : un petit
modèle oublie des éléments et invente bien avant de remplir sa fenêtre. Un second
plafond limite donc l'extrait à une part du contexte :

```
max_car_cible = CIBLE_CTX × num_ctx × CAR_PAR_TOKEN
```

La limite d'un modèle est la plus petite des deux valeurs. `decouper.sh` prend la
plus petite limite des modèles retenus. Avec les réglages par défaut, c'est
`CIBLE_CTX` qui l'emporte (environ 10 700 caractères).

Ce calcul est refait à chaque lancement d'un mode avec la vraie question : si une
tranche de l'intervalle dépasse, le script s'arrête avant tout appel.

Il repose sur une estimation. La requête interdit donc à ollama de tronquer le
prompt (`truncate: false`) ou d'oublier le début du contexte pendant l'écriture
(`shift: false`) : sans ces champs, ollama coupe en silence un prompt trop long à la
moitié de `num_ctx`. Le script **s'arrête sans rien enregistrer** pour la tranche si :

- ollama refuse la requête parce qu'elle dépasse le contexte ;
- la réponse a été coupée par `num_predict` (`done_reason` = `length`) ;
- le prompt réel (`prompt_eval_count`) + `num_predict` dépasse `num_ctx` : l'estimation
  était fausse ;
- le ratio caractères/token dépasse `RATIO_MAX` : le modèle a lu bien moins de tokens
  que le texte n'en contient, le prompt a été tronqué (contrôle de secours).

Le message indique quel réglage modifier. Comme rien n'a été enregistré, une
reprise refait cette tranche. Les nombres de tokens du prompt et de la réponse
sont affichés à chaque appel, avec le ratio réel caractères/token du prompt. Si
ce ratio est inférieur à `CAR_PAR_TOKEN`, un avertissement conseille de réduire
`CAR_PAR_TOKEN` : l'estimation n'est pas prudente pour ce document (chiffres,
tableaux, URL, code...).

## Réglages (variables d'environnement)

| Variable | Défaut | Rôle |
|----------|--------|------|
| `QUESTION_MAX` | 500 | longueur maximale prévue d'une question, en caractères (découpage) |
| `CAR_PAR_TOKEN` | 2.5 | ratio prudent caractères/token |
| `MARGE_TOKENS` | 256 | réserve pour le gabarit de conversation |
| `RATIO_MAX` | 8 | ratio caractères/token au-delà duquel la réponse est rejetée (prompt tronqué) |
| `CIBLE_CTX` | 0.35 | part maximale de `num_ctx` occupée par l'extrait (entre 0 et 1) |
| `TEMP_MAX` | 90 | température (°C) déclenchant une pause |
| `PAUSE_MAX` | 600 | durée maximale (s) d'une pause pour température, avant arrêt |
| `OLLAMA_URL` | `http://127.0.0.1:11434` | adresse du serveur ollama |
| `DEBUG_DOSSIER` | (vide) | si défini, chaque appel y enregistre sa requête (`.requete.json`, rejouable avec `curl`), le prompt lisible (`.prompt.txt`) et la réponse brute d'ollama (`.reponse.json`) |

Exemple : `CIBLE_CTX=0.25 ./decouper.sh doc.md travail-doc`.

## Premier-dernier : fonctionnement

Le modèle liste dans l'ordre tous les éléments de la tranche qui satisfont le
critère, et le script garde le premier (ou le dernier) de cette liste.
Pour le premier, on parcourt les tranches de l'intervalle depuis le début jusqu'à trouver un élément.
Pour le dernier, on part de la fin, sans remonter avant la tranche du premier.
Seules les tranches nécessaires sont analysées. Une tranche très dense
(un dictionnaire, par exemple) peut atteindre la limite `num_predict` : le script
s'arrête alors, et il faut redécouper avec une taille plus petite.

## Organisation

```
decouper.sh          découpage d'un document dans un dossier de travail
fusion.sh            fusion sans doublons (refine et map-reduce)
lib/commun.sh        découpage, séries, budget de contexte, batterie, température, appel ollama
refine/              refine.sh, refine-fr.Modelfile, refine-en.Modelfile
map-reduce/          map-reduce.sh, map-reduce-fr.Modelfile, map-reduce-en.Modelfile
premier-dernier/     premier-dernier.sh, premier-dernier-fr.Modelfile, premier-dernier-en.Modelfile
exemples/            document de test
```

Dossier de travail :

```
travail/
  decoupage.txt      document, taille, modèles retenus, nombre de tranches
  tranches/          001.md, 002.md...
  <série>/           question.txt, 000.md (refine : notes de départ), 001.md..., final_ ou fusion_<de>-<à>.md
```
