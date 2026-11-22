# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.27.0
# pragma-jennifer-capability: exec

/**
 * TeX maths for Grimoire, typeset as MathML while the book is built.
 *
 * A preprocessor. Display maths is a `math` fence and inline maths is
 * `` $`...`$ ``, both GitHub's forms:
 *
 *     ```math                         Inline: $`a^2 + b^2 = c^2`$.
 *     \sum_{i=1}^{n} i
 *     ```
 *
 * Each distinct formula is handed to the `katex` command line, which writes
 * MathML. Only the `<math>` element is kept; Grimoire's site and EPUB carry
 * it, and its printable book prints the TeX source KaTeX keeps in the
 * element's annotation. Nothing is shipped to the reader: browsers and EPUB
 * readers draw MathML themselves.
 *
 * The contract, the fences, the settings and the concurrency come from
 * Grimoire's plugin kit (`./pluginkit.j`, a copy of Grimoire's own); what is
 * here is the syntax, the KaTeX command line, and the shape of the MathML a
 * chapter gets back.
 * @module katex
 * @author mplx <mplx@jennifer-lang.dev>
 * @license LGPL-3.0-only
 */
use io;
use fs;
use path;
use json;
use strings;
use lists;
use maps;
use convert;
use regex;
use encoding;

import "./pluginkit.j" as kit;

# Caps, in bytes: one formula's TeX, and the MathML KaTeX writes for it. A
# formula is a line or a few; one far beyond either is a mistake or an attack,
# and it throws "limit".
def const MAX_SOURCE as int init 65536;
def const MAX_OUTPUT as int init 1048576;

# Always passed to KaTeX, so a runaway macro or an absurd size is an error or a
# cap rather than a hang or a page-sized box: at most 1000 macro expansions
# (KaTeX's own default, stated here so it cannot change underneath a book), and
# no user-given size above 100 em.
def const MAX_EXPAND as string init "1000";
def const MAX_SIZE as string init "100";

# KaTeX draws a command it may not run (`\href` without `--trust`) in its error
# colour instead of failing. This colour is passed as that error colour and is
# looked for in the output, so such a formula stops the build like any other
# error.
def const ERROR_COLOUR as string init "010203";

def const SETTINGS as list of string init [
    "inline",
    "macros",
    "macroFile",
    "strict",
    "leqno",
    "fleqn",
    "program",
    "jobs"
];

# The characters Markdown, or a later preprocessor, could still read in the
# text between the tags: emphasis, code, links, Grimoire's mark / sub / sup,
# table cells, macros (`{{ }}`) and shortcodes (`:x:`). They are written as
# numeric entities, which every edition reads back as the character.
def const ENCODED as list of string init [
    "\\",
    "`",
    "*",
    "_",
    "[",
    "]",
    "\{",
    "\}",
    "~",
    "=",
    "^",
    "|",
    ":"
];

# --- settings ---------------------------------------------------------

/**
 * What the `[preprocessor.katex]` table says, checked and with defaults.
 * @field inline {bool} typeset `` $`...`$ `` as well as math fences
 * @field macros {list of string} `-m` definitions, `\name:expansion`, sorted
 * @field macroFile {string} a macro file, resolved against `book.src`, or ""
 * @field strict {bool} KaTeX's LaTeX-faithful mode
 * @field leqno {bool} equation numbers on the left
 * @field fleqn {bool} display maths flush left
 * @field program {string} katex's command: a name on PATH or a path
 * @field jobs {int} formulas typeset at a time; 0 is one per CPU
 */
export def struct Settings {
    inline as bool,
    macros as list of string,
    macroFile as string,
    strict as bool,
    leqno as bool,
    fleqn as bool,
    program as string,
    jobs as int
};

# macrosOf reads the `macros` table: a macro name, starting with a backslash,
# to its expansion. Sorted, so the command line does not depend on the order
# the table was written in.
func macrosOf(req as json.Value) {
    def out as list of string;
    if (not kit.hasSetting($req, "macros")) {
        return $out;
    }
    def at as string init "/plugin/settings/macros";
    if (json.typeOf($req, $at) != "map") {
        kit.fail("setting `macros` must be a table of macro names to expansions");
    }
    for (def name in lists.sort(json.keys($req, $at))) {
        def value as string init $at + "/" + kit.pointerKey($name);
        if (not regex.matches('^\\[A-Za-z]+$|^\\.$', $name)) {
            kit.fail("macro `" + $name + "` is not a macro name: a backslash and letters");
        }
        if (json.typeOf($req, $value) != "string") {
            kit.fail("macro `" + $name + "` must expand to a string");
        }
        $out[] = $name + ":" + json.asString($req, $value);
    }
    return $out;
}

/**
 * Read the settings from a request.
 *
 * Every key is checked: an unknown one is a typo or a setting of another
 * plugin, and building without it would typeset the book some way nobody asked
 * for. `macroFile` is resolved against `book.src` and has to exist.
 * @param req {json.Value} the decoded request
 * @return {Settings} the settings, with defaults filled in
 * @throws {Error} kind "plugin" for an unknown key, a value of the wrong kind,
 *   a bad macro name or a missing macro file
 */
export func settingsOf(req as json.Value) {
    kit.checkSettings($req, SETTINGS);
    def s as Settings init Settings{
        inline: kit.settingBool($req, "inline", true),
        macros: macrosOf($req),
        macroFile: kit.settingText($req, "macroFile", ""),
        strict: kit.settingBool($req, "strict", false),
        leqno: kit.settingBool($req, "leqno", false),
        fleqn: kit.settingBool($req, "fleqn", false),
        program: kit.settingText($req, "program", ""),
        jobs: kit.settingInt($req, "jobs", 0)
    };
    if ($s.program == "") {
        $s.program = "katex";
    }
    if ($s.jobs < 0) {
        kit.fail("setting `jobs` must be 0 or more");
    }
    if ($s.macroFile != "") {
        if (not path.isAbs($s.macroFile)) {
            $s.macroFile = path.join(json.asString($req, "/book/src"), $s.macroFile);
        }
        if (not fs.isFile($s.macroFile)) {
            kit.fail("macro file not found: " + $s.macroFile);
        }
    }
    return $s;
}

/**
 * The arguments every KaTeX call gets, before `-d` for display maths.
 * @param s {Settings} the settings
 * @return {list of string} the arguments
 */
export func argsOf(s as Settings) {
    def out as list of string init [
        "-F",
        "mathml",
        "-e",
        MAX_EXPAND,
        "-s",
        MAX_SIZE,
        "-c",
        ERROR_COLOUR
    ];
    if ($s.strict) {
        $out[] = "-S";
    }
    if ($s.leqno) {
        $out[] = "--leqno";
    }
    if ($s.fleqn) {
        $out[] = "--fleqn";
    }
    if ($s.macroFile != "") {
        $out[] = "-f";
        $out[] = $s.macroFile;
    }
    for (def m in $s.macros) {
        $out[] = "-m";
        $out[] = $m;
    }
    return $out;
}

# --- finding the maths ------------------------------------------------

/**
 * One formula in a chapter.
 * @field chapter {string} the chapter's `src`
 * @field line {int} the line it starts on, from 1
 * @field display {bool} a math fence, rather than inline
 * @field tex {string} the TeX source
 * @field first {int} display: the fence's first line index; inline: the
 *   offset of its `$` in the paragraph text
 * @field last {int} display: the fence's last line index; inline: the offset
 *   just past its closing `$`
 * @field indent {string} display: the fence's indentation
 */
export def struct Formula {
    chapter as string,
    line as int,
    display as bool,
    tex as string,
    first as int,
    last as int,
    indent as string
};

# checkSize refuses a formula over the source cap.
func checkSize(f as Formula) {
    if (encoding.lenBytes($f.tex) > MAX_SOURCE) {
        kit.failAt(
            "limit",
            $f.chapter,
            $f.line,
            "the formula is over " + convert.toString(MAX_SOURCE) + " bytes");
    }
}

/**
 * The display formulas in a chapter: its `math` fences.
 * @param chapter {string} the chapter's `src`, for errors
 * @param content {string} the chapter's Markdown
 * @return {list of Formula} the formulas, in order
 * @throws {Error} kind "plugin" for an unclosed or empty math fence; "limit"
 *   over the source cap
 */
export func displaysIn(chapter as string, content as string) {
    def out as list of Formula;
    for (def f in kit.fencesIn($content)) {
        if (kit.languageOf($f.info) != "math") {
            continue;
        }
        if (not $f.closed) {
            kit.failAt("plugin", $chapter, $f.first + 1, "the math fence is never closed");
        }
        if (strings.trim($f.body) == "") {
            kit.failAt("plugin", $chapter, $f.first + 1, "the math fence is empty");
        }
        def formula as Formula init Formula{
            chapter: $chapter,
            line: $f.first + 1,
            display: true,
            tex: strings.trimRight($f.body),
            first: $f.first,
            last: $f.last,
            indent: $f.indent
        };
        checkSize($formula);
        $out[] = $formula;
    }
    return $out;
}

# How many times `mark` repeats in `chars` from `at`.
func runAt(chars as list of string, at as int, mark as string) {
    def n as int init 0;
    while ($at + $n < len($chars) and $chars[$at + $n] == $mark) {
        $n = $n + 1;
    }
    return $n;
}

# closingRun finds the backtick run of exactly `size` that closes a code span
# opened before `from`, or -1.
func closingRun(chars as list of string, from as int, size as int) {
    def i as int init $from;
    while ($i < len($chars)) {
        if ($chars[$i] != "`") {
            $i = $i + 1;
            continue;
        }
        def n as int init runAt($chars, $i, "`");
        if ($n == $size) {
            return $i;
        }
        $i = $i + $n;
    }
    return -1;
}

# spanText is a code span's content as CommonMark reads it: line endings are
# spaces, and one space is taken off each end when both have one and the content
# is not all spaces.
func spanText(raw as string) {
    def text as string init strings.replace($raw, "\n", " ");
    if (len($text) >= 2 and strings.startsWith($text, " ") and strings.endsWith($text, " ") and
        strings.trim($text) != "") {
        return $text[1..len($text) - 1];
    }
    return $text;
}

# escapes reports whether the character at `i` is a backslash escaping the
# punctuation after it.
func escapes(chars as list of string, i as int) {
    return $chars[$i] == "\\" and $i + 1 < len($chars) and
        strings.contains(PUNCTUATION, $chars[$i + 1]);
}

# ASCII punctuation, which a backslash escapes in Markdown.
def const PUNCTUATION as string init "!\"#$%&'()*+,-./:;<=>?@[\\]^_`\{|\}~";

/**
 * The inline formulas in one paragraph's text: every code span that a `$`
 * opens and a `$` closes, `` $`...`$ ``.
 *
 * The text is read the way CommonMark reads code spans: a backslash escapes the
 * punctuation after it (so `` \$`x`$ `` is a dollar and a code span), a run of
 * backticks is closed only by a run of the same length, and every other code
 * span is skipped whole, `$` signs in it included.
 * @param chapter {string} the chapter's `src`, for errors
 * @param text {string} the paragraph, its lines joined by newlines
 * @param line {int} the paragraph's first line, from 1
 * @return {list of Formula} the formulas, offsets into `text`
 * @throws {Error} kind "plugin" for an empty formula; "limit" over the cap
 */
export func inlinesIn(chapter as string, text as string, line as int) {
    def out as list of Formula;
    def chars as list of string init strings.chars($text);
    def dollar as int init -2;
    def i as int init 0;
    while ($i < len($chars)) {
        def ch as string init $chars[$i];
        if (escapes($chars, $i)) {
            $i = $i + 2;
            continue;
        }
        if ($ch == "$") {
            $dollar = $i;
            $i = $i + 1;
            continue;
        }
        if ($ch != "`") {
            $i = $i + 1;
            continue;
        }
        def size as int init runAt($chars, $i, "`");
        def close as int init closingRun($chars, $i + $size, $size);
        if ($close < 0) {
            $i = $i + $size;
            continue;
        }
        def stop as int init $close + $size;
        if ($dollar == $i - 1 and $stop < len($chars) and $chars[$stop] == "$") {
            def tex as string init spanText(strings.join($chars[$i + $size..$close], ""));
            def at as int init $line +
                strings.count(strings.join($chars[..$i], ""), "\n");
            if (strings.trim($tex) == "") {
                kit.failAt("plugin", $chapter, $at, "the inline formula is empty");
            }
            def formula as Formula init Formula{
                chapter: $chapter,
                line: $at,
                display: false,
                tex: $tex,
                first: $i - 1,
                last: $stop + 1,
                indent: ""
            };
            checkSize($formula);
            $out[] = $formula;
            $i = $stop + 1;
            continue;
        }
        $i = $stop;
    }
    return $out;
}

/**
 * A run of lines that may hold inline maths: consecutive lines outside fences
 * that are not blank, as Markdown's paragraphs, headings and list items are.
 * @field first {int} the first line's index
 * @field last {int} the last line's index
 */
export def struct Block {
    first as int,
    last as int
};

# The columns a line is indented by, tabs to the next multiple of four.
func columnsOf(line as string) {
    def width as int init 0;
    for (def ch in strings.chars($line)) {
        if ($ch == " ") {
            $width = $width + 1;
        } elseif ($ch == "\t") {
            $width = $width + 4 - $width % 4;
        } else {
            return $width;
        }
    }
    return $width;
}

/**
 * The blocks of a chapter inline maths is looked for in.
 *
 * Fenced code is skipped, and so is a block whose first line is indented four
 * columns or more after a blank line, which is indented code at the top level.
 * A list item's continuation indented that far is skipped too; the README says
 * to indent less.
 * @param lines {list of string} the chapter's lines
 * @return {list of Block} the blocks
 */
export func blocksOf(lines as list of string) {
    def out as list of Block;
    def fenced as list of bool init kit.fencedLines(strings.join($lines, "\n"));
    def i as int init 0;
    while ($i < len($lines)) {
        if ($fenced[$i] or strings.trim($lines[$i]) == "") {
            $i = $i + 1;
            continue;
        }
        def j as int init $i;
        while ($j + 1 < len($lines) and not $fenced[$j + 1] and
            strings.trim($lines[$j + 1]) != "") {
            $j = $j + 1;
        }
        def afterBlank as bool init $i == 0 or strings.trim($lines[$i - 1]) == "";
        if (not ($afterBlank and columnsOf($lines[$i]) >= 4)) {
            $out[] = Block{first: $i, last: $j};
        }
        $i = $j + 1;
    }
    return $out;
}

# --- the MathML -------------------------------------------------------

# The `<math>` element in KaTeX's output, without the `span.katex` around it.
func elementOf(output as string) {
    def start as int init strings.indexOf($output, "<math");
    def stop as int init strings.lastIndexOf($output, "</math>");
    if ($start < 0 or $stop < $start) {
        return "";
    }
    return $output[$start..$stop + len("</math>")];
}

/**
 * MathML with the characters Markdown could still read turned into numeric
 * entities, in its text only: tags and attribute values are left as they are.
 * @param markup {string} the element
 * @return {string} the element, safe in a paragraph
 */
export func encoded(markup as string) {
    def out as list of string;
    def inTag as bool init false;
    for (def ch in strings.chars($markup)) {
        if ($ch == "<") {
            $inTag = true;
        } elseif ($ch == ">") {
            $inTag = false;
        } elseif (not $inTag and lists.contains(ENCODED, $ch)) {
            $out[] = "&#" + convert.toString(convert.toCodepoint($ch)) + ";";
            continue;
        }
        $out[] = $ch;
    }
    return strings.join($out, "");
}

/**
 * KaTeX's first message line: the `ParseError: ...` line of a Node stack trace
 * without the error's class, or the first line of its output otherwise.
 * @param stderr {string} what KaTeX wrote to stderr
 * @param stdout {string} what it wrote to stdout
 * @return {string} the message
 */
export func messageOf(stderr as string, stdout as string) {
    for (def line in strings.split($stderr, "\n")) {
        def m as regex.Match init regex.find('^\s*[A-Za-z]*Error: (.+)$', $line);
        if ($m.start >= 0) {
            return strings.trim($m.groups[0]);
        }
    }
    def first as string init kit.firstLine($stderr);
    if ($first != "") {
        return $first;
    }
    return kit.firstLine($stdout);
}

/**
 * Typeset one formula: the kit's worker, run concurrently.
 * @param ctx {json.Value} `program` and `args`, from `contextOf`
 * @param item {json.Value} `tex`, `display`, and the `chapter` and `line` of
 *   the first place it was written
 * @return {string} the `<math>` element, its text encoded
 * @throws {Error} kind "plugin" for a formula KaTeX refuses; "limit" over the
 *   output cap
 */
export func typeset(ctx as json.Value, item as json.Value) {
    def chapter as string init json.asString($item, "/chapter");
    def line as int init json.asInt($item, "/line");
    def program as string init json.asString($ctx, "/program");
    def argv as list of string init [$program];
    for (def i in 0..json.length($ctx, "/args")) {
        $argv[] = json.asString($ctx, "/args/" + convert.toString($i));
    }
    if (json.asBool($item, "/display")) {
        $argv[] = "-d";
    }
    def ran as kit.Ran init kit.runProgram($argv, json.asString($item, "/tex"));
    if (not $ran.started) {
        kit.failAt("plugin", $chapter, $line, $program + ": " + $ran.message);
    }
    if ($ran.exitCode != 0) {
        kit.failAt("plugin", $chapter, $line, messageOf($ran.stderr, $ran.stdout));
    }
    if (encoding.lenBytes($ran.stdout) > MAX_OUTPUT) {
        kit.failAt(
            "limit",
            $chapter,
            $line,
            "the MathML is over " + convert.toString(MAX_OUTPUT) + " bytes");
    }
    def element as string init elementOf($ran.stdout);
    if ($element == "") {
        kit.failAt("plugin", $chapter, $line, $program + " wrote no MathML");
    }
    if (strings.contains($element, '"#' + ERROR_COLOUR + '"')) {
        kit.failAt(
            "plugin",
            $chapter,
            $line,
            "KaTeX cannot typeset a command in this formula without --trust, which is never given");
    }
    return encoded($element);
}

# contextOf is what every typesetting task gets.
func contextOf(s as Settings) {
    def args as list of string;
    for (def a in argsOf($s)) {
        $args[] = json.encode($a);
    }
    return json.decode('{"program":' + json.encode($s.program) + ',"args":[' +
        strings.join($args, ",") + ']}');
}

# The key a formula is typeset once under: the mode and the source.
func keyOf(f as Formula) {
    if ($f.display) {
        return "d " + $f.tex;
    }
    return "i " + $f.tex;
}

# --- rewriting a chapter ----------------------------------------------

# displayBlock is a display element as an HTML block: the opening tag alone on
# its line, which is what makes Markdown read a block, then the rest of the
# element on the next, both at the fence's indentation.
func displayBlock(markup as string, indent as string) {
    def open as int init strings.indexOf($markup, ">");
    return $indent + $markup[..$open + 1] + "\n" + $indent +
        $markup[$open + 1..len($markup)];
}

# rewriteBlock replaces the inline formulas of one block, back to front so the
# offsets stay good.
func rewriteBlock(text as string, formulas as list of Formula, typeset as map of string to string) {
    def out as string init $text;
    def k as int init len($formulas) - 1;
    while ($k >= 0) {
        def f as Formula init $formulas[$k];
        $out = $out[..$f.first] + $typeset[keyOf($f)] +
            $out[$f.last..len($out)];
        $k = $k - 1;
    }
    return $out;
}

/**
 * One chapter with its maths replaced: each math fence by its element as an
 * HTML block with a blank line on either side, and each inline formula by its
 * element in the line.
 * @param content {string} the chapter's Markdown
 * @param displays {list of Formula} its math fences, from `displaysIn`
 * @param blocks {list of Block} its blocks, from `blocksOf`
 * @param inlines {list of list of Formula} each block's inline formulas
 * @param typeset {map of string to string} each formula's element, by `keyOf`
 * @return {string} the chapter
 */
export func rewrite(
    content as string,
    displays as list of Formula,
    blocks as list of Block,
    inlines as list of list of Formula,
    typeset as map of string to string) {
    def lines as list of string init strings.split($content, "\n");
    def out as list of string;
    def d as int init 0;
    def b as int init 0;
    def i as int init 0;
    while ($i < len($lines)) {
        if ($d < len($displays) and $displays[$d].first == $i) {
            def f as Formula init $displays[$d];
            if (len($out) > 0 and strings.trim($out[len($out) - 1]) != "") {
                $out[] = "";
            }
            $out[] = displayBlock($typeset[keyOf($f)], $f.indent);
            $i = $f.last + 1;
            if ($i < len($lines) and strings.trim($lines[$i]) != "") {
                $out[] = "";
            }
            $d = $d + 1;
            continue;
        }
        if ($b < len($blocks) and $blocks[$b].first == $i) {
            def block as Block init $blocks[$b];
            def text as string init strings.join($lines[$block.first..$block.last + 1], "\n");
            if (len($inlines[$b]) > 0) {
                $text = rewriteBlock($text, $inlines[$b], $typeset);
            }
            $out[] = $text;
            $i = $block.last + 1;
            $b = $b + 1;
            continue;
        }
        $out[] = $lines[$i];
        $i = $i + 1;
    }
    return strings.join($out, "\n");
}

# --- the request ------------------------------------------------------

# missing says what to do about a katex that cannot be run.
func checkProgram(s as Settings) {
    def ran as kit.Ran init kit.runProgram([$s.program, "--version"], "");
    if (not $ran.started) {
        kit.fail(kit.missingProgram(
            $s.program,
            $ran.message,
            "katex (npm install -g katex)",
            "program"));
    }
    if ($ran.exitCode != 0) {
        kit.fail(kit.missingProgram(
            $s.program,
            "--version exited " + convert.toString($ran.exitCode),
            "katex (npm install -g katex)",
            "program"));
    }
}

# One chapter's maths, found before anything is typeset.
def struct Found {
    src as string,
    content as string,
    displays as list of Formula,
    blocks as list of Block,
    inlines as list of list of Formula,
    count as int
};

func foundIn(src as string, content as string, inline as bool) {
    def out as Found init Found{
        src: $src,
        content: $content,
        displays: displaysIn($src, $content),
        blocks: [],
        inlines: [],
        count: 0
    };
    $out.count = len($out.displays);
    if (not $inline) {
        return $out;
    }
    def lines as list of string init strings.split($content, "\n");
    for (def block in blocksOf($lines)) {
        def text as string init strings.join($lines[$block.first..$block.last + 1], "\n");
        def formulas as list of Formula init inlinesIn($src, $text, $block.first + 1);
        $out.blocks[] = $block;
        $out.inlines[] = $formulas;
        $out.count = $out.count + len($formulas);
    }
    return $out;
}

/**
 * Answer one request: typeset every formula and rewrite the chapters that had
 * any.
 * @param req {json.Value} the decoded request, checked by `kit.request`
 * @return {string} the reply, as JSON
 * @throws {Error} kind "plugin" for a Grimoire without `mathml`, a bad setting,
 *   a missing katex or a formula KaTeX refuses; "limit" over a cap
 */
export func replyFor(req as json.Value) {
    kit.requireFeature($req, "mathml");
    def s as Settings init settingsOf($req);
    # Every formula first, so a syntax error stops the build before anything runs.
    def chapters as list of Found;
    def total as int init 0;
    for (def i in 0..json.length($req, "/chapters")) {
        def at as string init "/chapters/" + convert.toString($i);
        def found as Found init foundIn(
            json.asString($req, $at + "/src"),
            json.asString($req, $at + "/content"),
            $s.inline);
        $chapters[] = $found;
        $total = $total + $found.count;
    }
    def replies as list of string;
    if ($total == 0) {
        return kit.preprocessorReply($replies);
    }
    checkProgram($s);
    # One KaTeX call per distinct formula, remembered with the first place it
    # was written, which is the one an error names.
    def items as list of json.Value;
    def keys as list of string;
    def seen as map of string to int;
    for (def c in $chapters) {
        def all as list of Formula init $c.displays;
        for (def formulas in $c.inlines) {
            $all = lists.concat($all, $formulas);
        }
        for (def f in $all) {
            if (maps.has($seen, keyOf($f))) {
                continue;
            }
            $seen[keyOf($f)] = 1;
            $keys[] = keyOf($f);
            $items[] = json.decode('{"tex":' + json.encode($f.tex) + ',"display":' +
                json.encode($f.display) + ',"chapter":' + json.encode($f.chapter) +
                ',"line":' + convert.toString($f.line) + '}');
        }
    }
    def results as list of string init kit.work($s.jobs, typeset, contextOf($s), $items);
    def done as map of string to string;
    for (def k in 0..len($keys)) {
        $done[$keys[$k]] = $results[$k];
    }
    for (def c in $chapters) {
        if ($c.count == 0) {
            continue;
        }
        $replies[] = kit.chapterReply(
            $c.src,
            rewrite($c.content, $c.displays, $c.blocks, $c.inlines, $done));
    }
    return kit.preprocessorReply($replies);
}

/**
 * Run the plugin over one request.
 * @param request {string} the JSON request from stdin
 * @return {int} the exit status
 */
export func run(request as string) {
    try {
        io.printf("%s", replyFor(kit.request($request, "preprocessor")));
        return 0;
    } catch (e) {
        return kit.report("grimoire-katex", $e.message);
    }
}
