# LLM extraction patterns

Bash scripts that extract, from a long Markdown document, what answers a
question, using a local model served by [ollama](https://ollama.com).
The document is first split into slices, once and for all, in a working
directory. Each question is then processed over these slices by one of three modes.
French documentation: [LISEZMOI.md](LISEZMOI.md). Code comments and messages are in French.

| Mode | Directory | Principle | Output (in `work/<series>/`) |
|------|-----------|-----------|--------|
| refine | `refine/` | Each slice is read together with the previous notes, which the model rewrites. | `NNN.md` (notes after slice NNN), `fusion_<from>-<to>.md` |
| map-reduce | `map-reduce/` | Each slice is processed on its own, without feeding back earlier results, then the results are merged. | `NNN.md` (answer for slice NNN), `final_<from>-<to>.md` |
| first-last (`premier-dernier`) | `premier-dernier/` | Finds the first and last items that meet a criterion. | `NNN.md` (slices analysed), `final_<from>-<to>.md` (two lines) |

Each directory holds one script and two agent definitions (`<mode>-fr.Modelfile`,
`<mode>-en.Modelfile`). The ollama model is named after the file.

## Setup

```bash
for d in refine map-reduce premier-dernier; do
  for l in fr en; do ollama create "$d-$l" -f "$d/$d-$l.Modelfile"; done
done
```

Recreate a model after editing its Modelfile. You need bash, awk (gawk), ollama, curl (7.76 or later) and jq.
The scripts call the ollama API at `OLLAMA_URL` (default `http://127.0.0.1:11434`).

## Usage

### 1. Split the document: `decouper.sh`

```bash
./decouper.sh [-t size] [-m model]... document.md working_directory
```

Slices are written to `working_directory/tranches/001.md`, `002.md`...
and the slicing parameters to `working_directory/decoupage.txt`.

- Without `-t`, the size (in characters) is the largest one that suits every
  installed model, for a question of at most `QUESTION_MAX` characters. The script
  prints each model's limits.
- With `-t`, the given size is refused if it exceeds that maximum.
- `-m` (repeatable) restricts the calculation to the models you plan to use.

A working directory is never re-split: slice numbers are stable references for
every series of results. For a different slicing, create another working directory.

Slices preferably break on a `#` or `##` heading once they reach a quarter of the
size. An overlong line is split between words.

### 2. Ask a question: one series per question

```bash
refine/refine.sh [-d from] [-a to] fr|en working_directory series "question"
map-reduce/map-reduce.sh [-d from] [-a to] fr|en working_directory series "question"
premier-dernier/premier-dernier.sh [-d from] [-a to] fr|en working_directory series "criterion"
```

- Results go to `working_directory/series/`, one file per slice, named after the
  slice. Several questions can thus work on the same slices, each in its own series.
- The mode, language and question are saved in `series/question.txt`: a series
  cannot be resumed with a different question.
- `-d` and `-a` restrict processing to slices `from` to `to` (default: all).
- Before starting, the script checks that every slice in the range fits the model's
  context with this question. Otherwise it stops: shorten the question, or re-split
  into another working directory.

The scripts resume where they stopped: a slice whose output file already exists
is skipped. Delete a slice's file to redo it.

Before each call, the script stops if the battery is below 20 % and unplugged.
It also pauses while the CPU/GPU temperature is at or above `TEMP_MAX`.

### 3. Dig into a range

Once an item shows up in slice n, you can ask a more precise question over a
narrow range around n, in a new series. In refine, the starting notes are the file
just before the first slice: `000.md` without `-d`, `011.md` with `-d 12`. If it
exists, it is used as is, so you can write or fix it by hand before running the
script. Otherwise it is created empty.

Taking back control between passes, rather than chaining the model's outputs
automatically, avoids piling up its hallucinations.

## Example

`exemples/debats.md` is a short (French) record of debates. A small size splits it into 4 slices:

```bash
./decouper.sh -t 300 exemples/debats.md travail-debats
refine/refine.sh fr travail-debats temperature "Quels sujets sont débattus ? Pour chaque sujet, indique la température du débat entre 0° (calme) et 100° (très houleux)."
premier-dernier/premier-dernier.sh fr travail-debats nourriture "un mot qui désigne une forme de nourriture ou d'aliment"
# Then, on the 13 March session only (slices 3 and 4), with starting notes
# written by hand in travail-debats/fonciere/002.md:
refine/refine.sh -d 3 -a 4 fr travail-debats fonciere "Quelles positions sont exprimées sur la contribution foncière ?"
```

## Output format

The refine and map-reduce agents produce a title followed by a list, one line per item:

```
# Debated topics and temperature

* **Land tax reform** distinction between productive and unproductive land (Temperature: 50°)
```

The part in parentheses only holds data the question explicitly asks for each
item. When the question asks for no such data, it is left out.

## Merging: `fusion.sh`

```bash
./fusion.sh [-t title] [-o output.md] (directory | file1.md file2.md ...)
```

The script reads the files in order and ignores titles and free text.
It keeps every list item in order of first appearance and skips a line already seen.
Whitespace and the `*`/`-` bullet are normalized.
The most frequent title is kept, unless `-t` sets one.

- In refine, it runs automatically over the notes of the range, starting notes included (`fusion_<from>-<to>.md`). This recovers items the model dropped or changed along the way.
- In map-reduce, it is the *reduce* step (`final_<from>-<to>.md`).

## Context size guarantee

ollama silently truncates a prompt longer than `num_ctx`, so the slice size is
bounded, for each model:

```
max_chars = (num_ctx − k × num_predict − system − fixed text − MARGE_TOKENS) × CAR_PAR_TOKEN
```

- `num_ctx`, `num_predict` and the system prompt are read from the model (`ollama show`).
- The fixed text is the prompt built by `prompt_complet` (`lib/commun.sh`) without excerpt or notes, using a 5-digit dummy index: the leading `=== VARIABLE ===` / `index=<n>` section (slice number, 43 for `043.md`), section headers, question and instruction. When splitting, the question is not known yet: `QUESTION_MAX` characters are counted for it, plus 500 for the rest.
- `k = 1` reserves room for the answer. In refine, `k = 2`: the notes read back are a previous answer, so they are bounded by `num_predict`.
- `CAR_PAR_TOKEN` defaults to 2.5, a conservative ratio (about 4.3 chars/token measured on French text with gemma4).

This is why every Modelfile must set `num_predict`.

This hard limit prevents truncation, but not quality loss: a small model starts
missing items and making things up well before its window is full. A second cap
therefore limits the excerpt to a share of the context:

```
max_chars_target = CIBLE_CTX × num_ctx × CAR_PAR_TOKEN
```

A model's limit is the smaller of the two values. `decouper.sh` takes the smallest
limit among the selected models. With the default settings, `CIBLE_CTX` is the
binding one (about 10,700 characters).

This calculation is redone with the actual question whenever a mode starts: if a
slice in the range exceeds it, the script stops before any call.

It is an estimate. After each call, the script therefore reads the
ollama API response and **stops without saving anything** for the slice if:

- the answer was cut off by `num_predict` (`done_reason` = `length`);
- the actual prompt (`prompt_eval_count`) + `num_predict` exceeds `num_ctx`: the estimate
  was wrong and ollama may have truncated the prompt.

The message says which setting to change. Since nothing was saved, resuming
redoes that slice. Prompt and answer token counts are printed for every call,
along with the prompt's actual chars/token ratio. If that ratio is below
`CAR_PAR_TOKEN`, a warning suggests lowering `CAR_PAR_TOKEN`: the estimate is not
conservative for this document (numbers, tables, URLs, code...).

## Settings (environment variables)

| Variable | Default | Purpose |
|----------|---------|---------|
| `QUESTION_MAX` | 500 | expected max question length, in characters (slicing) |
| `CAR_PAR_TOKEN` | 2.5 | conservative chars/token ratio |
| `MARGE_TOKENS` | 256 | room for the chat template |
| `CIBLE_CTX` | 0.35 | max share of `num_ctx` taken by the excerpt (between 0 and 1) |
| `TEMP_MAX` | 90 | temperature (°C) that triggers a pause |
| `OLLAMA_URL` | `http://127.0.0.1:11434` | ollama server address |
| `DEBUG_DOSSIER` | (empty) | when set, every call saves its request (`.requete.json`, replayable with `curl`), the readable prompt (`.prompt.txt`) and ollama's raw response (`.reponse.json`) there |

## First-last: how it works

The model lists, in order, every item of the slice that meets the criterion, and
the script keeps the first (or last) one of that list.
For the first item, the range is scanned from the start until a slice contains an item.
For the last item, the scan starts from the end and never goes before the first item's slice.
Only the slices needed are analysed. A very dense slice (a dictionary, for example)
may hit the `num_predict` limit: the script then stops, and you should re-split with a smaller size.

## Layout

```
decouper.sh          splits a document into a working directory
fusion.sh            de-duplicating merge (refine and map-reduce)
lib/commun.sh        slicing, series, context budget, battery, temperature, ollama call
refine/              refine.sh, refine-fr.Modelfile, refine-en.Modelfile
map-reduce/          map-reduce.sh, map-reduce-fr.Modelfile, map-reduce-en.Modelfile
premier-dernier/     premier-dernier.sh, premier-dernier-fr.Modelfile, premier-dernier-en.Modelfile
exemples/            test document
```

Working directory:

```
work/
  decoupage.txt      document, size, selected models, number of slices
  tranches/          001.md, 002.md...
  <series>/          question.txt, 000.md (refine: starting notes), 001.md..., final_ or fusion_<from>-<to>.md
```
