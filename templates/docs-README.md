# docs/ — why things are the way they are

This folder holds **dated decision records**: whenever we change what this
product does (module selection, workflow design, infrastructure), we write
down *what we decided, when, and why* — so that months later we can
reconstruct the reasoning instead of re-researching it. This is a mandatory
practice, not an optional nicety: the record is written **in the same commit
(or PR) as the change it explains**.

Not for how-to/setup instructions (those live in `DEPLOY.md`, module READMEs,
or `platform/README.md`) and not for the per-module one-liners
(`selection_reasons.md`). This is for the *decisions behind* those files.

## Convention

- One file per decision or investigation: `decisions/YYYY-MM-DD-short-slug.md`
- Structure loosely as: **Context** (what prompted this), **Findings** (what
  we learned, with evidence), **Decision** (what we did and rejected
  alternatives), **Consequences / follow-ups**.
- Write it in the same commit (or PR) as the change it explains.
- Add every new record to the index below.
- Never rewrite old records to match later reality — add a new record and
  link back. A superseded record still explains why the old state existed.

## Index

<!-- - [YYYY-MM-DD — Title](decisions/YYYY-MM-DD-short-slug.md) -->
