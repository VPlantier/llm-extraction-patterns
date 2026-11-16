# LLM extraction patterns

Bash scripts that extract, from a long Markdown document, what answers a
question, using a local model served by [ollama](https://ollama.com).
The document is split into slices, then processed by one of three modes.
French documentation: [LISEZMOI.md](LISEZMOI.md). Code comments and messages are in French.

| Mode | Directory | Principle | Output |
|------|-----------|-----------|--------|
| refine | `refine/` | Each slice is read together with the previous notes, which the model rewrites. | `note_NNN.md` (successive versions), `fusion.md` |
| map-reduce | `map-reduce/` | Each slice is processed on its own, without feeding back earlier results, then the results are merged. | `map/NNN.md`, `final.md` |
| first-last (`premier-dernier`) | `premier-dernier/` | Finds the first and last items of the document that meet a criterion. | `final.md` (two lines) |

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

```bash
refine/refine.sh en debates.md "Which topics are debated? Give the debate temperature from 0° to 100°."
map-reduce/map-reduce.sh en debates.md "Which topics are debated? Give the debate temperature from 0° to 100°."
premier-dernier/premier-dernier.sh en dictionary.md "a word that names a kind of food"
```

An optional fourth argument sets the output directory (default `resultats-<mode>`).
The scripts resume where they stopped: a step whose output file already exists is skipped.
Delete the output directory to start over. Resuming assumes the document and
settings are unchanged, otherwise the slices no longer match.

Before each call, the script stops if the battery is below 20 % and unplugged.
It also pauses while the CPU/GPU temperature is at or above `TEMP_MAX`.

## Example

`exemples/debats.md` is a short (French) record of debates. The small `MAX_MOTS`/`MIN_MOTS` values split it into 4 slices:

```bash
MAX_MOTS=80 MIN_MOTS=20 refine/refine.sh fr exemples/debats.md "Quels sujets sont débattus ? Pour chaque sujet, indique la température du débat entre 0° (calme) et 100° (très houleux)."
MAX_MOTS=80 MIN_MOTS=20 premier-dernier/premier-dernier.sh fr exemples/debats.md "un mot qui désigne une forme de nourriture ou d'aliment"
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

- In refine, it runs automatically over every version of the notes (`fusion.md`). This recovers items the model dropped or changed along the way.
- In map-reduce, it is the *reduce* step (`final.md`).

## Context size guarantee

ollama silently truncates a prompt longer than `num_ctx`, so the scripts bound each slice:

```
max_chars = (num_ctx − k × num_predict − system − fixed text − MARGE_TOKENS) × CAR_PAR_TOKEN
```

- `num_ctx`, `num_predict` and the system prompt are read from the model (`ollama show`).
- The fixed text is the prompt built by `prompt_complet` (`lib/commun.sh`) without excerpt or notes, using a 5-digit dummy index: the leading `=== VARIABLE ===` / `index=<n>` section (slice number, 43 for `043.md`), section headers, question and instruction.
- `k = 1` reserves room for the answer. In refine, `k = 2`: the notes read back are a previous answer, so they are bounded by `num_predict`.
- `CAR_PAR_TOKEN` defaults to 2.5, a conservative ratio (about 4.3 chars/token measured on French text with gemma4).
- A slice never exceeds `MAX_MOTS` words or `max_chars` characters. An overlong line (such as a whole paragraph on one line) is split between words.

This is why every Modelfile must set `num_predict`.

This calculation is an estimate. After each call, the script therefore reads the
ollama API response and **stops without saving anything** for the slice if:

- the answer was cut off by `num_predict` (`done_reason` = `length`);
- the actual prompt (`prompt_eval_count`) + `num_predict` exceeds `num_ctx`: the estimate
  was wrong and ollama may have truncated the prompt.

The message says which setting to change. Since nothing was saved, resuming
redoes that slice. Prompt and answer token counts are printed for every call.

## Settings (environment variables)

| Variable | Default | Purpose |
|----------|---------|---------|
| `MAX_MOTS` | 2000 | max slice size, in words |
| `MIN_MOTS` | `MAX_MOTS/4` | only split on a `#`/`##` heading beyond this size, to avoid tiny slices |
| `CAR_PAR_TOKEN` | 2.5 | conservative chars/token ratio |
| `MARGE_TOKENS` | 256 | room for the chat template |
| `TEMP_MAX` | 90 | temperature (°C) that triggers a pause |
| `OLLAMA_URL` | `http://127.0.0.1:11434` | ollama server address |

## First-last: how it works

The model lists, in order, every item of the slice that meets the criterion, and
the script keeps the first (or last) one of that list.
For the first item, slices are scanned from the start until one contains an item.
For the last item, the scan starts from the end and never goes before the first item's slice.
Answers are cached in `reponses/`. A very dense slice (a dictionary, for example)
may hit the `num_predict` limit: the script then stops, and you should lower `MAX_MOTS`.

## Layout

```
lib/commun.sh        slicing, context budget, battery, temperature, ollama call
fusion.sh            de-duplicating merge (refine and map-reduce)
refine/              refine.sh, refine-fr.Modelfile, refine-en.Modelfile
map-reduce/          map-reduce.sh, map-reduce-fr.Modelfile, map-reduce-en.Modelfile
premier-dernier/     premier-dernier.sh, premier-dernier-fr.Modelfile, premier-dernier-en.Modelfile
exemples/            test document
```
