---
name: api-practices
description: API design and documentation standards for this repo. Use when creating, naming, renaming, or documenting any API, CLI flag, JSON schema, or public function. Use ONLY when the task touches an API surface or its docs.
---

# API Practices

These rules apply to every API introduced in this repo (Rocq definitions,
OCaml library functions, C++ frontend matchers, Rust CLI/JSON I/O, Python
helpers, and the `Mini*.json` schemas). They exist to keep the public surface
small and easy to hold in a programmer's head.

## 1. Document every API in `docs/API.md`

- One canonical API reference file: `docs/API.md`. No API docs live only in
  chat, comments, or commit messages.
- The same change that introduces or modifies an API MUST update `docs/API.md`
  (signature, purpose, parameters, returns, error cases, one minimal example).
- If an API has no docs entry, it does not exist — do not use it, do not merge it.

## 2. Create only necessary APIs

- Justify each new public symbol: what caller needs it, and why no existing
  API covers the need. Prefer extending an existing API over adding a new one.
- No speculative generality (YAGNI): no unused parameters, no "future-proof"
  options objects, no parallel APIs doing the same thing two ways.
- Keep pipeline boundaries narrow: stages talk only through the versioned
  `Mini*.json` schemas plus exit codes (see SRS §4 FR-4).

## 3. Names must be unique, clear, and concise

- Before naming, search the repo (`grep`) for near-duplicates; never introduce
  a second name for the same concept or reuse a name for a different concept.
- Clear over clever: full words, domain terms from the SRS (`map_kernel`,
  `MiniCUDA`, `WellSync`), no ad-hoc abbreviations (only repo-standard ones:
  `rocq`, `cli`, `dir`, `json`).
- Concise: drop redundant scope prefixes (`core_map_kernel` → `map_kernel`
  when already inside `core/`).
- One naming convention per language, matching that language's standard
  (e.g. `snake_case` for Rocq/OCaml/Python/Rust functions, `CamelCase` for C++
  matchers/types, `kebab-case` for CLI flags).

## 4. Lower memory stress on the programmer

- Small surface: fewer public symbols, fewer flags, fewer schema versions
  (exactly one active `Mini*.json` schema version at a time).
- Consistency: same verbs across languages (`parse`, `map`, `print`,
  `validate`); same error shape (`Unsupported(feature, loc, hint)`);
  same exit codes (`0` ok, `2` unsupported, `3` internal).
- Explicit over implicit: no hidden globals, no magic defaults — defaults are
  documented in `docs/API.md` next to the API.
- Stable contracts: never change a JSON field's meaning in place; bump the
  schema version and document the migration.

## 5. Pre-merge checklist for any API change

1. `docs/API.md` updated in the same change.
2. Name uniqueness verified by search; no shadowing across stage boundaries.
3. No new API without a caller in-tree (prototype, test, or validator).
4. SRS mapping table (`docs/SUPPORTED.md`) still matches implementation.
