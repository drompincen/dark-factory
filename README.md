# Dark Factory

An interactive presentation on AI-driven software engineering maturity, based on Dan Shapiro's five-level framework — from "spicy autocomplete" to a fully autonomous **dark factory** where no human writes or reviews code.

**[View Presentation](https://drompincen.github.io/dark-factory/)**

## The Five Levels

| Level | Name | Who does the work |
|-------|------|-------------------|
| 0 | Spicy autocomplete | Human, with inline AI suggestions |
| 1 | Coding intern | Human delegates scoped tasks to AI |
| 2 | Junior developer | AI handles multi-file changes; human reads all code |
| 3 | Developer as manager | AI authors PRs; human reviews at feature level |
| 4 | Developer as product manager | Human writes specs, evaluates outcomes; code is a black box |
| 5 | **Dark factory** | Spec → software, fully autonomous; no human reads diffs |

## Key Concepts

- **Autonomy vs. control**: Higher autonomy levels require stronger evaluation infrastructure, not just better prompts.
- **Holdout scenario suites**: Behavioral specs stored *outside* the repo so agents can't overfit to the tests they can see.
- **Digital twins**: Simulated external services enabling full integration testing without touching real APIs or data.
- **Enterprise tiering**: Not every system should target Level 5 — a portfolio approach by risk class is recommended.

## Delivery system

A working design for running delivery this way with a real team: several hundred Claude Code sessions that take Jira tickets and prove them up a ladder (local spotlight, test track, UAT, prod, regression), coordinated only through git.

**[Browse the delivery system](https://drompincen.github.io/dark-factory/delivery-system/)** once this is on `main`, or read the files here:

| File | What it is |
|------|------------|
| [`delivery-system/README.txt`](delivery-system/README.txt) | What is in the directory, and the one-time checklist for the harness team |
| [`delivery-system/DELIVERY-AGENT.txt`](delivery-system/DELIVERY-AGENT.txt) | The core manual every session reads at the start |
| [`delivery-system/manual/`](delivery-system/manual/) | The parts read when needed: concepts, setup, deliver, coordinate, templates |
| [`delivery-system/proof-driven-delivery-system.txt`](delivery-system/proof-driven-delivery-system.txt) | The spec: why the system is shaped this way |
| [`delivery-system/tools/dq`](delivery-system/tools/dq) | The coordination tool, with [`selftest.sh`](delivery-system/tools/selftest.sh) |
| [`FEEDBACK.txt`](FEEDBACK.txt) | A review of version 0.2 at 300 to 600 sessions |
| [`FEEDBACK-RESOLUTION.txt`](FEEDBACK-RESOLUTION.txt) | Each point of that review, and where it was fixed |

## Deployment

The presentation is deployed automatically to GitHub Pages on every push to `main` via GitHub Actions (`.github/workflows/pages.yml`).
