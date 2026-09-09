# Architecture decision records

One file per decision, named `NNNN-short-slug.md`. Read the directory listing rather than an index: a
hand-maintained list of every record goes stale the first time someone is in a hurry, and the filenames
already say what each one is about.

The format, when to write one, and the rule that a changed decision gets a new record rather than an edit
to the old one are all in [`../conventions.md`](../conventions.md).

Numbers are grouped by subject:

| Range | Subject |
| --- | --- |
| 0001 to 0009 | Cross-cutting: toolchain, repository shape, CI, documentation |
| 0010 to 0019 | The guardrails stack |
| 0020 to 0029 | The bootstrap stack |
| 0030 to 0039 | The cluster stack |
| 0040 to 0049 | The platform layer |
| 0050 to 0059 | Scripts, tasks and the test suite |

Gaps in the numbering are normal. A number is never reused, so a record that was written and then dropped
leaves a hole, and the hole is more honest than renumbering everything after it.
