# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

This is a **multi-context monorepo**: each top-level folder is a self-contained project with its own domain, not a shared `src/` tree. A context = a top-level project folder (`MLOps-Module-3`, `AWS-bedrock-agentcore-pipeline`, `freshbasket-churn`, `mlops-pune-price-prediction`, `pune-price-prediction-fastapi`, `SecureLife-MCP-Project`, `Snapshot30000`, `M5_Lab_E_BentoML`, etc.).

## Before exploring, read these

- **`CONTEXT-MAP.md`** at the repo root — it points at one `CONTEXT.md` per project folder. Read the entry (and its `CONTEXT.md`) relevant to whichever project you're touching.
- **`docs/adr/`** at the repo root — read ADRs that record cross-project / repo-wide decisions (tooling, CI, shared conventions).
- **`<project-folder>/docs/adr/`** — read ADRs scoped to the specific project you're working in.

If any of these files don't exist yet, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

```
/
├── CONTEXT-MAP.md
├── docs/adr/                          ← repo-wide decisions (CI, shared tooling, conventions)
├── MLOps-Module-3/
│   ├── CONTEXT.md
│   └── docs/adr/                      ← decisions scoped to this project
├── MLOps-Module-4/
│   ├── CONTEXT.md
│   └── docs/adr/
├── AWS-bedrock-agentcore-pipeline/
│   ├── CONTEXT.md
│   └── docs/adr/
└── freshbasket-churn/
    ├── CONTEXT.md
    └── docs/adr/
```

(Every top-level project folder follows the same `CONTEXT.md` + `docs/adr/` shape once it has one — not just the examples above.)

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in that project's `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR (repo-wide or project-scoped), surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_
