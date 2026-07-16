# NextStep AI Contracts

These files are Draft 2020-12 **proposal/result envelopes**, not database records. Production acceptance requires two gates:

1. JSON Schema validation with formats enabled and unknown fields rejected.
2. Semantic validation against the request allow-list, canonical entity versions, source hashes/anchors, rights policy and planning rules.

Contracts:

- `document-parse.schema.json`
- `paper-search.schema.json`
- `source-verification.schema.json`
- `guided-learning-package.schema.json`
- `daily-action.schema.json`
- `weekly-plan.schema.json`
- `highlight.schema.json`
- `citation.schema.json`
- `quiz.schema.json`
- `replan.schema.json`
- `ink-recognition.schema.json`

The client rejects a schema version it does not support, preserves the raw bounded artifact for diagnostics where safe, and never writes it over user source/ink. Markdown may be a rendered field but is never the canonical response envelope.

`document-parse.schema.json` is v2 because it adds exact, validated UTF-16
occurrences for every fact candidate. The app migrates bounded v1 parse results
in memory by resolving the legacy value against its declared source anchors;
the original raw envelope remains immutable.
