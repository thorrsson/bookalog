# Bookalog catalog app

The selected production implementation is Flutter + Supabase. The app supports Google OAuth, approved memberships, coordinated gallery/table/release-calendar browsing, metadata and relationship editing, additional editions, private covers, member administration, signed-lease encrypted offline browsing, and reviewed core-metadata CSV/XLSX and provisional ONIX 3.0 exchange. It is not a finished production release.

## Configure a development project

1. Create a Supabase project and configure Google as an OAuth provider. Add the Supabase Auth callback URL shown by the provider setup to the Google OAuth client.
2. Add `com.bookalog.catalog://login-callback/` to the Supabase Auth redirect allowlist.
3. Apply **all** migrations in `supabase/migrations/` in filename order using the Supabase CLI or SQL editor. This requires the `storage` schema and a Supabase Auth instance; the migrations create the private `book-covers` bucket and role policies.
4. Bootstrap the first administrator by inserting the Auth user's UUID into `public.memberships` using an operator-only SQL connection. Never put a database password, service-role key, or migration credential in the app.
5. Run the app with the project URL and publishable key:

```sh
cd app
flutter run -d macos \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

The same Dart defines are used for `windows`, `ios`, and `android` targets. The URL scheme is registered for Apple and Android; Windows MSIX advertises the same protocol. Native browser callback, signed Keychain behavior, and Windows/mobile runtime behavior still require platform testing. Do not use a production catalog until those checks and the source-schema review are complete.

## Data and access

The provisional normalized schema models works, editions, ordered contributor credits, categories, revisions, immutable audit snapshots, and memberships. Editors/admins can create works and additional editions, edit metadata and relationships, and upload/replace/remove private covers. Every mutation is server-authorized and audited; updates reject stale revisions. Covers accept JPEG, PNG, or WebP up to 10 MiB and display through five-minute signed URLs. Membership revocation prevents new URLs, but an already issued URL remains usable until expiry; downloaded images cannot be recalled. Unsuccessful object cleanup is reported for operator attention. Removal requires the Storage response to identify the requested object; an empty RLS-filtered deletion result is not success.

Relationships are **edition-scoped**, with at most 100 credits and 100 categories per edition. Existing identities are preserved; contributors with the same name are not merged. New categories reuse an exact existing name. Additional editions reuse the work identity but do not copy ISBNs, relationships, or covers. Real source files and inheritance/code-list requirements may require reviewed schema changes.

Sorting and filtering are shared across all views. Contributor/category drill-down uses identities, not names. Date ranges include overlapping partial dates (a year or month represents its full interval), exclude unknown dates, and support a calendar-aware next-six-months shortcut.

The client uses only a publishable key and the signed-in user's token; RLS and narrow database functions enforce access. Administrators manage roles for already registered Auth accounts and deactivate members; invitation delivery remains operator-managed. Sessions are stored in OS-protected storage, namespaced by project. Upgrading from the earlier unscoped session key requires signing in again.

## Reviewed CSV/XLSX exchange

Open **Catalog tools > File exchange** while connected. All approved roles can export; importing requires an editor or administrator. Export rechecks access and reloads **all editions**, regardless of browsing filters. Files are unencrypted and require an explicit acknowledgment before export.

The provisional `bookalog-core` projection contains ten columns: `id`, `work_id`, `revision`, `title`, `format`, `language`, `isbn13`, `publication_status`, `release_date`, and `description`. It does **not** export contributor/category assignments, work-level metadata, or cover files and is not a backup or ONIX feed. XLSX writes text cells for exact text/identifier/date-precision preservation. CSV prefixes formula-like text (including leading apostrophes) with an apostrophe to reduce spreadsheet formula execution; that prefix is visible on reimport, so choose XLSX for exact text round-trips.

Import proceeds through file selection, column mapping, row-by-row preview, explicit confirmation, and a downloadable JSON result report. Required source mappings are title, format, language, and publication status. Each target uses a distinct source column; extra source columns require explicit acknowledgment before ignoring their values. Unmapped optional fields preserve existing metadata; mapped blank cells clear optional values.

Known edition IDs update those editions; supplied revisions must match, and every update checks the revision captured during preview. Blank edition IDs create new editions. A known work ID attaches an additional edition; otherwise each new row creates its own work. Unknown IDs, ISBN collisions, duplicate edition IDs/ISBNs, invalid dates, and unsupported enum values block the whole batch. Names and ISBNs are never automatically merged. Core imports preserve existing relationships and covers.

The server applies all reviewed rows in one transaction through the existing authorized/audited mutations. Any failure rolls back every row; unchanged rows do not create revisions or audit events. A client-generated request ID makes retries safe after a lost response. The same source SHA-256 cannot be imported twice under a new ID, preventing duplicate creates after a restart; consult history before creating a revised file. Source filename/hash, normalized input, actor, and successful per-row outcomes remain in immutable database history. Editors see their own recent reports; administrators see all. Keep the report/request ID when investigating an uncertain response rather than starting another import.

Limits: 5,000 data rows, 32 source columns, 8 MiB per file, 100,000 characters per cell, one XLSX sheet, 100 ZIP entries, and 32 MiB expanded XLSX data. CSV is UTF-8 with LF or CRLF line endings; headers must be nonempty and case-insensitively unique. XLSX numeric/date/formula cells, macros, embedded objects, external links, DTD/entity declarations, and oversized coordinates are rejected. Use text cells for ISBNs and partial dates. Export also enforces readable size limits. The shared spreadsheet codec in `packages/catalog_exchange/` is used by the production app and comparison spike.

Real publisher mapping/reconciliation, relationship exchange, and native picker/save behavior still require qualification; mobile file export remains deferred. ONIX now has its own deliberately bounded profile below, separate from the illustrative comparison spike.

## Provisional ONIX 3.0 core profile

The app implements `bookalog-onix-core-v1`: UTF-8 XML 1.0, ONIX release `3.0`, reference tags, and the namespace `http://ns.editeur.org/onix/3.0/reference`. Prefixed or default namespaces are accepted. This is a **provisional core projection, not a recipient-approved feed or a full catalog backup**. Local schema validation uses EDItEUR's classic 3.0.8 XSD and codelists issue 75; schema validity does not establish commercial completeness, source compatibility, or recipient acceptance.

On export, expand **ONIX 3.0 core profile**, enter the actual publisher name (also used as message sender), and acknowledge both the unencrypted-file warning and the profile limits. No publisher, price, rights, author, format detail, or date is invented. All editions are refreshed online and exported together, or the export fails with the offending edition's ID. Supported mappings are:

| Catalog field | ONIX representation |
|---|---|
| Edition ID | Proprietary `ProductIdentifier`, type `01`, name `Bookalog edition`; stable `RecordReference` is `urn:uuid:<edition-id>` |
| Work ID | `RelatedWork` relation `01`, proprietary work identifier named `Bookalog work` |
| Title | One distinctive title (`01`), one product-level title element (`01`), plain `TitleText` |
| Format | paperback `BC`, hardback `BB`, ebook `EA` (delivery detail unspecified), audio `AA` (carrier unspecified); composition `00` |
| ISBN-13 | Optional identifier type `15`, with checksum validation |
| Language | One language-of-text role `01`; explicit ISO 639-2/B code mapping, below |
| Publication status | planned: notification/status `01/02`; announced: `02/02`; released: `03/04`; out of print: `03/07` |
| Release date | Publishing date role `01`; `YYYY` -> format `05`, `YYYY-MM` -> `01`, `YYYY-MM-DD` -> `00`, with separators removed |
| Description | Optional main description (`TextType 03`), unrestricted content audience (`00`), plain-text format `06`; no XHTML |

These status mappings are provisional business semantics: planned is early notification, announced is confirmed advance notification, and released is active. Forthcoming products **must have an expected publication date**; a missing date blocks export/import rather than being fabricated. A catalog "released" record that is not active in the ONIX sense needs source reconciliation before distribution. Plain-text escaping preserves Unicode, literal markup, tabs, LF and CR. Empty descriptions and missing ISBN/release dates remain absent, except for the forthcoming-date requirement.

Supported language pairs are `en/eng`, `fr/fre`, `de/ger`, `es/spa`, `it/ita`, `pt/por`, `nl/dut`, `da/dan`, `sv/swe`, `no/nor`, `fi/fin`, `is/ice`, `pl/pol`, `cs/cze`, `el/gre`, `ru/rus`, `ar/ara`, `he/heb`, `hi/hin`, `ja/jpn`, `ko/kor`, and `zh/chi`. Export accepts either spelling in each pair. Import uses the two-letter spelling for new editions and preserves an existing equivalent spelling on updates. Regional/script tags, other languages, terminological aliases such as `deu`, and more specific product forms are rejected, not simplified.

Choose a `.xml` or `.onix` file to import. ONIX uses a fixed mapping rather than spreadsheet dropdowns, then the same row preview, explicit confirmation, role checks, atomic writes, retries, and duplicate-source protection. A non-Bookalog record reference is **not** treated as an edition ID. External records require an ISBN when they have no Bookalog identifier and propose creates; an ISBN already in the catalog blocks the row rather than merging it. Known explicit Bookalog edition/work UUIDs preserve identity; unknown local IDs block the file at review. ONIX carries no internal revision: updates compare the file with the catalog at preview time and use that current revision when applying. Review differences carefully before replacing newer metadata with an older source file.

Every imported product retains its profile, exact record reference, sender, sent timestamp and publisher in the immutable normalized request and downloadable outcome report. These are **source-supplied provenance, not authenticated publisher claims**, and do not change a global publisher setting or grant access. `source_row` is the product position plus one, matching the review table's logical header. The header accepts one sender name and a real UTC `SentDateTime` in `YYYYMMDDThhmmssZ` form. Each product accepts one publisher with role `01`.

The parser rejects all elements/attributes outside the documented profile, including contributors/categories, subtitles, collections, publisher IDs, prices, rights, supply blocks, cover links, additional identifiers/languages/dates, XHTML, deletions, partial/block updates, and test notifications. Existing relationships and covers are preserved; their absence never means "delete". Limits are 5,000 products, 8 MiB, 100,000 characters for descriptions, 500 for titles, 200 for provenance strings, 24 XML levels and 250,000 elements. Duplicate references, malformed dates/ISBNs, duplicate fields, unexpected ordering, foreign namespaces, DTD/entity declarations and processing instructions reject the whole file before any write. Convert or explicitly map a richer source through a reviewed profile extension; do not strip unsupported data just to make validation pass.

References: [EDItEUR schemas/specifications](https://www.editeur.org/93/Release-3.0-Downloads/), [notification types](https://ns.editeur.org/onix/en/1), [product forms](https://ns.editeur.org/onix/en/150), [publishing status](https://ns.editeur.org/onix/en/64), [languages](https://ns.editeur.org/onix/en/74), [date formats](https://ns.editeur.org/onix/en/55), [plain-text format](https://ns.editeur.org/onix/en/34).

## Offline access

Offline browsing is optional and disabled until the lease function and client public key are configured. It contains catalog metadata only, **not cover images**, and never permits edits or queues writes. A successful online load obtains an Ed25519-signed lease that expires exactly 24 hours after server-side identity and membership verification. Connectivity failures can restore a verified encrypted copy, including after app restart; unsigned in-memory data is not an authorization fallback.

Use an approved disposable project for initial setup. These commands are operator instructions, not automatic provisioning:

```sh
# From the repository root; choose a private location outside every Git checkout.
mkdir -m 700 "$HOME/.config/bookalog-offline"
ruby script/offline-lease-key.rb "$HOME/.config/bookalog-offline"
node_modules/.bin/supabase secrets set --remote=YOUR_PROJECT_REF \
  --env-file "$HOME/.config/bookalog-offline/.env.offline-lease"
node_modules/.bin/supabase functions deploy offline-lease --remote=YOUR_PROJECT_REF
```

These commands use the pinned Supabase CLI 3.0.0 installed by root `npm ci` and require an operator's separately authorized Supabase account. The helper writes an Ed25519 PKCS#8 private key as base64 in `.env.offline-lease` and a raw 32-byte public key as base64url in `offline-public-key.txt`. Files are created with mode `0600`; existing keys are never overwritten and private material is not printed. Keep the private key in approved secret storage, never Git or Dart defines. Ruby must support `OpenSSL::PKey.generate_key('ED25519')`.

The function requires `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` (or `SUPABASE_ANON_KEY`), and `OFFLINE_LEASE_PRIVATE_KEY`. Supabase supplies the URL and legacy anon key in its hosted runtime. It does not use a service-role key. `supabase/config.toml` deliberately disables the gateway JWT verifier for this function: **the handler independently verifies every bearer token via Supabase Auth, then checks the caller's active membership**. Do not remove either check. This works with legacy and asymmetric Auth signing keys.

Build/run with the usual project defines plus:

```sh
--dart-define=OFFLINE_LEASE_PUBLIC_KEY=PUBLIC_KEY_FROM_offline-public-key.txt
```

Snapshots are capped at 32 MiB/10,000 editions, AES-256-GCM encrypted per account/project, and written atomically. OS-protected storage holds the encryption key, encrypted-file digest, and last-observed clock value. Lease signatures, account binding, expiry, clock rollback, and file replacement are checked before access. Running sessions additionally use a monotonic timer. Confirmed edits refresh the saved metadata without extending its lease. Sign-out/account changes clear the saved copy; denied access, corrupt data, and expired leases fail closed. There is no unencrypted persistent fallback.

These are not tamper-proof DRM guarantees. A disconnected device can retain access until its lease expires; revocation is not instant. A fully compromised device or coordinated rollback of both protected storage and the clock is outside the demonstrated guarantees. OS secure-storage behavior, backup exclusion, and lifecycle must be qualified on each supported platform.

For key rotation, deploy the new private key and ship the corresponding public key together. Old clients cannot verify new leases; new clients discard old signed snapshots and must reconnect. There is no multi-key grace window. Roll back the function and matching client key together only if the previous key remains trusted; never restore a compromised key. Disabling the service stops renewal, not leases already issued. No production key or hosted project has been created by this repository.

## Validation

From the repository root, use the wrappers:

```sh
bash script/test-app.sh
bash script/test-supabase.sh
bash script/test-supabase-services.sh
```

The app wrapper requires Node (with native TypeScript stripping), the root npm dependencies, Ruby/OpenSSL, and Flutter. ONIX schema checks additionally require `curl`, `unzip`, and `xmllint`. It runs lease-service tests, produces a disposable server-signed vector, then runs Flutter analysis/unit/widget tests. These cover cross-language signatures, startup recovery, fail-closed offline access, exchange mapping/confirmation/retry behavior, and narrow layouts. Independent Node readers compare all ten XLSX fields and all nine ONIX-projected fields for 5,000 editions. The wrapper accepts test selectors, for example `bash script/test-app.sh test/exchange_workflows_test.dart`. `bash script/test-offline-lease.sh` runs just service/key-generation checks.

When ONIX fixtures are generated, the wrapper also validates the 5,000-product export, an ISBN-bearing export, and an independently authored input against the official XSD. `script/validate-onix.sh` downloads EDItEUR's schema archive to ignored `.cache/onix/` on first use and verifies its pinned SHA-256 before extraction; subsequent checks work offline with that archive. XML validation is local with `--nonet`; no catalog is uploaded. An upstream checksum change fails explicitly and requires review. The schema files are not vendored into the repository. This is the classic XSD check, not the advanced XSD 1.1 rules or a recipient's rules.

The SQL wrapper uses disposable PostgreSQL with mock Auth/Storage schemas to check authorization, audited revision changes, relationships, memberships, storage policies, atomic import rollback/idempotency, and the 5,000-row boundary. The separate real-service wrapper below covers the actual local provider APIs. Neither qualifies hosted services, OS secure-storage runtime, or native file dialogs. The comparison wrappers and evidence remain in the root README and `spikes/RESULTS.md`.

## Local provider and recovery checks

`bash script/test-supabase-services.sh` requires root `npm ci` (with an isolated cache), Node, Ruby/OpenSSL, Flutter and Docker. `FLUTTER_BIN` and `PUB_CACHE` can select an isolated Flutter SDK/cache. It runs the pinned Supabase CLI 3.0.0 in a private temporary directory with a unique project/network, unused loopback ports, and only the required services. It checks the actual published port bindings before creating any synthetic users or catalog records. A one-hour private certificate authority signs a localhost server certificate; its trust is scoped to the Node process through `NODE_EXTRA_CA_CERTS` and the Dart test's `SecurityContext`. The production handler's HTTPS requirement remains unchanged. No cloud account, service-role key in the app, paid project, or system trust-store change is required.

Real Auth signup/password sign-in, user lookup, refresh and logout are exercised with synthetic addresses and randomly generated passwords. Confirmation email is disabled only in the disposable test configuration. The first administrator is bootstrapped through the isolated operator connection; subsequent approvals and revocation use the application RPCs. The suite also checks unapproved-account isolation, viewer write denial, metadata conflicts, relationship identities, retry-safe imports with ONIX provenance, and actual private Storage upload/sign/download/delete. Existing signed cover URLs remain valid after membership revocation, while new requests are denied.

The real lease handler runs under Node with real HTTPS Auth/PostgREST calls, not mocked responses or a test transport. Its Ed25519 signature, issuer, account/role binding, 24-hour duration and denial after revocation are checked. This does **not** exercise the deployed Deno entry point, Google OAuth, native callbacks, or hosted key configuration.

The wrapper then calls the app test wrapper for `test/provider_integration_test.dart` while the services remain available. This uses actual Supabase Dart SDK sessions and `CatalogRepository`: password sign-in/refresh/sign-out, membership administration/revocation, denied reads/writes, catalog parsing, additional editions, metadata conflicts, relationship identities, cover upload/sign/download/removal, and import retry/history with provenance. It verifies Storage's empty response to a denied deletion and the app's explicit cleanup failure, followed by confirmed authorized removal. Credentials remain in a private disposable fixture file. This test is intentionally skipped in ordinary app-only runs; the service wrapper and CI run it with live fixtures. It does not initialize OS-backed session persistence or perform native UI/file-picker interactions.

The recovery drill populates every catalog table, takes a custom-format `pg_dump --data-only --schema=public` snapshot and separately downloads the cover bytes, then deletes that synthetic catalog data and object. `pg_restore --single-transaction --data-only` restores in dependency order with foreign keys and audit protections enabled; it does not require disabling system triggers. Exact rows across all ten tables are compared, including identities, relationships, revisions, membership state, audits and immutable import reports. A post-restore edit checks sequence continuity, audit insertion and revision handling; an import retry must return its original report. The database restore alone must still leave the cover unavailable, followed by separate object upload and SHA-256 comparison.

This is a **quiescent, same-stack catalog-data loss drill**, not a production backup utility or full disaster recovery. Existing Auth identities, database schema/roles/policies, platform secrets and runtime configuration are not destroyed or restored. Production recovery still requires an approved isolated replacement destination, provider-supported Auth/schema recovery, separate versioned cover backups, coordinated snapshots or a write-maintenance window, encrypted backup retention, agreed RPO/RTO, and hosted recovery evidence. Never point this destructive fixture test at an existing project; the wrapper accepts no target URL and binds its database connection to its newly created container.

Credentials, temporary backups/certificates, containers, data volumes and the private network are cleaned up on normal completion or test failure. Container/volume removal is verified; cleanup failures are reported explicitly and downloaded Docker images remain cached. A forced process/engine termination can require manual cleanup of the unique project ID printed at startup. The suite does not stop or reset other local Supabase projects.

## Desktop build checks and release boundary

From the repository root, `bash script/build-desktop.sh macos` creates `.cache/desktop/bookalog-macos-unsigned.zip`, preserving `Bookalog Catalog.app` and checking its display name. On a Windows host with Git Bash, Flutter, Visual Studio C++ tools and `7z` on PATH, use `bash script/build-desktop.sh windows` for `.cache/desktop/bookalog-windows-unsigned.zip`. Windows product metadata displays Bookalog Catalog; its internal executable remains `bookalog_catalog.exe`. The wrapper rejects unsupported targets and wrong hosts. Both Apple entitlements include sandboxed user-selected file read/write access, required for native import, cover picking and export.

The GitHub Actions workflow runs app/independent-reader/schema checks, disposable SQL regressions, and the real local provider/data-recovery wrapper sequentially on Ubuntu, followed by separate macOS and Windows build jobs. It uses pinned action revisions, the repository Node version, Flutter 3.47.9, a run-isolated npm cache, read-only repository permissions, and seven-day artifact retention. Hosted CI has completed the Linux checks and both native builds, and the downloaded archives pass integrity checks. It does not deploy infrastructure, use signing or production secrets, publish a release, or enable updates.

These artifacts deliberately have **no Supabase configuration** and are not signed/notarized installers. The Windows ZIP does not register the OAuth callback protocol; qualified Windows distribution must use a signed package with protocol registration (the MSIX configuration declares it). Do not treat successful compilation as proof of browser callbacks, Keychain/Credential Manager, file dialogs, screen-reader support or offline lifecycle behavior.

Before a staff pilot, qualify an approved disposable project with real Google sign-in, membership denial/revocation, private covers, offline leases, token refresh, concurrent edits and each desktop's secure storage/file dialogs. Before a production release, also reconcile real source data/recipients, select residency and recovery targets, perform a database **and separate cover-object** restore drill into an isolated environment, verify counts/identities/cover references and representative file digests, and record observed costs. Retain the prior signed client and its matching trusted lease key for rollback. Database migrations must be assessed for backward compatibility; restoring a database is not a client-update rollback and can lose subsequent catalog edits. Never roll back to a compromised key or claim the unsigned build archives satisfy these gates.
