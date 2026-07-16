# 11 — Security, Privacy and Copyright

## Threat and trust boundaries

Protected assets include notes/ink/audio, academic/career documents, goals/calendar, credentials/bookmarks, source provenance and plan decisions. Untrusted inputs include imported files/packages, web responses, AI output, sync files, malformed future schemas and URLs.

Trust order is: user-confirmed or verified source facts → deterministic derived data → AI proposals. Confidence never raises a proposal to verified authority.

## Data minimization and privacy

- No mandatory NextStep account, ad/analytics SDK or remote backend.
- Default processing is local. Network source lookup sends only query/identifier needed for that connector.
- Future remote AI/BYOK is off by default, contract-scoped and requires disclosure of fields/source ranges leaving the device.
- Calendar permission is read-only in v1 unless a later explicit write feature is separately authorized.
- Photos, microphone, speech and Files use just-in-time permission explanations.
- Logs redact titles, text, URLs containing tokens, file names and recognized content.
- AI invocation history stores hashes/IDs and policy outcome, not raw prompts by default.

## Storage and sync security

- iOS data protection applies to local database/blobs; security-scoped bookmark data is stored with appropriate file protection.
- iCloud Drive uses the user's Apple account and quota. NextStep v1 does not claim independent end-to-end encryption beyond Apple's service protections.
- Live SQLite is never synced. Every change/blob has library ID, schema, length and SHA-256; unexpected/mismatched content is quarantined.
- Imported paths reject traversal, symlinks and nested-root attacks; reads/writes are bounded and atomically staged.
- Operation IDs and base revisions stop replay/duplicate application; HLC validation limits absurd clock values.
- Protected concurrent changes require human conflict resolution. No silent last-write overwrite.
- Device retirement and tombstone purge require confirmation and record an audit event.

Application-level encrypted sync is deferred until a recovery-key and multi-device key distribution design can avoid permanent data loss. This limitation is visible in Settings.

## Source integrity and prompt injection

- Imported/web text is content, never executable instructions. Prompts delimit source chunks and forbid following embedded directives.
- Model output cannot choose tools, URLs, files or database operations directly.
- URL policy allows `https` and explicitly supported DOI/file-opening flows; redirects are bounded and final canonical URL is recorded.
- Citation metadata is cross-checked; unknown IDs/anchors and claims outside accessible text are rejected.
- Hard facts require source/user confirmation even when confidence is high.

## Copyright and lawful access

- Preserve user-provided files the user is entitled to use; record rights basis and access date.
- Store bibliographic metadata, necessary quotation, summary, user annotation and source location. Do not redistribute an unlicensed full paper.
- Legal full-text links may point to publisher, author repository, institutional repository, arXiv, SSRN, PubMed Central or verified open-access location.
- Metadata/abstract-only access is labeled; the system must not imply it read unseen pages.
- Exports provide toggles for source, ink, highlights, AI annotations, recognized text and citations; rights warnings appear before embedding full source content.
- Current-affairs packages quote minimally, link originals and distinguish reporting from system summary.

## User control

- Show storage location, sync devices/status/conflicts, model/provider status and data leaving device.
- Export canonical data, raw ink and provenance in documented formats.
- Deleting local data creates a tombstone for sync; “delete everywhere” explains propagation and backup limits.
- Source/AI-derived content can be removed without deleting raw user ink/source.

## Security verification

- Malformed archive/schema/fuzz tests, zip-bomb/size/path/link tests and asset hash mutation.
- Sync replay, duplicate, truncated file, stale base, concurrent protected edits and device retirement.
- Prompt-injection fixtures and fabricated DOI/anchor/reference rejection.
- Privacy manifest/permissions review, log redaction tests and export-content tests.
- Dependency/license inventory; pin CI actions by commit and review model/data licenses before distribution.
