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

## Deployment

The presentation is deployed automatically to GitHub Pages on every push to `main` via GitHub Actions (`.github/workflows/pages.yml`).
