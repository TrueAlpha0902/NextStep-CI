# NextStep Product Handoff Index

This index is the implementation entry point. Documents are normative in numerical order; later documents apply the decisions made earlier without reopening them.

1. [Repository Current-State Audit](00_CURRENT_STATE_AUDIT.md)
2. [Product Vision Gap Analysis](01_VISION_GAP_ANALYSIS.md)
3. [Revised Product Requirements](02_PRODUCT_REQUIREMENTS.md)
4. [Information Architecture](03_INFORMATION_ARCHITECTURE.md)
5. [User Flows](04_USER_FLOWS.md)
6. [Domain and Data Model](05_DOMAIN_DATA_MODEL.md)
7. [AI and Source Grounding](06_AI_SOURCE_GROUNDING.md)
8. [Guided Learning Package](07_GUIDED_LEARNING_PACKAGE.md)
9. [Planning and Replanning](08_PLANNING_REPLANNING.md)
10. [UI/UX Specification](09_UI_UX_SPECIFICATION.md)
11. [Technical Architecture](10_TECHNICAL_ARCHITECTURE.md)
12. [Security, Privacy and Copyright](11_SECURITY_PRIVACY_COPYRIGHT.md)
13. [Phased Implementation Roadmap](12_IMPLEMENTATION_ROADMAP.md)
14. [Acceptance Criteria](13_ACCEPTANCE_CRITERIA.md)
15. [First Complete Vertical Slice](14_FIRST_VERTICAL_SLICE.md)
16. [Phase-1 Repository Change Map](15_PHASE1_FILE_MAP.md)

Supporting implementation contracts:

- [Live implementation status and remaining release gates](IMPLEMENTATION_STATUS.md)
- [Design system](../Design/README.md)
- [Strict AI JSON Schemas](../../Schemas/AI/README.md)

Locked V1 decisions:

- Core functionality has no required paid service.
- iPhone uses a compact tab/stack information architecture; it is not a scaled-down iPad view.
- Same-Apple-ID sync uses the same user-selected iCloud Drive folder on both devices and is eventual, not promised real-time/background-immediate.
- Each device keeps a local SQLite projection; iCloud transports immutable change packs/blobs, never a live SQLite database.
- iOS/iPadOS 18 minimum; Foundation Models/Apple Intelligence is optional on iOS/iPadOS 26+.
- “eip pencil” is treated as a generic third-party stylus; Apple Pencil pressure/tilt/hover/double-tap/squeeze use runtime capability gates.
- Windows receives an interactive contract web twin, not Apple Simulator or native PencilKit/iCloud verification.
