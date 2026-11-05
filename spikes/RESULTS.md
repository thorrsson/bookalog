# Comparative spike evidence

**Status: local two-client/two-backend matrix and native bounded exchange implemented; Flutter + Supabase selected for production implementation.** This is not a production-readiness report. A successful local test is not evidence that hosted identity, private storage, or a different operating system works.

## Evidence collected

| Area | Evidence | Limitation |
|---|---|---|
| Common catalog | Exactly 5,000 validated editions across 2,500 works; Unicode, missing ISBN/cover references, precise/partial/unknown dates, duplicate and malformed fixtures | Synthetic source data; cover objects are not implemented |
| PostgreSQL | Actual engine: non-member isolation, viewer write denial, direct-write/privilege bypass denial, optimistic revision conflict, atomic audit rollback, revocation | Comparison read projection, not final catalog schema |
| Supabase-style protocol | Actual PostgREST: signed test JWT verification, all 5,000 rows over five pages, role denial, successful edit and HTTP 409 conflict | Not hosted Supabase; Google OAuth, Storage, backup recovery unverified |
| Google Cloud-oriented gateway | Actual HTTP server plus PostgreSQL: authorization boundary, reads, writes, validation and conflict mapping | Tests inject an identity verifier; production Firebase verification, Cloud SQL/Run/Storage deployment unverified |
| Client/backend matrix | Actual Dart and Rust HTTP adapters each read all 5,000 records through PostgREST and the gateway; denied viewer writes, rejected invalid/unapproved identities, successful editor writes, stale revisions, and exactly one audit event per successful write | Gateway verifier is injected; these are synthetic local identities, not Google sign-in or hosted-provider qualification |
| Flutter | Analysis/unit/widget checks; connection/edit controls with preserved conflict drafts; short/failed/duplicate-page and revocation tests; narrow-screen scrolling; native exchange, 24-hour policy, authenticated encryption; macOS compilation succeeds without signing | Signed build requires a matching Mac development provisioning profile; OS Keychain and native dialog behavior not verified |
| Tauri | TypeScript/Vite build, Rust tests, macOS debug application bundle; browser fixture table inspected with native IPC disabled | Native dialogs/Keychain and iOS/Android/Windows execution still require qualification |
| XLSX/ONIX | Both native languages read shared fixtures and export 5,000 editions; independent Node readers compare all XLSX projected values and ONIX identifiers/titles/forms; malformed files, oversized grids, formulas, external links, and entities are rejected | Bounded seven-column XLSX and illustrative ONIX only; no import commit, lossless interchange, recipient compatibility, or mobile file-provider qualification |

Both desktop UI slices are diagnostic surfaces, not competing finished product designs. Flutter currently uses a virtualized list; Tauri uses paginated rows. Do not infer comparative performance or UX superiority from that difference. No comparable startup/scroll/memory benchmark has been recorded.

## UI refinement

Impeccable's Operate/polish guidance was applied without replacing the diagnostic visual identity. Search and catalog rows take priority; file exchange and synthetic cache actions are grouped behind a disclosure instead of seven equal-weight buttons. Connected source/role remains visible after saves, failed loads offer fixture recovery, and empty search has a clear action. Tauri title editing moves keyboard focus to the editor and restores it afterward. Flutter uses native Material controls, scrollable content at narrow widths, and inline feedback for blank titles.

Flutter tracks catalog availability separately from utility errors: a failed file/cache operation preserves the loaded catalog and offers clear-search recovery rather than incorrectly reporting that no catalog is loaded. Clear search restores keyboard focus. Fixture restoration clears connected records before loading, so a failed restoration cannot leave those records in synthetic export tools. Widget regressions cover the error/search interaction, search focus and counts, and failed-load recovery.

The browser fixture surface was inspected at desktop-panel and 390px widths. The table scrolls within its own region rather than overflowing the document; body text contrast was approximately 12.9:1 and web controls retain 44px targets. The scoped Impeccable detector reported no findings. This is a focused usability refinement, not production design sign-off or native-device accessibility certification.

## Selected production direction

The local comparison supports Flutter + Supabase for this small internal catalog. Flutter offers the broader maintained cross-platform native ecosystem for the stated future mobile parity; Supabase has lower operational overhead than maintaining the Google Cloud gateway path for a 2-10 person team. The user authorized this choice and implementation. The app in `app/` now has coordinated gallery/table/release-calendar views, common sorting and identity/date-range filters, responsive details, new works/additional editions, revision-checked metadata and edition-scoped relationship editing, member administration, and private cover upload/replacement/removal. SQL regressions cover authorized/audited changes, relationships, cover keys, and Storage policies.

Production offline metadata browsing now uses AES-GCM encrypted per-account snapshots and a server-signed 24-hour membership lease. The service verifies identity/membership independently; Dart verifies an actual server-generated Ed25519 signature in the regression suite. Startup recovery, expiry, clock rollback, encrypted-file replay, account separation, and sign-out cleanup have local coverage. Covers are not cached, unsigned snapshots are not usable offline, and no public key means online-only operation. This supersedes the earlier unleased in-memory fallback, but does not qualify hosted Edge Functions or actual OS secure storage.

The selected app now also supports a ten-field core-metadata CSV/XLSX exchange workflow: explicit mappings and ignored-column acknowledgment, per-row create/update/conflict review, atomic confirmed writes, request-ID retries, source-hash duplicate protection, and immutable downloadable import reports. Relationship assignments/covers are deliberately excluded and preserved on update. The XLSX codec is shared with the spike. Local tests verify 5,000 exported records field-for-field, with an independent reader, and server-side imports at the 5,000-row boundary. This is not a complete catalog backup, source reconciliation, or native file-dialog qualification.

The production app separately implements a provisional ONIX 3.0 reference-tag core profile, not the illustrative spike. It requires a supplied publisher on export, preserves explicit edition/work identities and date precision, rejects unsupported content/codes, and sends reviewed imports through the same atomic RPC. Source references, sender, timestamp and publisher are retained as untrusted provenance in immutable reports. An independent Node parser verifies all nine projected values for 5,000 products. Those exports, an ISBN-bearing sample and an independently authored input validate against EDItEUR's classic 3.0.8 XSD/codelists issue 75. This establishes bounded profile behavior and schema validity, not complete ONIX support or recipient acceptance; internal revisions, relationships, covers and commercial metadata are not exported.

The selected-stack service wrapper now also runs actual local Supabase Auth, PostgREST and Storage over loopback HTTPS using a pinned CLI and disposable certificate authority. Synthetic password accounts exercise approval/denial, membership administration/revocation, refresh/logout, revision conflicts, relationships, retry-safe imports and private cover operations. The production lease handler uses real provider responses with its HTTPS requirement intact, and its resulting Ed25519 lease is verified. Already issued signed cover URLs remain usable until expiry even after membership revocation. This is local provider evidence, not Google OAuth or hosted Edge runtime qualification.

The same wrapper now runs the actual Supabase Dart SDK and app `CatalogRepository` against those services: account lifecycle, membership administration, parsing/edits/conflicts, additional editions, relationships, covers and import history/retries. This exposed and fixed a real cleanup defect: Storage returns an empty result for an RLS-filtered deletion, which was previously treated as success. The repository now requires exactly the requested object in the deletion response and otherwise reports an explicit cleanup failure. The live regression proves denied deletion leaves the bytes intact and authorized deletion removes them. Nine related catalog workflow regressions and the refreshed unsigned macOS archive pass. This does not qualify native UI, OS-backed session persistence, Google callbacks or signed runtime behavior.

A separate-object/catalog-data recovery drill now passes locally: all ten populated catalog tables are dumped and restored atomically after synthetic data loss, with exact row comparisons including relationships, audit/history and membership state. A subsequent edit checks restored sequences and revisions, and replaying the import request returns its original report. Database restore alone leaves the cover missing; independently restored downloaded bytes match their SHA-256 digest. The drill retains existing Auth users and schema in the same disposable stack, so it does not establish replacement-project recovery, credential recovery, hosted backup behavior or production RPO/RTO.

Pinned GitHub Actions checks now define Linux app/SQL/real-local-provider validation and unsigned macOS/Windows artifacts. Hosted run [42086709590](https://github.com/thorrsson/bookalog/actions/runs/42086709590) passed all three jobs for implementation commit `a20ba0d`; both downloaded native archives pass integrity checks. The local macOS wrapper also builds and archives successfully. The Mac bundle and Windows product metadata display Bookalog Catalog rather than the internal project name. A missing macOS user-selected file read/write entitlement was corrected for debug/profile and release builds. Signed native runtime has not been exercised. Synthetic desktop/narrow exchange renderings were inspected; these are not native file-dialog or platform accessibility certification.

Invitations remain an operator-managed Supabase Auth step; the client never receives an admin/service-role credential. Selection and local checks do not qualify Google OAuth callbacks, signed OS storage, hosted Storage/Functions, replacement-project recovery, production data, Windows/mobile execution, or cost. Relationship exchange and recipient approval beyond the bounded ONIX profile remain unfinished; relationship semantics remain provisional until source samples are reconciled. No cloud service has been provisioned.

## Concrete findings

- A server-side membership table and narrow mutation function can enforce the same basic authorization and concurrency contract through both access paths.
- PostgREST's default row limit requires explicit pagination; tests verify completeness and uniqueness across all five pages.
- Native adapters continue after short pages rather than assuming a short page means completion. Failed/duplicate pages and revoked membership fail the whole load instead of exposing a partial result. Redirects do not forward bearer tokens to another endpoint.
- Native connection controls are wired to these same adapters. Connected records cannot enter the synthetic cache/export path; test credentials remain in memory. Conflict errors leave title drafts intact.
- Native XLSX export uses explicit string cells, including formula-like titles, ISBNs, and partial dates. Rust uses `calamine`/`rust_xlsxwriter`; Dart uses `excel_community`. The Dart library requires styles even though XLSX makes them optional, so the adapter normalizes an absent styles relationship in memory and preserves the original file.
- Native file preflight bounds compressed size, ZIP expansion/entry count, and worksheet coordinates before workbook parsing. Spreadsheet formulas/external links and XML DTD/entities are outside this comparison profile and rejected.
- Browser previews hosted inside another Tauri app may expose that host's Tauri runtime. The comparison's browser entry point therefore explicitly disables native IPC rather than relying solely on `isTauri()`.
- Flutter's documented secure-storage capability needs suitable Apple signing/provisioning for native qualification. Existing local identity alone did not supply the required application profile; no profile was provisioned.
- Flutter has file-selector/share-sheet adapters wired, but mobile behavior is unverified. The current Tauri adapter handles native paths; Android content-provider URIs and mobile export/share remain gaps.
- The Tauri cache adapter deliberately fails closed on platforms without its implemented OS key-store adapter, including Android. That is an implementation gap, not proof that Tauri cannot support Android.
- The synthetic caches demonstrate encryption and a local expiry policy, not production offline authorization. They lack server-signed membership leases, complete account/revocation lifecycle integration, replay-resistant lease storage, and a qualified recovery strategy.

## Selected-stack release gates

| Gate | Required input or work |
|---|---|
| Hosted identity and storage | Approved disposable Supabase project, Google OAuth configuration, test members, private covers, and the offline lease function; no credentials in Git |
| Selected client/backend path | Real local SDK/repository integration now passes; hosted Google callbacks, OS-backed sessions and native UI interactions remain |
| Apple runtime | Matching local development profiles; signed cache/dialog verification; iOS simulator/device |
| Windows/Android | Appropriate SDKs/runners and physical-device verification of file providers, secure storage, and lifecycle |
| Future mobile file parity | Complete the selected app's save/share adapter and qualify file providers, secure storage, and lifecycle on devices; mobile release remains later work |
| Product data | Real schema/source samples, ONIX versions/code lists/recipients, and approved exchange limits/permissions |
| Recovery and cost | Region, cover sizes/retention, backup objectives, development environments, and observed provider usage |

These are unfinished work and verification gates. The local architecture decision is made, but production data must not be loaded and no production deployment should proceed until the applicable source, hosted-provider, platform, recovery, and cost gates are addressed. The documented Tauri/Google Cloud qualification gaps remain comparison limitations, not additional implementation work or release blockers for the selected stack.

## Cost comparison worksheet

| Component | Supabase | Google Cloud |
|---|---|---|
| Advertised starting point | Pro organization + one Micro project: $25/month; two Micro projects: about $35 before extras | Cloud SQL advertised from $9.37/month; region/configuration dependent |
| Identity/database API | Included services subject to quotas | Identity plus SQL Connect or an authenticated API; production desktop path must be proven |
| Private covers and transfer | Measure storage, egress, transformations | Measure Cloud Storage, operations, transfer |
| Backups | Daily database backup is not object backup; PITR costs extra | Cloud SQL retention/PITR plus separate object recovery |
| API/runtime/logging | Measure any functions and logging extras | Measure Cloud Run, networking, logging, secret/configuration services |
| Complete estimated total | **Unknown** | **Unknown** |

The $50/month target has not been demonstrated. Source pricing: [Supabase](https://supabase.com/pricing), [SQL Connect](https://firebase.google.com/docs/sql-connect/pricing). Provider budgets are alerts, not hard spending caps.
