# 06 — AI and Source-Grounding Architecture

## Authority boundary

AI produces typed **proposals**. Deterministic code validates structure, rights, references and constraints. Users confirm protected facts and consequential changes.

| Work | Device deterministic | Optional model | User gate |
| --- | --- | --- | --- |
| File hash/type/size, PDF text, date parsing | required | no | review only ambiguous facts |
| OCR/handwriting | Vision/local | optional local model | accept/correct before canonical text |
| Paper metadata | connector + cross-source match | ranking explanation | confirm use in thesis/citation |
| Summary/highlights/quiz | extractive fallback | local/Foundation Models/BYOK later | schema/evidence validation; edit allowed |
| Planning | constraint engine | decomposition/wording proposal | protected plan diff |
| Deadline/credit/grade/DOI | source/user authority | never authoritative | always source-verified or user-confirmed |

## Pipeline

```text
Import
→ quarantine, type/size/hash/rights
→ parse/OCR
→ stable chunks and anchors
→ metadata candidates
→ source connector verification
→ claim/evidence linking
→ strict JSON Schema validation
→ policy validation
→ proposal preview
→ user confirmation when required
→ canonical transaction + audit
```

All stages are resumable jobs with bounded input/output, cancellation, retry policy and idempotency key. OCR, indexing, networking and model work never block the ink/render main thread.

## Free provider strategy

Required core has no paid dependency:

- Apple PDFKit/Vision/NaturalLanguage/Speech, deterministic parsers and extractive tools.
- Crossref, OpenAlex, arXiv, PubMed/PMC, Unpaywall and official publisher/agency endpoints when their terms and rate limits permit.
- Official RSS/web sources plus manually imported sources for current affairs.
- Optional downloadable local models only after license, hash, memory and storage review.
- Foundation Models only when iOS/iPadOS 26+ and capability checks succeed.
- Future BYOK providers implement the same contracts, are off by default, and show exactly what leaves the device.

Offline mode uses verified cached metadata and local files. It queues discovery/enrichment and never invents missing URLs, dates or content.

## Search and retrieval

V1 retrieval is hybrid local FTS5 + deterministic metadata/concept links. Embeddings are an optional local index, derived and rebuildable; no remote vector database is required. Retrieval returns bounded chunks containing source ID, anchor ID, rights state, content hash and verification timestamp.

Model prompts receive only retrieved chunks and allowed profile context. Responses may reference only supplied IDs. Unknown IDs, unanchored quotations, DOI/author mismatches or claims outside accessible text fail validation.

## Paper verification

1. Normalize title, author names, year and DOI.
2. Resolve DOI through authoritative metadata; compare at least title + year + first author.
3. Preserve official publication URL separately from legal full-text links.
4. Record peer-review/preprint state as verified, unknown or conflicting—never infer certainty from venue text alone.
5. Hash user-provided/legal full text and record access date and rights basis.
6. A full-text claim requires an anchor in accessible content. Metadata/abstract-only records cannot support unseen page claims.
7. Page/section/paragraph locators are produced from the exact document version and become stale if the hash changes.

## Current-affairs grounding

Each ready event requires event date, publication date, at least one first-party source and one independent quality source when available. Conflicting accounts are represented as separate claims/evidence, not averaged into false certainty. Search time and access time are stored; weekly packages expire into archived snapshots rather than silently refresh.

## Formal contracts

`Schemas/AI` contains Draft 2020-12 schemas for document parse, paper search, verification, package, action, week, highlight, citation, quiz, replan and ink recognition. Contracts require:

- explicit `schemaVersion` and `requestID`;
- `additionalProperties: false` on every object;
- bounded arrays/strings and enumerated states;
- 0...1 confidence only for proposals;
- supplied source/anchor IDs, never generated bibliographic facts;
- no Markdown as the canonical envelope.

Schema success is necessary but insufficient. Semantic validators resolve every ID, compare hashes/revisions, enforce rights and recalculate scores/dates.

## Privacy and model invocation

`AIInvocationRecord` stores provider kind, local/remote execution, model/version, contract version, input source IDs/hashes (not raw content), output hash, policy result, duration and user consent reference. Raw prompts/responses are not retained by default. Remote invocation is impossible until a future explicit provider is configured and per-class data policy allows it.

## Failure behavior

- Invalid schema/unknown reference: discard proposal, retain diagnostic without user content.
- Source mismatch: quarantine metadata and show conflict.
- Rate limit/network: exponential backoff with jitter and visible queued state.
- Source removed: preserve citation metadata/anchor hash, show unavailable; do not erase user work.
- Model unavailable/low confidence: use extractive/manual workflow.
- Newer schema: preserve raw artifact but do not interpret or overwrite it.
