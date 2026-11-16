# Modes d'extraction par LLM

Scripts bash pour extraire d'un long document Markdown ce qui répond à une
question, avec un modèle local servi par [ollama](https://ollama.com).
Le document est découpé en tranches, puis traité selon l'un des trois modes ci-dessous.

| Mode | Dossier | Principe | Résultat |
|------|---------|----------|----------|
| refine | `refine/` | Chaque tranche est lue avec les notes précédentes, que le modèle réécrit. | `note_NNN.md` (versions successives), `fusion.md` |
| map-reduce | `map-reduce/` | Chaque tranche est traitée isolément, sans renvoyer les résultats précédents, puis les résultats sont fusionnés. | `map/NNN.md`, `final.md` |
| premier-dernier | `premier-dernier/` | Trouve le premier et le dernier élément du document qui satisfont un critère. | `final.md` (deux lignes) |

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

```bash
refine/refine.sh fr debats.md "Quels sujets sont débattus ? Indique la température du débat de 0° à 100°."
map-reduce/map-reduce.sh fr debats.md "Quels sujets sont débattus ? Indique la température du débat de 0° à 100°."
premier-dernier/premier-dernier.sh fr dictionnaire.md "un mot qui désigne une forme de nourriture"
```

Un quatrième argument facultatif donne le dossier de sortie (par défaut `resultats-<mode>`).
Les scripts reprennent là où ils se sont arrêtés : une étape dont le fichier
existe déjà est sautée. Pour repartir de zéro, supprime le dossier de sortie.
Une reprise suppose que le document et les réglages n'ont pas changé, sinon les tranches ne correspondent plus.

Avant chaque appel, le script s'arrête si la batterie est sous 20 % et non
branchée. Il fait aussi une pause tant que la température CPU/GPU atteint `TEMP_MAX`.

## Exemple

`exemples/debats.md` est un court compte rendu de débats. Les petites valeurs de `MAX_MOTS`/`MIN_MOTS` le découpent en 4 tranches :

```bash
MAX_MOTS=80 MIN_MOTS=20 refine/refine.sh fr exemples/debats.md "Quels sujets sont débattus ? Pour chaque sujet, indique la température du débat entre 0° (calme) et 100° (très houleux)."
MAX_MOTS=80 MIN_MOTS=20 premier-dernier/premier-dernier.sh fr exemples/debats.md "un mot qui désigne une forme de nourriture ou d'aliment"
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

- En refine, il est lancé automatiquement sur toutes les versions des notes (`fusion.md`). Il récupère ainsi les éléments que le modèle a perdus ou modifiés en route.
- En map-reduce, il constitue l'étape *reduce* (`final.md`).

## Garantie de la taille du contexte

ollama tronque sans prévenir un prompt plus long que `num_ctx`. Les scripts
bornent donc la taille de chaque tranche :

```
max_car = (num_ctx − k × num_predict − système − texte fixe − MARGE_TOKENS) × CAR_PAR_TOKEN
```

- `num_ctx`, `num_predict` et le prompt système sont lus dans le modèle (`ollama show`).
- Le texte fixe est le prompt produit par `prompt_complet` (`lib/commun.sh`) sans extrait ni notes, avec un index fictif de 5 chiffres : section `=== VARIABLE ===` / `index=<n>` (numéro de la tranche, 43 pour `043.md`) en tête, titres de sections, question et consigne.
- `k = 1` (réservation pour la réponse). En refine, `k = 2` : les notes relues sont une réponse précédente, donc bornées par `num_predict`.
- `CAR_PAR_TOKEN` vaut 2,5 par défaut, un ratio prudent : on mesure environ 4,3 caractères par token sur du français avec gemma4.
- Une tranche ne dépasse jamais `MAX_MOTS` mots ni `max_car` caractères. Une ligne trop longue (un paragraphe entier sur une ligne, par exemple) est coupée entre deux mots.

C'est pourquoi chaque Modelfile doit définir `num_predict`.

Ce calcul repose sur une estimation. Après chaque appel, le script lit donc la
réponse de l'API d'ollama et **s'arrête sans rien enregistrer** pour la tranche si :

- la réponse a été coupée par `num_predict` (`done_reason` = `length`) ;
- le prompt réel (`prompt_eval_count`) + `num_predict` dépasse `num_ctx` : l'estimation
  était fausse et ollama a pu tronquer le prompt.

Le message indique quel réglage modifier. Comme rien n'a été enregistré, une
reprise refait cette tranche. Les nombres de tokens du prompt et de la réponse
sont affichés à chaque appel.

## Réglages (variables d'environnement)

| Variable | Défaut | Rôle |
|----------|--------|------|
| `MAX_MOTS` | 2000 | taille maximale d'une tranche, en mots |
| `MIN_MOTS` | `MAX_MOTS/4` | on ne coupe sur un titre `#`/`##` qu'au-delà de cette taille, pour éviter les tranches minuscules |
| `CAR_PAR_TOKEN` | 2.5 | ratio prudent caractères/token |
| `MARGE_TOKENS` | 256 | réserve pour le gabarit de conversation |
| `TEMP_MAX` | 90 | température (°C) déclenchant une pause |
| `OLLAMA_URL` | `http://127.0.0.1:11434` | adresse du serveur ollama |

Exemple : `MAX_MOTS=1000 refine/refine.sh fr doc.md "..."`.

## Premier-dernier : fonctionnement

Le modèle liste dans l'ordre tous les éléments de la tranche qui satisfont le
critère, et le script garde le premier (ou le dernier) de cette liste.
Pour le premier, on parcourt les tranches depuis le début jusqu'à trouver un élément.
Pour le dernier, on part de la fin, sans remonter avant la tranche du premier.
Les réponses sont mises en cache dans `reponses/`. Une tranche très dense
(un dictionnaire, par exemple) peut atteindre la limite `num_predict` : le script
s'arrête alors, et il faut réduire `MAX_MOTS`.

## Organisation

```
lib/commun.sh        découpage, budget de contexte, batterie, température, appel ollama
fusion.sh            fusion sans doublons (refine et map-reduce)
refine/              refine.sh, refine-fr.Modelfile, refine-en.Modelfile
map-reduce/          map-reduce.sh, map-reduce-fr.Modelfile, map-reduce-en.Modelfile
premier-dernier/     premier-dernier.sh, premier-dernier-fr.Modelfile, premier-dernier-en.Modelfile
exemples/            document de test
```
