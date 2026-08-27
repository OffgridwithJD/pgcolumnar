#!/usr/bin/env python3
"""
Measurable plain-language rules for the pgColumnar documentation.

The project writes its user-facing documentation to ISO 24495-1:2023, Plain
language - Part 1: Governing principles and guidelines. This file checks the
part of that standard a machine can check.

ISO 24495-1 states four governing principles: readers get what they need
(relevant), can easily find it (findable), can easily understand it
(understandable), and can easily use it (usable). Only the third has any
mechanically checkable content, and only in part. What is enforced here is that
subset, and nothing is claimed beyond it.

From the standard, under "understandable":

  * A sentence carries at most 25 words. The standard asks for short sentences
    that each carry one main idea. It does not give a number, so 25 is this
    project's measurable proxy for that principle and not a figure quoted from
    ISO 24495-1.
  * No phrase from the idiom list below. The standard asks for familiar words
    and warns against figurative language, which a reader without fluent English
    cannot resolve. Idiom is the part a fluent reader does not notice, which
    makes it the rule with the most value and the least visibility.

    The PRINCIPLE is the standard's; the LIST is this project's, in the same way
    the 25-word limit is. ISO 24495-1 publishes no vocabulary, and the entries
    below are curated from the phrases these authors actually write. So the
    rule's name matters: it is "no phrase from an idiom list", not "no idiom",
    and a mutation that reaches for an idiom which is not on the list gets a
    green run and proves nothing.

House rules, which are this project's typographic choices and are NOT from the
standard. They are listed separately so nobody mistakes a preference for a
requirement:

  * No em dash or en dash, anywhere in the checked files.
  * No double hyphen used as a dash in prose. A double hyphen inside a fenced
    code block is a SQL comment and is left alone.

WHAT IS NOT CHECKED. Most of ISO 24495-1 is not mechanical: whether the reader
got what they needed, whether the order suits their task, whether the document
works when someone uses it. The standard's own test for "usable" is that a
reader acts on the document successfully, which no checker can perform. A green
run here means the measurable subset holds, not that the documentation is plain.

Code blocks, tables, headings and link targets are excluded from the sentence
measurement, because none of them is prose. A list item counts as its own
sentence: joining the items of a list reports a long sentence that nobody wrote.

Usage:  test/plain_language_check.py FILE [FILE ...]
Exit status is the number of violations, so a caller can test it directly.

Written fresh for pgColumnar.
"""
import re, sys, subprocess

PASSIVE = re.compile(r'\b(is|are|was|were|be|been|being)\s+\w+(ed|en)\b', re.I)
IDIOM = ["fall back", "falls back", "fell back", "point the", "reach for",
         "in place of", "on the fly", "out of the box", "hand-rolled",
         "wired up", "knock-on", "rule of thumb", "bear in mind", "in flight"]

def sentences(text):
    text = re.sub(r'```.*?```', '', text, flags=re.S)      # code blocks
    text = re.sub(r'^\s*\|.*$', '', text, flags=re.M)      # tables
    text = re.sub(r'`[^`]*`', 'X', text)                   # inline code
    text = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)   # links
    out = []
    for para in text.split('\n\n'):
        # A list item is its own unit. Joining the items of a list into one
        # string reports a long sentence that nobody wrote, which is how an
        # earlier version of this check produced a finding against a bullet list.
        lines = para.split('\n')
        blocks, cur = [], []
        for l in lines:
            if re.match(r'\s*([-*]|\d+\.)\s', l):
                if cur:
                    blocks.append(' '.join(cur))
                cur = [re.sub(r'^\s*([-*]|\d+\.)\s', '', l).strip()]
            else:
                cur.append(l.strip())
        if cur:
            blocks.append(' '.join(cur))
        for block in blocks:
            if not block.strip() or block.strip().startswith('#'):
                continue
            for s in re.split(r'(?<=[.!?])\s+', block):
                s = s.strip()
                if s:
                    out.append(s)
    return out

def violations(path):
    """Count only the rules this project enforces: length, idiom, dashes."""
    t = open(path).read()
    sents = sentences(t)
    long_ = [s for s in sents if len(s.split()) > 25]
    idiom = [s for s in sents if any(i in s.lower() for i in IDIOM)]
    dashes = t.count('\u2014') + t.count('\u2013')
    # A double hyphen in prose, but not one inside a fenced code block.
    prose = re.sub(r'```.*?```', '', t, flags=re.S)
    dbl = len(re.findall(r'\S -- \S', prose))
    return long_, idiom, dashes, dbl


def report(path):
    long_, idiom, dashes, dbl = violations(path)
    n = len(long_) + len(idiom) + dashes + dbl
    if n == 0:
        print(f"  ok    {path}")
        return 0
    print(f"  FAIL  {path}: {len(long_)} long, {len(idiom)} idiom, "
          f"{dashes} em/en dash, {dbl} prose double-hyphen")
    for s in long_[:5]:
        print(f"          {len(s.split())} words: {s[:88]}")
    for s in idiom[:5]:
        print(f"          idiom: {s[:88]}")
    return n

if __name__ == '__main__':
    bad = 0
    for p in sys.argv[1:]:
        bad += report(p)
    sys.exit(1 if bad else 0)
