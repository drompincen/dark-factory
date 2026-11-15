# {{KEY}} journal

Timestamps are UTC, one on every log line. Elapsed time is measured from
them, and another session reads this file to pick up where you stopped.

## Problem, in my words

## Plan
Numbered steps. Mark each done as you go.

## Rebuild local state
What another machine must run to get back to where this one is.

- Spotlight (name and the exact start command):
- Fakers staged (the exact commands, in order):
- Seed data:
- Verification command:
- Worktrees (repo and branch for each):
- Track (which one, and whether a run is in flight):

## Log
{{NOW}} Claimed by {{SESSION}}.

## Attempts
One block per change-and-prove cycle, each starting with a heading line of
three hashes, the word Attempt and its number. The iterations budget
counts those headings. In each block: the time, what changed, which proof
ran, the result, kept or reverted, and the commit.

## Decisions
Decision, why, and whether the owner has seen it.

## Dead ends
What I tried that did not work, so nobody tries it again.

## Corrections received
Each correction, and the check proposed so it need not be repeated.

## Resume from
The step in DELIVER.txt, the last green commit in each repo, and the next
command to run.
