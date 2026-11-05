param([switch]$ExerciseRegistration)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'MSIX checks require Windows.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = Split-Path $PSScriptRoot -Parent
$package = Join-Path $root '.cache\desktop\bookalog-windows-unsigned.msix'
$identity = 'com.bookalog.catalog'
$publisher = 'CN=Bookalog Catalog Development'
$protocol = 'com.bookalog.catalog'
$originalHash = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash
$archive = [IO.Compression.ZipFile]::OpenRead($package)
try {
    $entry = $archive.GetEntry('AppxManifest.xml')
    if ($null -eq $entry) { throw 'MSIX manifest is missing.' }
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $stream = $entry.Open()
    $reader = [Xml.XmlReader]::Create($stream, $settings)
    try {
        $manifest = New-Object Xml.XmlDocument
        $manifest.XmlResolver = $null
        $manifest.Load($reader)
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
    $namespaces = New-Object Xml.XmlNamespaceManager($manifest.NameTable)
    $namespaces.AddNamespace('p', 'http://schemas.microsoft.com/appx/manifest/foundation/windows10')
    $namespaces.AddNamespace('uap', 'http://schemas.microsoft.com/appx/manifest/uap/windows10')
    $packageIdentity = $manifest.SelectSingleNode('/p:Package/p:Identity', $namespaces)
    if ($null -eq $packageIdentity -or $packageIdentity.Name -cne $identity -or
        $packageIdentity.Publisher -cne $publisher -or $packageIdentity.ProcessorArchitecture -ne 'x64') {
        throw 'MSIX identity, development publisher or architecture is incorrect.'
    }
    $applications = @($manifest.SelectNodes('/p:Package/p:Applications/p:Application', $namespaces))
    if ($applications.Count -ne 1 -or $applications[0].Executable -cne 'bookalog_catalog.exe') {
        throw 'MSIX must activate exactly the catalog executable.'
    }
    $protocols = @($manifest.SelectNodes('//uap:Extension[@Category="windows.protocol"]/uap:Protocol', $namespaces))
    if ($protocols.Count -ne 1 -or $protocols[0].Name -cne $protocol) {
        throw 'MSIX must register exactly the catalog callback protocol.'
    }
    foreach ($file in @('bookalog_catalog.exe', 'flutter_windows.dll', 'data/icudtl.dat')) {
        $entry = $archive.GetEntry($file)
        if ($null -eq $entry -or $entry.Length -eq 0) { throw "MSIX is missing $file." }
    }
    if ($null -ne $archive.GetEntry('AppxSignature.p7x')) {
        throw 'The build-check artifact must remain unsigned.'
    }
    $baseVersion = [version]$packageIdentity.Version
} finally {
    $archive.Dispose()
}
Write-Host 'Unsigned MSIX identity, executable, runtime and callback declaration verified.'
if (-not $ExerciseRegistration) { exit 0 }

if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    throw 'Registration tests may change certificate trust and run only on ephemeral GitHub-hosted runners.'
}
if (@(Get-AppxPackage -AllUsers -Name $identity).Count -ne 0 -or
    (Test-Path "Registry::HKEY_CLASSES_ROOT\$protocol")) {
    throw 'Refusing to replace an existing catalog installation or protocol registration.'
}
$signTool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" |
    Sort-Object FullName -Descending | Select-Object -First 1
if ($null -eq $signTool) { throw 'The Windows SDK signing tool is required for the isolated installation test.' }

$temporary = Join-Path $env:RUNNER_TEMP ("bookalog-msix-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
$certificate = $null
$installedExecutable = $null
$installationAttempted = $false
$cleanupErrors = New-Object 'System.Collections.Generic.List[string]'

function Stop-TestApplication {
    if ($null -eq $script:installedExecutable) { return }
    foreach ($process in [Diagnostics.Process]::GetProcessesByName('bookalog_catalog')) {
        try {
            if ($process.MainModule.FileName -eq $script:installedExecutable) {
                Stop-Process -Id $process.Id -Force
                if (-not $process.WaitForExit(30000)) { throw 'The test application did not exit.' }
            }
        } finally { $process.Dispose() }
    }
}

function Sign-TestPackage([string]$path) {
    & $script:signTool.FullName sign /fd SHA256 /s My /sha1 $script:certificate.Thumbprint $path
    if ($LASTEXITCODE -ne 0) { throw 'Signing the disposable test copy failed.' }
}

function Cleanup([scriptblock]$action) {
    try { & $action } catch {
        $script:cleanupErrors.Add($_.Exception.Message)
        Write-Warning $_.Exception.Message
    }
}

try {
    $certificate = New-SelfSignedCertificate -Type Custom -Subject $publisher `
        -FriendlyName 'Bookalog ephemeral CI installation test' -KeyUsage DigitalSignature `
        -KeyExportPolicy NonExportable -HashAlgorithm SHA256 -KeyLength 2048 `
        -NotAfter (Get-Date).AddHours(1) -CertStoreLocation 'Cert:\CurrentUser\My' `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    $publicCertificate = Join-Path $temporary 'test.cer'
    Export-Certificate -Cert $certificate -FilePath $publicCertificate | Out-Null
    Import-Certificate -FilePath $publicCertificate -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
    $testPackage = Join-Path $temporary 'test.msix'
    Copy-Item -LiteralPath $package -Destination $testPackage
    Sign-TestPackage $testPackage
    $installationAttempted = $true
    Add-AppxPackage -Path $testPackage
    $installed = @(Get-AppxPackage -Name $identity)
    if ($installed.Count -ne 1 -or [version]$installed[0].Version -ne $baseVersion) {
        throw 'MSIX installation did not register the expected version.'
    }
    $family = $installed[0].PackageFamilyName
    $installedExecutable = Join-Path $installed[0].InstallLocation 'bookalog_catalog.exe'

    Start-Process ($protocol + '://login-callback/?error=access_denied')
    $deadline = (Get-Date).AddSeconds(30)
    $activated = $false
    do {
        foreach ($process in [Diagnostics.Process]::GetProcessesByName('bookalog_catalog')) {
            try {
                if ($process.MainModule.FileName -eq $installedExecutable -and $process.MainWindowHandle -ne [IntPtr]::Zero) {
                    $activated = $true
                }
            } finally { $process.Dispose() }
        }
        if (-not $activated) { Start-Sleep -Milliseconds 250 }
    } while (-not $activated -and (Get-Date) -lt $deadline)
    if (-not $activated) { throw 'The installed callback protocol did not open the packaged application window.' }
    Stop-TestApplication

    $state = Join-Path $env:LOCALAPPDATA "Packages\$family\LocalState"
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    $sentinel = Join-Path $state 'bookalog-ci-upgrade.txt'
    $token = [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($sentinel, $token)
    if ($baseVersion.Revision -ge 65535) { throw 'The package revision has no room for an upgrade fixture.' }
    $upgradeVersion = '{0}.{1}.{2}.{3}' -f $baseVersion.Major, $baseVersion.Minor, $baseVersion.Build, ($baseVersion.Revision + 1)
    Push-Location (Join-Path $root 'app')
    try {
        & dart run msix:create --build-windows false --sign-msix false --install-certificate false `
            --version $upgradeVersion --output-path $temporary --output-name upgrade
        if ($LASTEXITCODE -ne 0) { throw 'Creating the upgrade fixture failed.' }
    } finally { Pop-Location }
    $upgrade = Join-Path $temporary 'upgrade.msix'
    Sign-TestPackage $upgrade
    Add-AppxPackage -Path $upgrade
    $updated = @(Get-AppxPackage -Name $identity)
    if ($updated.Count -ne 1 -or [version]$updated[0].Version -ne [version]$upgradeVersion -or
        $updated[0].PackageFamilyName -ne $family -or [IO.File]::ReadAllText($sentinel) -cne $token) {
        throw 'The package upgrade did not retain identity and local application state.'
    }
    $installedExecutable = Join-Path $updated[0].InstallLocation 'bookalog_catalog.exe'
    Write-Host 'MSIX install, OS callback activation and state-preserving upgrade passed.'
} finally {
    Cleanup { Stop-TestApplication }
    if ($installationAttempted) {
        Cleanup {
            Get-AppxPackage -Name $identity | ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName }
            if (@(Get-AppxPackage -Name $identity).Count -ne 0) { throw 'The test package was not removed.' }
        }
    }
    if ($null -ne $certificate) {
        Cleanup {
            $trusted = "Cert:\LocalMachine\TrustedPeople\$($certificate.Thumbprint)"
            if (Test-Path $trusted) { Remove-Item -LiteralPath $trusted -Force }
            if (Test-Path $trusted) { throw 'The disposable trust certificate was not removed.' }
        }
        Cleanup {
            $personal = "Cert:\CurrentUser\My\$($certificate.Thumbprint)"
            if (Test-Path $personal) { Remove-Item -LiteralPath $personal -DeleteKey -Force }
            if (Test-Path $personal) { throw 'The disposable private signing key was not removed.' }
        }
    }
    Cleanup { Remove-Item -LiteralPath $temporary -Recurse -Force }
    Cleanup {
        if ((Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash -cne $originalHash) {
            throw 'The original unsigned artifact was modified.'
        }
    }
    if ($cleanupErrors.Count -gt 0) { throw ('Installation test cleanup failed: ' + ($cleanupErrors -join '; ')) }
}
Write-Host 'Test package, certificate trust, private key and temporary files removed; original artifact remains unsigned.'
