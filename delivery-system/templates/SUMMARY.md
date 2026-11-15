# {{KEY}} proof bundle

Verdict: (the state reached, in one line. For an item that was already
done, start with "Already satisfied" and say by which commit or item.)

Contract: items/{{KEY}}/contract.yaml
Tier:
Built by: {{ENGINEER}}, session {{SESSION}}
Written: {{NOW}}

## Change set
Repo, branch, commit for every repo involved.

## Environment
Spotlight or track used, and versions.

## Proofs
For each scenario: the proof, the result, and the path to its saved output.
Include the failing-first output from before implementation.

## Evidence stored outside the claim
Branch, commit and path of each large file (screenshots, recordings, full
logs), as printed by "dq evidence".

## Verification findings
What the fresh-eyes check found and what was done about each.

## Verified against
The visible proofs only. Product holds back scenarios that are run at UAT,
so say "verified against the visible proofs", never "fully verified".

## Not tested
Everything in scope that has no proof, and why.

## Risks and decisions to check
