# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

/**
 * White-box tests for `katex.j`, run by `jennifer test src/katex_test.j` from
 * the repository root (`scripts/test.sh` does that).
 *
 * KaTeX is `tests/fake-katex`, a shell script given through `program`, which
 * writes MathML shaped like KaTeX's and can be told to fail, stall or write
 * nothing. The real `katex` is tried at the end when it is installed.
 * @module katex_test
 * @author mplx <mplx@jennifer-lang.dev>
 * @license LGPL-3.0-only
 */
use testing;
use os;
use xml;

import "markdown.j" as markdown;
import "doctree.j" as doctree;

func fake() {
    return path.join(os.cwd(), "tests/fake-katex");
}

# A request as Grimoire 0.5.0 sends it. Raw strings for the JSON around it.
func requestWith(settings as string, chapters as map of string to string) {
    def parts as list of string;
    for (def src in $chapters) {
        $parts[] = '{"src":' + json.encode($src) + ',"content":' +
            json.encode($chapters[$src]) + '}';
    }
    return '{"api":1,"kind":"preprocessor","features":["files","mathml"],' +
        '"book":{"title":"T","description":"","authors":[],"language":"en",' +
        '"src":' + json.encode(os.cwd()) + ',"out":"site","generated":""},' +
        '"plugin":{"name":"katex","settings":' + $settings + ',"files":""},' +
        '"entries":[],"chapters":[' + strings.join($parts, ",") + ']}';
}

func fakeSettings(extra as string) {
    return '{"program":' + json.encode(fake()) + $extra + '}';
}

func one(src as string, content as string) {
    def out as map of string to string;
    $out[$src] = $content;
    return $out;
}

func replyTo(settings as string, chapters as map of string to string) {
    return replyFor(json.decode(requestWith($settings, $chapters)));
}

# The rewritten chapter `src` in a reply, or "" when the reply leaves it alone.
func chapterIn(reply as string, src as string) {
    def doc as json.Value init json.decode($reply);
    for (def i in 0..json.length($doc, "/chapters")) {
        def at as string init "/chapters/" + convert.toString($i);
        if (json.asString($doc, $at + "/src") == $src) {
            return json.asString($doc, $at + "/content");
        }
    }
    return "";
}

func texts(formulas as list of Formula) {
    def out as list of string;
    for (def f in $formulas) {
        $out[] = $f.tex;
    }
    return $out;
}

# --- display maths ----------------------------------------------------

func testAMathFenceIsDisplayMaths() {
    def found as list of Formula init displaysIn("a.md", "x\n\n```math\n\\sum_i i\n```\n");
    testing.assertEqual(len($found), 1);
    testing.assertTrue($found[0].display);
    testing.assertEqual($found[0].tex, "\\sum_i i");
    testing.assertEqual($found[0].line, 3);
    testing.assertEqual(len(displaysIn("a.md", "~~~~ math\na\n~~~~\n")), 1);
}

# Only `math`, exactly; any other fence, or a math fence shown inside a longer
# one, is code.
func testOtherFencesAreCode() {
    testing.assertEqual(len(displaysIn("a.md", "```tex\na\n```\n")), 0);
    testing.assertEqual(len(displaysIn("a.md", "```Math\na\n```\n")), 0);
    testing.assertEqual(len(displaysIn("a.md", "````md\n```math\na\n```\n````\n")), 0);
    testing.assertEqual(len(displaysIn("a.md", "text\n\n    ```math\n    a\n    ```\n")), 0);
}

func unclosedFence() {
    displaysIn("guide/a.md", "text\n\n```math\na\n");
}

func emptyFence() {
    displaysIn("a.md", "```math\n\n```\n");
}

func testABrokenFenceIsRefused() {
    testing.assertThrows("unclosedFence", "plugin");
    try {
        unclosedFence();
    } catch (e) {
        testing.assertEqual($e.message, "guide/a.md:3: the math fence is never closed");
    }
    testing.assertThrows("emptyFence", "plugin");
}

# --- inline maths -----------------------------------------------------

func testDollarBacktickIsInlineMaths() {
    def found as list of Formula init inlinesIn("a.md", "Let $`a^2`$ and $`b`$ be.", 4);
    testing.assertEqual(texts($found), ["a^2", "b"]);
    testing.assertEqual($found[0].first, 4);
    testing.assertEqual($found[0].last, 11);
    testing.assertEqual($found[0].line, 4);
    testing.assertFalse($found[0].display);
}

# A longer backtick run carries a backtick inside, as a code span does, and one
# space on each side comes off.
func testALongerRunCarriesABacktick() {
    testing.assertEqual(texts(inlinesIn("a.md", "x $`` a`b ``$ y", 1)), ["a`b"]);
}

# Code spans that are not `$`...`$` are code, dollars and all; so is a `$`
# before a backtick that a backslash escapes.
func testOtherCodeSpansAreLeftAlone() {
    testing.assertEqual(len(inlinesIn("a.md", "`$x$` and `$HOME`", 1)), 0);
    testing.assertEqual(len(inlinesIn("a.md", "``$`x`$`` is how", 1)), 0);
    testing.assertEqual(len(inlinesIn("a.md", "a \\$`x`$ b", 1)), 0);
    testing.assertEqual(len(inlinesIn("a.md", "price $5 and $`x` no", 1)), 0);
    testing.assertEqual(len(inlinesIn("a.md", "$`x` $", 1)), 0);
    testing.assertEqual(len(inlinesIn("a.md", "an \\`$`x`$ escaped tick", 1)), 1);
}

# Plain `$...$` and `$$...$$` are not maths: a technical book is full of `$HOME`
# and `$5`.
func testDollarsAloneAreNotMaths() {
    testing.assertEqual(len(inlinesIn("a.md", "$x$ and $$y$$", 1)), 0);
}

func testAFormulaMaySpanLines() {
    def found as list of Formula init inlinesIn("a.md", "one\ntwo $`a +\nb`$ three", 7);
    testing.assertEqual(texts($found), ["a + b"]);
    testing.assertEqual($found[0].line, 8);
}

func emptyInline() {
    inlinesIn("a.md", "x $` `$ y", 1);
}

func testAnEmptyInlineFormulaIsRefused() {
    testing.assertThrows("emptyInline", "plugin");
}

# Fenced code and indented code are not prose.
func testBlocksSkipCode() {
    def lines as list of string init strings.split(
        "Para $`a`$\nmore\n\n```\n$`b`$\n```\n\n    $`c`$\n\n# H $`d`$\n",
        "\n");
    def blocks as list of Block init blocksOf($lines);
    testing.assertEqual(len($blocks), 2);
    testing.assertEqual($blocks[0].first, 0);
    testing.assertEqual($blocks[0].last, 1);
    testing.assertEqual($blocks[1].first, 9);
}

# --- the MathML -------------------------------------------------------

# The text between the tags is what Markdown reads; tags and attributes are
# left alone, and an entity KaTeX wrote stays one.
func testOnlyTheTextIsEncoded() {
    testing.assertEqual(
        encoded('<mo stretchy="false">*</mo><mi>x_1</mi>&lt;[a]{b}'),
        '<mo stretchy="false">&#42;</mo><mi>x&#95;1</mi>&lt;&#91;a&#93;&#123;b&#125;');
    testing.assertEqual(encoded("\\`~=^|:"), "&#92;&#96;&#126;&#61;&#94;&#124;&#58;");
}

func testKatexsMessageIsItsFirstLine() {
    def stack as string init "/usr/lib/katex.js:17690\n    throw error;\n\n" +
        "ParseError: KaTeX parse error: Expected '\}' at end of input\n    at Parser.parse\n";
    testing.assertEqual(messageOf($stack, ""), "KaTeX parse error: Expected '\}' at end of input");
    testing.assertEqual(messageOf("something odd\nsecond\n", ""), "something odd");
    testing.assertEqual(messageOf("", "out\n"), "out");
}

# --- settings ---------------------------------------------------------

func settingsIn(settings as string) {
    return settingsOf(json.decode(requestWith($settings, one("a.md", "x"))));
}

func testTheDefaults() {
    def s as Settings init settingsIn('{}');
    testing.assertTrue($s.inline);
    testing.assertEqual(len($s.macros), 0);
    testing.assertEqual($s.macroFile, "");
    testing.assertFalse($s.strict);
    testing.assertEqual($s.program, "katex");
    testing.assertEqual($s.jobs, 0);
    testing.assertEqual(argsOf($s), ["-F", "mathml", "-e", "1000", "-s", "100", "-c", "010203"]);
}

# Every option reaches the command line, and the two that would let a formula
# write HTML or hide an error are never there.
func testTheSettingsReachTheCommandLine() {
    def s as Settings init settingsIn(
        '{"strict":true,"leqno":true,"fleqn":true,"macroFile":"tests/fake-katex",' +
            '"macros":{"\\RR":"\\mathbb{R}","\\A":"a"},"command":"x","args":[]}');
    def argv as list of string init argsOf($s);
    testing.assertEqual(
        $argv,
        [
            "-F",
            "mathml",
            "-e",
            "1000",
            "-s",
            "100",
            "-c",
            "010203",
            "-S",
            "--leqno",
            "--fleqn",
            "-f",
            path.join(os.cwd(), "tests/fake-katex"),
            "-m",
            "\\A:a",
            "-m",
            "\\RR:\\mathbb\{R\}"
        ]);
    testing.assertFalse(lists.contains($argv, "--trust"));
    testing.assertFalse(lists.contains($argv, "-T"));
    testing.assertFalse(lists.contains($argv, "-t"));
    testing.assertFalse(lists.contains($argv, "--no-throw-on-error"));
}

func unknownKey() {
    settingsIn('{"inlin":false}');
}

func commandIsGrimoires() {
    settingsIn('{"command":"/usr/bin/katex","katex":"x"}');
}

func badMacroName() {
    settingsIn('{"macros":{"RR":"x"}}');
}

func macroNotText() {
    settingsIn('{"macros":{"\\RR":1}}');
}

func missingMacroFile() {
    settingsIn('{"macroFile":"no/such.tex"}');
}

func inlineNotBool() {
    settingsIn('{"inline":"no"}');
}

func negativeJobs() {
    settingsIn('{"jobs":-2}');
}

func testBadSettingsAreRefused() {
    testing.assertThrows("unknownKey", "plugin");
    testing.assertThrows("commandIsGrimoires", "plugin");
    testing.assertThrows("badMacroName", "plugin");
    testing.assertThrows("macroNotText", "plugin");
    testing.assertThrows("missingMacroFile", "plugin");
    testing.assertThrows("inlineNotBool", "plugin");
    testing.assertThrows("negativeJobs", "plugin");
    try {
        missingMacroFile();
    } catch (e) {
        testing.assertContains($e.message, path.join(os.cwd(), "no/such.tex"));
    }
}

# --- the request ------------------------------------------------------

func testAGrimoireWithoutMathMlIsRefused() {
    def old as string init strings.replace(
        requestWith(fakeSettings(""), one("a.md", "$`x`$")),
        '"features":["files","mathml"]',
        '"features":["files"]');
    def threw as bool init false;
    try {
        replyFor(json.decode($old));
    } catch (e) {
        $threw = true;
        testing.assertContains($e.message, "Grimoire 0.5.0");
        testing.assertContains($e.message, "`mathml`");
    }
    testing.assertTrue($threw);
}

func testABookWithoutMathsRunsNothing() {
    def reply as string init replyTo(
        '{"program":"/no/such/katex"}',
        one("a.md", "`$x$` costs $5\n\n```tex\n\\frac\{a\}\{b\}\n```\n"));
    testing.assertEqual($reply, '{"api":1,"chapters":[]}');
}

func testRunRefusesWhatItCannotAnswer() {
    def good as string init requestWith(fakeSettings(""), one("a.md", "x"));
    testing.assertEqual(run($good), 0);
    testing.assertEqual(run(""), 1);
    testing.assertEqual(run(strings.replace($good, '"preprocessor"', '"renderer"')), 1);
}

# --- the rewrite, with the fake ---------------------------------------

# Display maths is an HTML block: the opening tag alone on its line, so
# Markdown reads a block, and a blank line on either side.
func testAFenceBecomesAnHtmlBlock() {
    def out as string init chapterIn(
        replyTo(fakeSettings(""), one("a.md", "Before\n```math\na*b*c\n```\nAfter\n")),
        "a.md");
    def lines as list of string init strings.split($out, "\n");
    testing.assertEqual($lines[0], "Before");
    testing.assertEqual($lines[1], "");
    testing.assertEqual(
        $lines[2],
        '<math xmlns="http://www.w3.org/1998/Math/MathML" display="block">');
    testing.assertTrue(strings.startsWith($lines[3], "<semantics>"));
    testing.assertTrue(strings.endsWith($lines[3], "</math>"));
    testing.assertEqual($lines[4], "");
    testing.assertEqual($lines[5], "After");
    # The span KaTeX wraps it in is for KaTeX's own CSS, and is gone.
    testing.assertFalse(strings.contains($out, "katex\""));
    def doc as doctree.Node init markdown.parse($out);
    testing.assertEqual($doc.children[1].kind, "html_block");
}

# Inline maths stays in its line, and asterisks or underscores in it do not
# turn into emphasis: they are entities by the time Markdown sees them.
func testInlineMathsStaysInItsParagraph() {
    def out as string init chapterIn(
        replyTo(fakeSettings(""), one("a.md", "Let $`a*b*c`$ and $`x_1 + y_1`$ hold.\n")),
        "a.md");
    testing.assertTrue(strings.startsWith($out, "Let <math xmlns="));
    testing.assertContains($out, "a&#42;b&#42;c</annotation>");
    testing.assertContains($out, "x&#95;1 + y&#95;1</annotation>");
    testing.assertTrue(strings.endsWith($out, "</math> hold.\n"));
    def para as doctree.Node init markdown.parse($out).children[0];
    testing.assertEqual($para.kind, "paragraph");
    for (def n in $para.children) {
        testing.assertTrue($n.kind == "text" or $n.kind == "html_inline");
    }
}

# A fence in a list item keeps the item's indentation on both lines.
func testAFenceInAListItemStaysInTheItem() {
    def out as string init chapterIn(
        replyTo(fakeSettings(""), one("a.md", "- item\n\n  ```math\n  a\n  ```\n")),
        "a.md");
    def lines as list of string init strings.split($out, "\n");
    testing.assertTrue(strings.startsWith($lines[2], "  <math "));
    testing.assertTrue(strings.startsWith($lines[3], "  <semantics>"));
}

func testInlineFalseLeavesInlineAlone() {
    def out as string init chapterIn(
        replyTo(fakeSettings(',"inline":false'), one("a.md", "$`a`$\n\n```math\nb\n```\n")),
        "a.md");
    testing.assertTrue(strings.startsWith($out, "$`a`$\n\n<math"));
}

# The same formula is typeset once, wherever it is written; the same source as
# display and inline is two formulas.
func testAFormulaIsTypesetOnce() {
    def marks as string init fs.makeTempDir(os.tempDir(), "katex-marks-");
    os.setEnv("FAKE_KATEX_DIR", $marks);
    def chapters as map of string to string;
    $chapters["a.md"] = "$`x`$ and $`x`$\n\n```math\nx\n```\n";
    $chapters["b.md"] = "again $`x`$\n";
    replyTo(fakeSettings(',"jobs":1'), $chapters);
    os.unsetEnv("FAKE_KATEX_DIR");
    def calls as list of string init strings.split(
        strings.trim(fs.readString(path.join($marks, "peak"))),
        "\n");
    testing.assertEqual(len($calls), 2);
    fs.removeAll($marks);
}

func testDisplayMathsAsksForDisplayMode() {
    def out as string init chapterIn(
        replyTo(fakeSettings(""), one("a.md", "```math\nx\n```\n\n$`y`$\n")),
        "a.md");
    testing.assertContains($out, "display=\"block\"");
    testing.assertContains($out, "-F mathml -e 1000 -s 100 -c 010203 -d</mtext>");
    testing.assertContains($out, "-F mathml -e 1000 -s 100 -c 010203</mtext>");
}

# --- errors -----------------------------------------------------------

func testARefusedFormulaNamesItsPlace() {
    def chapters as map of string to string;
    $chapters["a.md"] = "$`fine`$\n";
    $chapters["guide/b.md"] = "# B\n\ntext and\n$`x BROKEN`$\n";
    def threw as bool init false;
    try {
        replyTo(fakeSettings(""), $chapters);
    } catch (e) {
        $threw = true;
        testing.assertEqual($e.kind, "plugin");
        testing.assertEqual(
            $e.message,
            "guide/b.md:4: KaTeX parse error: Undefined control sequence: \\BROKEN at position 1");
    }
    testing.assertTrue($threw);
}

func testTheFirstFailureInTheBookIsReported() {
    def chapters as map of string to string;
    $chapters["a.md"] = "```math\nSLOW BROKEN one\n```\n";
    $chapters["b.md"] = "$`BROKEN two`$\n";
    def threw as bool init false;
    try {
        replyTo(fakeSettings(',"jobs":2'), $chapters);
    } catch (e) {
        $threw = true;
        testing.assertTrue(strings.startsWith($e.message, "a.md:1: "));
    }
    testing.assertTrue($threw);
}

# A command KaTeX may not run without --trust is drawn in the error colour
# rather than refused; the plugin refuses it.
func testAnUntrustedCommandIsRefused() {
    def threw as bool init false;
    try {
        replyTo(fakeSettings(""), one("a.md", "x $`UNSAFE`$\n"));
    } catch (e) {
        $threw = true;
        testing.assertContains($e.message, "a.md:1: KaTeX cannot typeset");
        testing.assertContains($e.message, "--trust");
    }
    testing.assertTrue($threw);
}

func testNoMathMlIsAnError() {
    def threw as bool init false;
    try {
        replyTo(fakeSettings(""), one("a.md", "$`EMPTY`$\n"));
    } catch (e) {
        $threw = true;
        testing.assertContains($e.message, "wrote no MathML");
    }
    testing.assertTrue($threw);
}

func testAMissingKatexSaysWhatToInstall() {
    def threw as bool init false;
    try {
        replyTo('{"program":"grimoire-katex-no-such-katex"}', one("a.md", "$`x`$\n"));
    } catch (e) {
        $threw = true;
        testing.assertContains($e.message, "install katex");
        testing.assertContains($e.message, "`program`");
    }
    testing.assertTrue($threw);
}

func oversized() {
    inlinesIn("a.md", "$`" + strings.repeat("x", MAX_SOURCE + 1) + "`$", 1);
}

func testAFormulaOverTheCapThrowsLimit() {
    testing.assertThrows("oversized", "limit");
}

# --- concurrency ------------------------------------------------------

func peakOf(dir as string) {
    def most as int init 0;
    for (def line in strings.split(strings.trim(fs.readString(path.join($dir, "peak"))), "\n")) {
        def n as int init convert.toInt(strings.trim($line));
        if ($n > $most) {
            $most = $n;
        }
    }
    return $most;
}

func fourFormulas() {
    def chapters as map of string to string;
    for (def i in 0..4) {
        def n as string init convert.toString($i);
        $chapters["c" + $n + ".md"] = "$`x_" + $n + "`$\n";
    }
    return $chapters;
}

func testJobsBoundsHowManyRunAtOnce() {
    def marks as string init fs.makeTempDir(os.tempDir(), "katex-marks-");
    os.setEnv("FAKE_KATEX_DIR", $marks);
    replyTo(fakeSettings(',"jobs":1'), fourFormulas());
    testing.assertEqual(peakOf($marks), 1);
    fs.remove(path.join($marks, "peak"));
    replyTo(fakeSettings(',"jobs":4'), fourFormulas());
    testing.assertTrue(peakOf($marks) > 1);
    os.unsetEnv("FAKE_KATEX_DIR");
    fs.removeAll($marks);
}

func testTheResultDoesNotDependOnTheOrderTheyFinish() {
    def chapters as map of string to string init fourFormulas();
    $chapters["c0.md"] = "$`SLOW`$\n";
    testing.assertEqual(
        replyTo(fakeSettings(',"jobs":1'), $chapters),
        replyTo(fakeSettings(',"jobs":4'), $chapters));
}

# --- the real katex ---------------------------------------------------

func installed(program as string) {
    return kit.onPath($program) != "";
}

def const REAL_BOOK as string init "# Maths\n\nInline $`a*b*c + x_1`$ and " +
    "$`\\frac\{1\}\{2\}`$.\n\n" +
    "```math\n\\sum_\{i=1\}^\{n\} i = \\frac\{n(n+1)\}\{2\}\n```\n\n" +
    "```math\n\\begin\{pmatrix\} a & b \\\\ c & d \\end\{pmatrix\}\n```\n";

func testRealKatexGivesTheSameBytesTwice() {
    if (not installed("katex")) {
        return;
    }
    def a as string init replyTo('{}', one("a.md", REAL_BOOK));
    testing.assertEqual(replyTo('{"jobs":1}', one("a.md", REAL_BOOK)), $a);
    def out as string init chapterIn($a, "a.md");
    testing.assertEqual(strings.count($out, "<math "), 4);
    # Every element is XML once the entities are read back.
    def doc as doctree.Node init markdown.parse($out);
    testing.assertEqual($doc.children[2].kind, "html_block");
    testing.assertEqual(xml.localName(xml.decode(strings.trim($doc.children[2].text))), "math");
}

func testRealKatexRefusesBadTex() {
    if (not installed("katex")) {
        return;
    }
    def threw as bool init false;
    try {
        replyTo('{}', one("a.md", "x\n\n$`\\frac\{a`$\n"));
    } catch (e) {
        $threw = true;
        testing.assertTrue(strings.startsWith($e.message, "a.md:3: KaTeX parse error: "));
        testing.assertFalse(strings.contains($e.message, "node_modules"));
    }
    testing.assertTrue($threw);
    $threw = false;
    try {
        replyTo('{}', one("a.md", "$`\\href\{https://e.com\}\{x\}`$\n"));
    } catch (e) {
        $threw = true;
        testing.assertContains($e.message, "--trust");
    }
    testing.assertTrue($threw);
}
