# grimoire-katex

A [Grimoire](https://github.com/jennifer-language/grimoire) preprocessor that
typesets TeX maths as MathML while the book is built, using the `katex` command
line. Nothing is shipped to the reader: no stylesheet, no fonts, no script.
Current Chrome, Firefox and Safari draw MathML themselves, and EPUB 3 readers
do too.

A user plugin by mplx, not maintained by the Grimoire project, and not in
Grimoire's container image.

## What it needs

- **Grimoire 0.5.0 or later.** The plugin uses the `mathml` feature of the
  plugin contract (api 1), which says the EPUB, the printable book and the
  search index know what to do with MathML, and refuses an older Grimoire,
  saying so.
- **[`katex`](https://katex.org/)**, installed by you, which brings Node
  (`npm install -g katex`); checked with 0.19.1.

A build runs nothing else and fetches nothing. A book with no maths runs no
`katex` at all.

## Install

```sh
jvc app install https://github.com/mplx/grimoire-katex                   # onto PATH
jvc app install https://github.com/mplx/grimoire-katex --scope project   # beside one book
```

The command is `grimoire-katex`, which is what Grimoire runs for a
`[preprocessor.katex]` table. With `--scope project`, or a plain checkout, point
`command` at the launcher:

```toml
[preprocessor.katex]
command = "bin/grimoire-katex"
```

## Use

```toml
[preprocessor.katex]
```

is enough. The syntax is GitHub's:

````markdown
Inline maths sits in the line: $`a^2 + b^2 = c^2`$.

```math
\sum_{i=1}^{n} i = \frac{n(n+1)}{2}
```
````

- **Display maths** is a `math` fence, with backticks or tildes, following
  CommonMark's fence rules.
- **Inline maths** is `` $`...`$ ``: a code span with a `$` on each side. A
  longer backtick run carries a backtick (`` $``a`b``$ ``), as in any code span.
- **Not maths:** `$$...$$` and plain `$...$`, because a technical book is full of
  `$HOME` and `$5`. Other fences, indented code, and code spans that are not
  `` $`...`$ `` are left alone, so a page can show the syntax. A backslash before
  the `$` (`` \$`x`$ ``) leaves a dollar and a code span.
- **Not in block quotes:** a `math` fence or inline maths inside a block quote
  (`> `) is not recognised and stays code.
- **Indentation:** a paragraph indented four columns or more after a blank line
  is read as indented code, as at the top level. In a list item, indent its
  continuation paragraphs by less.

Each formula becomes the `<math>` element KaTeX writes, without the
`span.katex` around it, which exists for KaTeX's own CSS:

- display maths becomes an HTML block, the opening tag alone on its line, with a
  blank line on either side;
- inline maths stays in its line, inside the paragraph.

Markdown still reads the text between inline HTML tags, so `*`, `_`, `` ` ``,
`[`, `]`, `{`, `}`, `\`, `~`, `=`, `^`, `|` and `:` in the element's text are
written as numeric entities (`a*b*c` stays maths, not emphasis). A display block
needs none of that for Markdown, but gets the same treatment so a later
preprocessor (macros, emoji, a glossary) cannot rewrite it either.

### What each edition shows

| Edition | |
| - | - |
| the site | the MathML, drawn by the browser in the text's own colour, dark mode included |
| the EPUB | the MathML; each chapter that holds some is marked `properties="mathml"` |
| the printable book | the TeX source in monospace: in the line for inline maths, centred on its own lines for display maths |
| the search index | nothing: maths is left out, and a heading's anchor leaves it out too |

**Line height:** inline maths is laid out compact (TeX's text style). Scripts,
small fractions and `\sum` with its limits fit within Grimoire's line height.
Taller constructs (`\dfrac`, nested fractions, matrices) grow their line, as
they do in TeX; no CSS squeezes them, because a squeezed formula overlaps the
lines around it. Put tall maths in a `math` fence.

## Settings

```toml
[preprocessor.katex]
inline = true                 # false: only math fences
macroFile = "tex/macros.tex"  # --macro-file, relative to the book's src
strict = false                # true: --strict, LaTeX-faithful
leqno = false                 # --leqno: equation numbers on the left
fleqn = false                 # --fleqn: display maths flush left
program = ""                  # katex's path, when it is not on PATH
jobs = 0                      # formulas typeset at a time; 0 is one per CPU

[preprocessor.katex.macros]   # each passed as -m '\RR:\mathbb{R}'
'\RR' = '\mathbb{R}'
```

Any other key is an error, apart from Grimoire's own `command` and `args`.
katex's path is `program` rather than `command`, because Grimoire reads
`command` as the plugin's own path. A macro name is a backslash and letters, or
a backslash and one other character; a macro file that is not there stops the
build.

Every call is `katex -F mathml -e 1000 -s 100`, plus `-d` for display maths:

- `-e 1000`: at most 1000 macro expansions, so a runaway macro is an error
  rather than a hang;
- `-s 100`: no size a formula gives (`\rule{500em}{1em}`) above 100 em.

`--trust` is never passed, so `\href`, `\url` and the other commands that write
HTML are refused; KaTeX draws such a command in its error colour rather than
failing, and the plugin turns that into an error. `--no-throw-on-error` is never
passed either.

Each distinct formula (display and inline counted apart) is typeset once, up to
`jobs` at a time; the result does not depend on which finishes first, so the
book is the same at any `--jobs`.

## Errors

The plugin is strict: a problem stops the build rather than leaving a hole in
it. Grimoire reports the plugin's message, for example:

```
grimoire: preprocessor katex: exited 1: grimoire-katex: guide/sums.md:3: KaTeX parse error: Unexpected end of input in a macro argument, expected '}' at end of input: \frac{a
```

- a formula KaTeX refuses names the chapter, the line and KaTeX's message,
  without the Node stack trace;
- an unclosed or empty `math` fence, an empty inline formula, an unknown setting
  and a value of the wrong kind are refused;
- a missing `katex` says what to install or which setting to change;
- a formula over 64 KiB of TeX, or over 1 MiB of MathML, throws `"limit"`.

## Development

```
bin/grimoire-katex       the launcher: read stdin, run the module, exit its status
src/katex.j              the module: the syntax, the katex command line, the MathML
src/katex_test.j         its tests
src/pluginkit.j          a copy of Grimoire's plugin kit
tests/fake-katex         a stand-in katex the tests drive through `program`
examples/book/           a book with display and inline maths and every edition enabled
```

The plugin is built on Grimoire's plugin kit. `src/pluginkit.j` is a copy of
Grimoire's `src/pluginkit.j` (Grimoire 0.5.0 or later), imported as
`./pluginkit.j`; it is not edited here. The kit gives the request and reply
handling, the CommonMark fence scanner, settings and the concurrent typesetting.
`scripts/sync-kit.sh` refreshes the copy from a Grimoire checkout beside this one
(or `$GRIMOIRE_SRC`), and `scripts/test.sh` warns when the two differ.

```sh
scripts/sync-kit.sh                                                # refresh the kit copy
scripts/test.sh                                                    # fmt, lint, tests
GRIMOIRE="$PWD/../grimoire/bin/grimoire" scripts/check-example.sh  # the example, end to end
```

The tests run against the fake katex, and against the real `katex` when it is
installed: two builds have to give the same bytes, and bad TeX has to stop the
build with KaTeX's message. `scripts/check-example.sh` builds the example book
with a Grimoire checkout and checks the site, the EPUB and the PDF.

`NEEDS` names `katex`, for an image that would carry the plugin.

## Licence

LGPL-3.0-only, see [LICENSE](LICENSE).
