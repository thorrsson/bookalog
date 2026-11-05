# Bookalog

An internal publishing catalog application. **The selected implementation stack is Flutter + Supabase.** Tauri and Google Cloud remain comparison spikes; the production app is early work and is not feature-complete.

The approved direction is desktop-first (macOS/Windows), with eventual full-featured iOS/Android clients. See [product context](PRODUCT.md), [comparison evidence](spikes/RESULTS.md), and [operation contracts](spikes/contracts/operations.json).

## Selected production implementation

- `app/` contains the Flutter/Supabase catalog: Google OAuth, approved memberships, coordinated gallery/table/release-calendar views, shared identity/date filters and sorting, metadata and relationship editing, additional editions, private covers, member administration, encrypted offline browsing, and reviewed core-metadata CSV/XLSX and provisional ONIX 3.0 exchange.
- `supabase/migrations/` contains the provisional normalized work/edition schema, contributor/category relationships, RLS, revision-checked metadata and relationship operations, audit snapshots, and private cover bucket policy. Apply all migrations in filename order.
- App and SQL-policy behavior are checked by `bash script/test-app.sh` and `bash script/test-supabase.sh`. `bash script/test-supabase-services.sh` separately exercises real local Supabase Auth/PostgREST/Storage over HTTPS and a catalog-data/cover recovery drill. Google OAuth callbacks, hosted services/recovery/cost, and signed native behavior still require external qualification.
- Offline metadata browsing requires a server-signed, 24-hour membership lease and a pinned verification key. Snapshots are AES-GCM encrypted with keys in OS-protected storage; covers are not cached. Without a configured key or valid saved lease, the app is online-only. See [offline setup and limitations](app/README.md#offline-access).
- Relationships are explicitly edition-scoped, with ordered contributor credits and exact category identities; no inheritance is assumed. Administrators can assign roles to registered Auth accounts; invites remain operator-managed.
- **Catalog tools > File exchange** provides online CSV/XLSX column mapping, preview, atomic confirmed imports, duplicate/conflict detection, retry-safe request IDs, and durable reports. Spreadsheet exports contain ten core fields only, not relationships/covers or a complete backup. The provisional ONIX 3.0 core profile adds strict reference-tag XML import/export with source provenance and explicit unsupported-data failures. It is schema-checked, not recipient-qualified. See [exchange limits](app/README.md#reviewed-csvxlsx-exchange) and [ONIX compatibility](app/README.md#provisional-onix-30-core-profile).
- `.github/workflows/ci.yml` defines app/database/local-provider checks and unsigned macOS/Windows build artifacts using pinned actions. `bash script/build-desktop.sh macos` builds and archives locally; `windows` requires a Windows host. Hosted CI has passed the Linux checks and produced both native archives. These unconfigured artifacts are build checks, not signed installers or qualified releases.

Run the app with your own disposable Supabase URL and publishable key:

```sh
cd app
flutter run -d macos \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

Configure Google OAuth at Supabase and allow `com.bookalog.catalog://login-callback/` in Auth redirects. Bootstrap the initial administrator through an operator-only SQL connection. Never place service-role keys, database passwords, or migration credentials in the client. See [app setup](app/README.md).

## What the comparison spikes demonstrated

- Flutter and Tauri/React clients browse/search the same 5,000 synthetic editions.
- Both client slices preview/export seven-column CSV/XLSX projections and an illustrative ONIX 3.0 projection. They implement authenticated cache encryption with a 24-hour test expiry.
- Native Dart and Rust adapters connect to both backend access paths, load all 5,000 records, enforce membership/roles, edit titles with expected revisions, and retain drafts on conflicts.
- Real disposable PostgreSQL and PostgREST exercise membership, role enforcement, optimistic editing, immutable audit records, revocation, and pagination.
- A Google Cloud-oriented HTTP gateway uses Firebase Admin token verification and the same database operations. Its HTTP/database boundary is exercised with an injected verifier in tests; **live Google authentication is not yet verified**.
- The native exchange implementations are checked by independent Node readers against every exported row/product, not just by reading their own output.

Packaged data and automated test records are synthetic. The native connection forms accept manually supplied test access tokens; neither performs Google sign-in or issues a server-verified offline lease. Hosted cloud connectivity remains unqualified. Do not load sensitive data into these prototypes.

## Prerequisites

The comparison was checked with Node 26.12.1, Ruby 3.2, Rust 1.99.1, Flutter 3.47.9/Dart 3.13.7, Xcode, and a running Docker engine. `zip`, `openssl`, and Bash are used by the wrappers. macOS/Windows/mobile builds require the respective native SDKs.

Use NVM and `nvm use` where configured, or a matching Node installation. Use an isolated npm cache for each session:

```sh
npm ci --cache "$PWD/.cache/npm"
npm --prefix spikes/tauri ci --cache "$PWD/.cache/npm-tauri"
ruby script/fixtures.rb
cd spikes/flutter
flutter pub get
```

Generated datasets and build outputs are ignored. Generate fixtures before opening either client or invoking a direct native build.

## Run the comparison clients

From the repository root:

```sh
# Browser-only synthetic table; native controls are intentionally disabled.
npm --prefix spikes/tauri run dev

# Native Tauri app, including file dialogs and OS key-store adapter.
npm --prefix spikes/tauri run tauri dev

# Flutter native app.
cd spikes/flutter
flutter run -d macos
```

The browser entry point explicitly disables native IPC even when previewed inside another Tauri-based host. Native mode is selected only by the Tauri build/dev commands.

In a native app, use **Test backend connection** with a disposable environment's API URL and test token. Supabase URLs include `/rest/v1`; local PostgREST and the gateway use their server root. Hosted Supabase also needs its publishable key, never a service-role key. Tokens stay in memory, are not cached or logged, and are discarded on disconnect. An editor or administrator can select a title to edit it; a viewer can only read.

Connected records are deliberately excluded from the synthetic cache and file tools. On conflict, copy the preserved draft before canceling and reloading. The adapters reject redirects, incomplete pages, duplicate page records, and revoked membership; HTTP is restricted to loopback addresses. The comparison has explicit safety limits of 10,000 records, 16 MiB per HTTP response, and a one-minute pagination budget plus the current request's 20-second timeout. These are prototype guards, not agreed production exchange limits.

Flutter's secure-storage capability requires an appropriate Apple development profile for signed macOS execution. Configure signing locally in Xcode; no developer team or credentials are committed. The source also compiles without signing, but **unsigned compilation does not verify Keychain behavior**:

```sh
xcodebuild -workspace spikes/flutter/macos/Runner.xcworkspace \
  -scheme Runner -configuration Debug \
  -derivedDataPath spikes/flutter/build/unsigned CODE_SIGNING_ALLOWED=NO build
```

## Validation

Always use the wrappers. For the selected application:

```sh
bash script/test-app.sh
bash script/test-supabase.sh
bash script/test-supabase-services.sh
```

The service wrapper uses the pinned Supabase CLI 3.0.0 from `npm ci`, Ruby/OpenSSL, Node, Flutter and a running Docker engine. Set `FLUTTER_BIN`/`PUB_CACHE` when using an isolated SDK/cache. It creates a unique disposable project/network, applies all application migrations, selects unused loopback ports, and trusts a short-lived local certificate authority only in its test processes. It neither links to a hosted project nor changes production HTTPS verification. Password-based synthetic Auth accounts exercise real provider tokens; this is not Google sign-in.

The checks cover approved/unapproved accounts, administrator membership changes, token refresh/logout, revision conflicts, relationships/import retries, private cover upload/read/delete, and the production lease handler with real Auth and PostgREST responses. The handler runs under Node, not the hosted Edge runtime. The actual Flutter Supabase SDK and `CatalogRepository` then exercise these provider workflows through the app adapter, including explicit failure on an RLS-filtered cover deletion. A quiescent data-only dump of all ten catalog tables is restored after simulated data loss, with exact row comparisons and a separate cover-byte restore/digest check. Existing Auth users and schema remain in place; this is **not** replacement-project or disaster recovery. Temporary credentials/backups, containers, volumes and the private network are removed on normal completion or test failure; Docker images remain cached. See [the precise recovery boundary](app/README.md#local-provider-and-recovery-checks).

For the retained comparison spikes:

```sh
bash script/test.sh
bash script/test-flutter.sh
bash script/test-tauri.sh
bash script/test-matrix.sh
```

`script/test.sh` creates isolated PostgreSQL/PostgREST containers, generates disposable test credentials, binds random localhost ports, and removes its containers. It does not connect to an existing database or use cloud accounts. Run the wrappers sequentially because each regenerates shared fixture files.

`FLUTTER_BIN` can select an isolated Flutter SDK; `PUB_CACHE` can select its package cache. The Flutter wrapper runs analysis and unit/widget tests; the Tauri wrapper runs TypeScript/Vite checks and Rust tests. Neither substitutes for real-device native integration testing.

`script/test-matrix.sh` requires Dart and Cargo; set `DART_BIN` when Dart is not on PATH. It runs both actual client-language adapters against both disposable backend paths and checks their XLSX/ONIX exports with independent readers. It removes its temporary exports and containers. Gateway test identities exist only inside this isolated test harness; the production server has no test-token bypass.

## Exchange comparison profile

CSV/XLSX contain `id`, `work_id`, `title`, `format`, `isbn13`, `publication_status`, and `release_date`. XLSX accepts exactly one sheet with those headers and text cells, preserving ISBNs and partial dates without spreadsheet coercion. Exports write strings, not formulas. Formulas, external links, embedded objects, DTD/entity declarations, oversized grids, files above 8 MiB, archives with more than 100 entries, and declared/actual ZIP expansion above 32 MiB are rejected. The Dart adapter supplies a default styles relationship when this optional XLSX part is absent, accommodating its workbook library without modifying the source file.

Illustrative ONIX accepts only the bounded 3.0 demonstration profile. Its export contains record references, ISBN/proprietary identifiers, titles, and paperback/ebook product forms, with a fixed synthetic publisher/date header. It intentionally omits contributors, categories, publication dates/status, covers, and other commercial metadata. It is **not a complete, lossless, schema-certified, or recipient-compatible ONIX feed**.

File preview never commits catalog changes. Native picker/save/share paths are wired, but signed Apple runtime and physical-device file-provider behavior still need qualification.

## Backend experiments

`spikes/backends/catalog.sql` is a deliberately narrow migration for a **disposable** database. It stores a read projection of each edition while retaining work relationships and identifier uniqueness; it is not the final normalized publishing schema. Membership administration is intentionally operator-only in this slice.

For Supabase, apply the common migration followed by `spikes/supabase/attach.sql` in a disposable project. The local PostgREST test covers the PostgreSQL/JWT boundary, not the hosted Supabase Auth or Storage services. Fetch every page; the default row limit is not a complete catalog.

For the Google Cloud gateway, supply `GOOGLE_CLOUD_PROJECT`, a restricted `DATABASE_URL`, and Application Default Credentials through the environment/secret manager, then run:

```sh
node spikes/google-cloud/server.mjs
```

The database login must be allowed to `SET ROLE catalog_client` and must not be a superuser or catalog-table owner. The production entry point always verifies Firebase ID tokens, including revocation; it has no test-token or anonymous development bypass. It binds to localhost by default; Cloud Run would additionally require `HOST=0.0.0.0` and the platform's `PORT`. No deployment or paid infrastructure is created by these scripts.

The user authorized selecting Flutter + Supabase and beginning implementation. Local comparison evidence supports that choice for this small internal catalog: Flutter offers the broader maintained cross-platform native ecosystem needed for eventual full mobile parity, while Supabase has lower operational overhead than maintaining the Google Cloud gateway stack. The local matrix is evidence of the SQL/PostgREST and client adapters, not proof of hosted OAuth, private object access, native callback behavior, recovery, or cost.

Still open: real source/schema reconciliation; relationship exchange and recipient approval beyond the bounded ONIX core profile; hosted OAuth, Storage, and offline-service verification; signed macOS/Windows and mobile qualification; replacement-project/hosted backup recovery; and observed monthly cost. Production data must not be loaded until these gates are addressed. No cloud project or paid service has been provisioned.
