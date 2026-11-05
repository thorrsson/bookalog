# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

An internal publishing-house team of approximately 2-10 administrators, catalog editors, and read-only viewers.

## Product Purpose

Manage released and upcoming books and editions; discover records through coordinated gallery, table, and release-calendar views.

## Operating Context

The existing catalog is spread across spreadsheets and other systems. The application must support CSV/Excel and ONIX exchange. Real source schemas and samples have not yet been supplied.

## Capabilities and Constraints

- macOS and Windows first; future iOS and Android aim for full functionality, including import/export.
- Fewer than 5,000 book/edition records.
- Google Workspace identity plus approved application membership and server-enforced roles.
- Online editing only. Encrypted offline browsing expires 24 hours after successful online membership verification.
- Private book covers, concurrent-edit protection, and change history.
- Hosting target below $50/month; signing/distribution costs are separate.
- **Selected implementation stack:** Flutter for macOS/Windows first and eventual iOS/Android; Supabase Auth, PostgreSQL, PostgREST, and private Storage.
- Selection is based on the working local two-client/two-backend matrix, Flutter's maintained cross-platform identity/file/secure-storage ecosystem, and Supabase's lower operational footprint for a small internal catalog.
- This is a user-authorized implementation decision, not a claim that hosted provider setup, signed platform behavior, Windows/mobile runtime qualification, recovery, or the $50/month target has been proven. Those remain release gates; do not provision paid resources without explicit authorization.
- Tauri and Google Cloud remain documented comparison spikes, not maintained production targets.
- The production Flutter/Supabase application is now under `app/` and `supabase/`; it remains an early implementation, not a complete catalog product.

## Evidence on Hand

Issue #1 and the approved session plan. Generated fixtures are explicitly synthetic. Publisher schema, real files, approved ONIX profiles, and brand assets remain outstanding.

## Product Principles

- Preserve identifiers, date precision, and source-data provenance.
- Never silently overwrite concurrent changes or drop unsupported exchange data.
- Keep authorization independent of the client interface.
- Preserve functionality across device sizes without pretending identical layouts fit every platform.

## Accessibility & Inclusion

Keyboard access, visible focus, screen-reader semantics, scalable text, and readable Unicode metadata are required.
