# Prints the subject of a PFX code-signing certificate, which an MSIX signed
# with it must declare as its publisher.
#
#   powershell -File script/windows/certificate-subject.ps1 path\to\certificate.pfx
#
# The password is read from WINDOWS_CERTIFICATE_PASSWORD so it never appears
# on a command line or inside a generated command string.
param([Parameter(Mandatory = $true)][string]$Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
    (Resolve-Path -LiteralPath $Path).Path,
    $env:WINDOWS_CERTIFICATE_PASSWORD,
    [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
try {
    if (-not $certificate.HasPrivateKey) { throw 'The certificate has no private key to sign with.' }
    if ($certificate.NotAfter -lt (Get-Date)) { throw "The certificate expired on $($certificate.NotAfter)." }
    $codeSigning = '1.3.6.1.5.5.7.3.3'
    $usages = @($certificate.Extensions | Where-Object { $_ -is [Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } |
        ForEach-Object { $_.EnhancedKeyUsages } | ForEach-Object { $_.Value })
    if ($usages -notcontains $codeSigning) { throw 'The certificate is not valid for code signing.' }
    [Console]::Out.Write($certificate.Subject)
} finally {
    $certificate.Dispose()
}
