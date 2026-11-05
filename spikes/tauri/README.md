# Tauri comparison

See the [repository setup and wrappers](../../README.md) and [evidence/limitations](../RESULTS.md).

`npm run dev` is browser-only; `npm run tauri dev` enables the native runtime. Native file dialogs and cache commands are disabled in browser mode. The Rust key-store adapter currently supports macOS/iOS/Windows targets; Android fails closed until an adapter is implemented and verified. File-provider URIs and mobile save/share require additional implementation.
