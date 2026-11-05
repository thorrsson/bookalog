#!/bin/bash
# Helpers shared by the macOS and Windows release scripts.
# Sourced, never executed directly. Callers run from the repository root.

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# The version lives in app/pubspec.yaml, where Flutter also reads it.
app_version() {
    ruby script/app-version.rb
}

# Hosted configuration compiled into the app. The publishable key and offline
# lease public key are public values; no secret belongs in a Dart define.
dart_defines() {
    local name
    for name in SUPABASE_URL SUPABASE_PUBLISHABLE_KEY OFFLINE_LEASE_PUBLIC_KEY; do
        if [[ -n "${!name:-}" ]]; then
            printf -- '--dart-define=%s=%s\n' "${name}" "${!name}"
        fi
    done
}

# Release builds without a project can only show the configuration screen, so
# BOOKALOG_REQUIRE_CONFIGURATION=1 (the release workflow sets it) refuses them.
check_configuration() {
    if [[ -n "${SUPABASE_URL:-}" && -n "${SUPABASE_PUBLISHABLE_KEY:-}" ]]; then
        [[ "${SUPABASE_URL}" == https://* ]] || die "SUPABASE_URL must be an https:// URL."
        if [[ -z "${OFFLINE_LEASE_PUBLIC_KEY:-}" ]]; then
            warn "OFFLINE_LEASE_PUBLIC_KEY is not set, so offline browsing is disabled in this build."
        fi
        return
    fi
    if [[ "${BOOKALOG_REQUIRE_CONFIGURATION:-0}" == "1" ]]; then
        die "SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY must both be set for a release build."
    fi
    warn "SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are not both set; the app will start unconfigured."
}

# Builds the Flutter app for one desktop target with the configured defines.
flutter_release_build() {
    local target="${1}" define
    local defines=()
    while IFS= read -r define; do defines+=("${define}"); done < <(dart_defines)
    (cd app && "${FLUTTER_BIN:-flutter}" build "${target}" --release ${defines[@]+"${defines[@]}"})
}
