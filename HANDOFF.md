# ENG-2521 handoff: deliver SFTP/PGP keys from GitHub Secrets in the production deploys

**For:** the agent implementing this in `StaffScheduleCare/ssc-web-app`, and DevOps (section 6).
**Branch:** `bugfix/ENG-2521-PurgeRepoPrivateKeys` in `ssc-web-app`. It already removes the keys from the repo and ships a file-based delivery (`D:\SSC-Shared\Keys` + `Install-SscKeys.ps1`). This work **replaces that delivery** with GitHub Secrets.
**Prototype:** `Alexey-Stp/keys-poc` (this repo). Results are in `REPORT.md`; the scripts in `scripts/` are the reference implementation.

---

## 1. What the prototype proved, and what is new in production

Proven on GitHub (Windows runners, Windows PowerShell 5.1); see REPORT.md for run links:

| Fact | Evidence |
|---|---|
| Base64 secrets arrive byte-exact (text, CRLF, binary, zip). | 23/23 SHA256 matches |
| **Raw-text secrets lose their trailing newline.** | Round 1: 14/23 mismatches, 1-2 bytes short each |
| Environment secrets reach only jobs with `environment: <name>`; a job without one reads an empty string. | negative `no-environment` |
| `environment: <name>` silently **creates** a missing environment. | `globex` created by the negative run |
| Referencing `toJSON(secrets)` makes GitHub hold the run (`action_required`, 0 jobs). | runs 39794705946, 39794909046 |
| A tenant-keys matrix with `environment:` before a single job without one works; `fail-fast: false` keeps the other tenants running. | `deploy-to-all` |
| Keys outside the app folder survive `robocopy /MIR` of the app folder. | robocopy check |
| `Set-Content`/`Out-File` corrupt keys (BOM, CRLF). | negative `broken-writer` |

**New in production and NOT tested by the prototype.** Test these first (section 5):
- self-hosted runners chosen by `GH_RUNNER`: the tenant-keys job and the deploy job must run on the **same machine**;
- the app reading keys from `CONFIG_DIR\Keys` through AppConfig `KeysPath`;
- the IIS app-pool identity's read access to `CONFIG_DIR\Keys`;
- the guard against deleting key files placed by hand (`keys-manifest.json`);
- environment protection rules (reviewers) on `prod:*` environments, which would also gate the tenant-keys jobs.

---

## 2. Target design

### Secrets (every value is base64 of the exact file bytes, no exceptions)

| Secret | Scope | File written | Notes |
|---|---|---|---|
| `KEY_SFTP_PRIVATE` | repository | `SSC_SFTPPrivateKey.openSSH` | |
| `KEY_PGP_PRIVATE` | repository | `PGPPrivateKey.pgp` | |
| `KEY_PGP_PUBLIC` | repository | `PGPPublicKey.pgp` | |
| `KEY_PGP_PASSPHRASE` | repository | `PGPPassPhrase.txt` | `KeyStore.ReadPassPhrase` trims trailing CR/LF itself |
| `TENANT_KEYS` | environment `prod:<tenant>` | the zip's files | base64 of a zip with plain file names only; same name as a shared key = replaces it for that tenant |

These are the four files the app uses today (`docs/key-management.md`). The prototype's `.p8`/`.p12` were test-only; the APNS key is ENG-2712.

**Repository variable `TENANTS_WITH_CUSTOM_KEYS`:** a JSON array of exact environment names, e.g. `["prod:carecorp1"]`. It may be `[]` but must be set.
- Tenant listed: `TENANT_KEYS` is mandatory, and the deploy fails without it.
- Tenant not listed: shared keys only; any `TENANT_KEYS` the environment has is ignored.

### Layout on each server

```
<CONFIG_DIR>\Keys\                 final keys; the only folder the app reads (AppConfig KeysPath)
<CONFIG_DIR>\Keys\shared\          written by the deploy from KEY_*; removed after the merge
<CONFIG_DIR>\Keys\tenant\          written from TENANT_KEYS; removed after the merge
<CONFIG_DIR>\keys-manifest.json    written by each merge: names, source, SHA256; no key material
<APP_DIR>\                         robocopy /MIR / Clear-PublishOutput target; contains NO keys
```

- `KeyStore.ResolveKeyDirectory` uses an absolute `KeysPath` as-is (`KeyStoreTests.AbsoluteKeysPath_IsUsedAsIs`).
- The deploy stamps `KeysPath = <CONFIG_DIR>\Keys` into the deployed AppConfig.xml, the same way it stamps `ServerSideVersion`. So nobody edits AppConfig by hand.
- Old copies in `APP_DIR\XML\Keys` disappear by themselves: the build output has no `XML\Keys`, so the next `robocopy /mir` (deploy-all) or `Clear-PublishOutput` (single site) removes them.

### Order (the rule the prototype enforced)

**Single site** (`production-deployment.yml`, one job with `environment:`):
1. Check secrets.
2. Stage tenant keys if listed. Both happen before IIS stops, so a bad secret fails while the site still runs.
3. Build, stop IIS, publish.
4. Write shared keys, merge, check.
5. Start IIS.

**All sites** (`production-deployment-all.yml`):
1. `list_environments` (+ which tenants have their own keys).
2. `tenant_keys` matrix: one job per listed tenant, `environment: <tenant>`, `runs-on: <its GH_RUNNER>`. It writes `CONFIG_DIR\Keys\tenant\` on that machine.
3. `build_and_deploy`, one per runner, no environment. Per tenant, it checks the tenant keys are staged before stopping the pool. Then it migrates, mirrors, overlays config, writes shared keys, merges, stamps `KeysPath` and the versions, and starts the pool.

If any `tenant_keys` job fails, `build_and_deploy` doesn't run at all (proven behaviour; safe, nothing is touched).

---

## 3. Implementation steps (ssc-web-app)

Follow the rules at the top of `.github/scripts/deployment.ps1`: pure ASCII, PS 5.1 syntax, check `$LASTEXITCODE` by hand, Actions-aware `::error::` output.

### 3.1 `deployment.ps1`: replace the shared-folder key code

**Remove:**
- `$SharedKeysDir`
- `Assert-SharedKeys`
- `Copy-TenantKeys`
- the `Copy-TenantKeys` call in `Copy-TenantConfigOverlay`

**Add** (adapted from `keys-poc/scripts/write-shared-keys.ps1`, `write-tenant-keys.ps1`, `merge-keys.ps1`):

```powershell
# --- SFTP/PGP keys from GitHub Secrets (ENG-2521, docs/key-management.md) ------
#
# Shared keys: repository secrets KEY_*, base64 of the exact file bytes.
# Tenant keys: environment secret TENANT_KEYS (base64 zip), only for tenants listed in the
# repository variable TENANTS_WITH_CUSTOM_KEYS (JSON array of environment names).
# Final keys go to <CONFIG_DIR>\Keys (outside APP_DIR); the app reads them via AppConfig KeysPath.
# Values are never printed. Decoded key bytes are NOT masked by GitHub, so never echo file contents.

$SharedKeyFiles = [ordered]@{
    KEY_SFTP_PRIVATE   = 'SSC_SFTPPrivateKey.openSSH'
    KEY_PGP_PRIVATE    = 'PGPPrivateKey.pgp'
    KEY_PGP_PUBLIC     = 'PGPPublicKey.pgp'
    KEY_PGP_PASSPHRASE = 'PGPPassPhrase.txt'
}
$KeysManifestName = 'keys-manifest.json'

# True when $TenantName is listed in TENANTS_WITH_CUSTOM_KEYS. An unset/empty variable is an
# error, so a missing variable can't silently turn into "no tenant keys".
function Test-CustomKeyTenant {
    param(
        [Parameter(Mandatory = $true)][string] $TenantName,
        [AllowEmptyString()][string] $TenantsWithCustomKeys = $env:TENANTS_WITH_CUSTOM_KEYS
    )
    if ([string]::IsNullOrWhiteSpace($TenantsWithCustomKeys)) {
        throw "TENANTS_WITH_CUSTOM_KEYS is not set - set the repository variable (a JSON array, may be [])"
    }
    # ForEach-Object unwraps the array PS 5.1 ConvertFrom-Json emits as one object
    $listed = @($TenantsWithCustomKeys | ConvertFrom-Json | ForEach-Object { $_ })
    return ($listed -contains $TenantName)
}

# Fail before anything is stopped when a shared key secret is missing or not base64.
function Assert-SharedKeySecrets {
    foreach ($var in $SharedKeyFiles.Keys) {
        $value = [Environment]::GetEnvironmentVariable($var)
        if ([string]::IsNullOrEmpty($value)) {
            $message = "$var is empty - set the repository secret and map it in the step env (docs/key-management.md)"
            Write-Host "::error::$message"; throw $message
        }
        try { [void][Convert]::FromBase64String($value) }
        catch { $message = "$var is not valid base64"; Write-Host "::error::$message"; throw $message }
    }
}

# KEY_* -> <ConfigDir>\Keys\shared\ (one path for every key: base64 -> WriteAllBytes).
function Write-SharedKeys {
    param([Parameter(Mandatory = $true)][string] $ConfigDir)
    $sharedDir = Join-Path $ConfigDir 'Keys\shared'
    if (Test-Path -LiteralPath $sharedDir) { Remove-Item -LiteralPath $sharedDir -Recurse -Force }
    New-Item -ItemType Directory -Path $sharedDir -Force | Out-Null
    foreach ($var in $SharedKeyFiles.Keys) {
        $bytes = [Convert]::FromBase64String([Environment]::GetEnvironmentVariable($var))
        [System.IO.File]::WriteAllBytes((Join-Path $sharedDir $SharedKeyFiles[$var]), $bytes)
    }
    Write-Host "Wrote $($SharedKeyFiles.Count) shared key file(s) to $sharedDir"
}

# TENANT_KEYS -> <ConfigDir>\Keys\tenant\ when the tenant is listed; returns $true if written.
# Not listed: removes a stale tenant\ folder and returns $false.
function Write-TenantKeys {
    param(
        [Parameter(Mandatory = $true)][string] $ConfigDir,
        [Parameter(Mandatory = $true)][string] $TenantName
    )
    $tenantDir = Join-Path $ConfigDir 'Keys\tenant'
    if (-not (Test-CustomKeyTenant -TenantName $TenantName)) {
        if (Test-Path -LiteralPath $tenantDir) { Remove-Item -LiteralPath $tenantDir -Recurse -Force }
        Write-Host "Tenant '$TenantName' is not in TENANTS_WITH_CUSTOM_KEYS - shared keys only"
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($env:TENANT_KEYS)) {
        $message = "TENANT_KEYS is empty for '$TenantName' - it is listed in TENANTS_WITH_CUSTOM_KEYS, so its environment needs a TENANT_KEYS secret and the job needs 'environment: $TenantName'"
        Write-Host "::error::$message"; throw $message
    }
    try { $bytes = [Convert]::FromBase64String($env:TENANT_KEYS) }
    catch { $message = "TENANT_KEYS for '$TenantName' is not valid base64"; Write-Host "::error::$message"; throw $message }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $tenantDir) { Remove-Item -LiteralPath $tenantDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tenantDir -Force | Out-Null
    $archive = New-Object System.IO.Compression.ZipArchive((New-Object System.IO.MemoryStream(, $bytes)), [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        $invalid = [System.IO.Path]::GetInvalidFileNameChars()
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -ne $entry.Name -or $entry.Name -eq '' -or $entry.Name.IndexOfAny($invalid) -ge 0) {
                throw "TENANT_KEYS for '$TenantName' contains '$($entry.FullName)' - only plain file names are allowed"
            }
        }
        foreach ($entry in $archive.Entries) {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $tenantDir $entry.Name), $true)
        }
        Write-Host "Wrote $($archive.Entries.Count) tenant key file(s) for '$TenantName': $(($archive.Entries | ForEach-Object Name) -join ', ')"
    }
    finally { $archive.Dispose() }
    return $true
}

# deploy-all: before stopping a listed tenant's pool, its keys must already be staged by tenant_keys.
function Assert-TenantKeysStaged {
    param(
        [Parameter(Mandatory = $true)][string] $ConfigDir,
        [Parameter(Mandatory = $true)][string] $TenantName
    )
    if (-not (Test-CustomKeyTenant -TenantName $TenantName)) { return }
    $tenantDir = Join-Path $ConfigDir 'Keys\tenant'
    if (-not (Test-Path -LiteralPath $tenantDir) -or @(Get-ChildItem -LiteralPath $tenantDir -File).Count -eq 0) {
        throw "Tenant keys for '$TenantName' are not staged in $tenantDir - did its tenant_keys job run on this machine?"
    }
}

# Build <ConfigDir>\Keys from shared\ + tenant\ (tenant replaces same name), then remove both.
# Validates everything before deleting anything. Refuses to delete key files that no deploy
# wrote (not in keys-manifest.json), e.g. files placed by hand under the old file-based setup.
# Never deletes the Keys folder itself, so its ACL (app-pool read access) is kept.
function Merge-TenantKeys {
    param(
        [Parameter(Mandatory = $true)][string] $ConfigDir,
        [Parameter(Mandatory = $true)][string] $TenantName
    )
    $keysDir = Join-Path $ConfigDir 'Keys'
    $sharedDir = Join-Path $keysDir 'shared'
    $tenantDir = Join-Path $keysDir 'tenant'
    $manifestPath = Join-Path $ConfigDir $KeysManifestName
    $useTenant = Test-CustomKeyTenant -TenantName $TenantName

    foreach ($d in @($sharedDir, $tenantDir)) {
        if ((Test-Path -LiteralPath $d) -and @(Get-ChildItem -LiteralPath $d -Directory).Count -gt 0) {
            throw "$d contains subfolders - key files must be directly in it"
        }
    }
    $shared = @(if (Test-Path -LiteralPath $sharedDir) { Get-ChildItem -LiteralPath $sharedDir -File })
    if ($shared.Count -ne $SharedKeyFiles.Count) { throw "Expected $($SharedKeyFiles.Count) shared keys in $sharedDir, found $($shared.Count)" }
    $tenantFiles = @()
    if ($useTenant) {
        $tenantFiles = @(if (Test-Path -LiteralPath $tenantDir) { Get-ChildItem -LiteralPath $tenantDir -File })
        if ($tenantFiles.Count -eq 0) { throw "Tenant '$TenantName' is listed in TENANTS_WITH_CUSTOM_KEYS but $tenantDir is empty" }
    }

    $known = @()
    if (Test-Path -LiteralPath $manifestPath) {
        $known = @((Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json).files | ForEach-Object { $_.name })
    }
    $unmanaged = @(Get-ChildItem -LiteralPath $keysDir -File | Where-Object { $known -notcontains $_.Name } | ForEach-Object Name)
    if ($unmanaged.Count -gt 0) {
        throw "$keysDir has key files no deploy wrote: $($unmanaged -join ', '). Move them into the tenant's TENANT_KEYS (docs/key-management.md) and delete them here, then redeploy."
    }

    Get-ChildItem -LiteralPath $keysDir -File | Remove-Item -Force
    $entries = [ordered]@{}
    foreach ($f in $shared) { Copy-Item -LiteralPath $f.FullName -Destination $keysDir; $entries[$f.Name] = 'shared' }
    foreach ($f in $tenantFiles) {
        $source = if ($entries.Contains($f.Name)) { 'tenant (replaces shared)' } else { 'tenant' }
        Copy-Item -LiteralPath $f.FullName -Destination $keysDir -Force
        $entries[$f.Name] = $source
    }
    $now = [DateTime]::UtcNow
    $files = foreach ($name in $entries.Keys) {
        $path = Join-Path $keysDir $name
        [System.IO.File]::SetLastWriteTimeUtc($path, $now)
        Write-Host ("  {0,-30} <- {1}" -f $name, $entries[$name])
        [ordered]@{ name = $name; source = $entries[$name]; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    }
    $manifest = [ordered]@{ tenant = $TenantName; mergedUtc = $now.ToString('o'); runId = $env:GITHUB_RUN_ID; files = @($files) }
    [System.IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $manifest -Depth 5))

    Remove-Item -LiteralPath $sharedDir -Recurse -Force
    if (Test-Path -LiteralPath $tenantDir) { Remove-Item -LiteralPath $tenantDir -Recurse -Force }
    Write-Host "Merged $($entries.Count) key file(s) into $keysDir ($($shared.Count) shared, $($tenantFiles.Count) tenant)"
}

# Give the tenant's app pool read access to the keys folder (idempotent; adds, never removes).
function Grant-KeysReadAccess {
    param(
        [Parameter(Mandatory = $true)][string] $KeysDir,
        [Parameter(Mandatory = $true)][string] $AppPool
    )
    icacls $KeysDir /grant "IIS AppPool\${AppPool}:(OI)(CI)RX" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed for $KeysDir (exit $LASTEXITCODE)" }
}

# Stamp KeysPath (absolute) into an AppConfig.xml, creating the key if absent. Same shape as Set-ServerSideVersion.
function Set-AppConfigKeysPath {
    param(
        [Parameter(Mandatory = $true)][string] $AppConfigPath,
        [Parameter(Mandatory = $true)][string] $KeysDir
    )
    [xml]$appConfig = Get-Content $AppConfigPath -Raw
    $root = $appConfig.SelectSingleNode("/Root")
    if ($null -eq $root) { throw "Root element not found in $AppConfigPath" }
    $node = $root.SelectSingleNode("add[@key='KeysPath']")
    if ($null -eq $node) {
        $node = $appConfig.CreateElement("add")
        $node.SetAttribute("key", "KeysPath")
        $root.AppendChild($node) | Out-Null
    }
    $node.SetAttribute("value", [System.IO.Path]::GetFullPath($KeysDir))
    $appConfig.Save($AppConfigPath)
    Write-Host "Stamped KeysPath = $KeysDir into $AppConfigPath"
}

# Shared keys + merge + ACL. Call after the app is deployed and BEFORE the app pool starts.
# Tenant keys must already be in Keys\tenant\ (Write-TenantKeys, or the tenant_keys job).
function Install-TenantKeys {
    param(
        [Parameter(Mandatory = $true)][string] $ConfigDir,
        [Parameter(Mandatory = $true)][string] $TenantName,
        [Parameter(Mandatory = $true)][string] $AppPool
    )
    $keysDir = Join-Path $ConfigDir 'Keys'
    New-Item -ItemType Directory -Path $keysDir -Force | Out-Null
    Write-SharedKeys -ConfigDir $ConfigDir
    Merge-TenantKeys -ConfigDir $ConfigDir -TenantName $TenantName
    Grant-KeysReadAccess -KeysDir $keysDir -AppPool $AppPool
}
```

**Optional post-install check**, ported from `keys-poc/scripts/verify-keys.ps1`. It needs no expected hashes:
- every `$SharedKeyFiles` name is in `CONFIG_DIR\Keys`, with no BOM in text files;
- every name in the manifest exists and its SHA256 matches;
- no file with a key extension (`.openssh .pgp .gpg .asc .p8 .p12 .pfx .pem .ppk .key`) anywhere under `APP_DIR`;
- no `shared\` or `tenant\` left.

Run it before the pool starts.

### 3.2 `deployment.ps1`: call sites

`Invoke-RunnerDeployment` (deploy-all), replacing the first check:
```powershell
    # Before any tenant's app pool is stopped.
    Assert-SharedKeySecrets
    [void](Test-CustomKeyTenant -TenantName '-')   # fails now if TENANTS_WITH_CUSTOM_KEYS is unset
```

`Invoke-TenantMigrateAndDeploy`, inside the `try`:
```powershell
        # Before the pool stops: a listed tenant whose keys weren't staged is skipped untouched.
        Assert-TenantKeysStaged -ConfigDir $configDir -TenantName $envName

        Stop-TenantAppPool -AppPool $appPool
        # ... migrations, Deploy-TenantBuild, Copy-TenantConfigOverlay (no longer copies keys) ...

        $appConfigDest = Join-Path (Join-Path $appDir 'XML\Configuration') 'AppConfig.xml'
        Install-TenantKeys -ConfigDir $configDir -TenantName $envName -AppPool $appPool
        Set-AppConfigKeysPath -AppConfigPath $appConfigDest -KeysDir (Join-Path $configDir 'Keys')
        Set-ServerSideVersion -AppConfigPath $appConfigDest -Version $Version
        # ... Set-AppVersion ...
        Start-TenantAppPool -AppPool $appPool
```
- `Assert-TenantKeysStaged` must run **before** `Stop-TenantAppPool`.
- `Install-TenantKeys` must run **before** `Start-TenantAppPool`.
- On failure the existing `catch` leaves the pool stopped and records the tenant, as for any other deploy error.

### 3.3 `production-deployment.yml` (single site; its job already has `environment:`)

In the `copy configs` step (before `stop IIS`), add the key env and calls:
```yaml
      - name: copy configs
        env:
          KEY_SFTP_PRIVATE:   ${{ secrets.KEY_SFTP_PRIVATE }}
          KEY_PGP_PRIVATE:    ${{ secrets.KEY_PGP_PRIVATE }}
          KEY_PGP_PUBLIC:     ${{ secrets.KEY_PGP_PUBLIC }}
          KEY_PGP_PASSPHRASE: ${{ secrets.KEY_PGP_PASSPHRASE }}
          TENANT_KEYS:        ${{ secrets.TENANT_KEYS }}
          TENANTS_WITH_CUSTOM_KEYS: ${{ vars.TENANTS_WITH_CUSTOM_KEYS }}
          TENANT_NAME:        ${{ inputs.environment }}
        run: |
          . ".\.github\scripts\deployment.ps1"
          $version = Resolve-DeployVersion
          Copy-BuildConfig -ConfigDir "${{ vars.CONFIG_DIR }}"
          Assert-SharedKeySecrets
          [void](Write-TenantKeys -ConfigDir "${{ vars.CONFIG_DIR }}" -TenantName $env:TENANT_NAME)
          $appConfig = ".\src\legacy\LegacyServer\BBBSilverlight.Web\XML\Configuration\AppConfig.xml"
          Set-AppConfigKeysPath -AppConfigPath $appConfig -KeysDir "${{ vars.CONFIG_DIR }}\Keys"
          Set-ServerSideVersion -AppConfigPath $appConfig -Version $version
          # ... Set-AppVersion as today ...
```
Replace the `copy tenant keys` step:
```yaml
      - name: install keys
        env:
          KEY_SFTP_PRIVATE:   ${{ secrets.KEY_SFTP_PRIVATE }}
          KEY_PGP_PRIVATE:    ${{ secrets.KEY_PGP_PRIVATE }}
          KEY_PGP_PUBLIC:     ${{ secrets.KEY_PGP_PUBLIC }}
          KEY_PGP_PASSPHRASE: ${{ secrets.KEY_PGP_PASSPHRASE }}
          TENANTS_WITH_CUSTOM_KEYS: ${{ vars.TENANTS_WITH_CUSTOM_KEYS }}
          TENANT_NAME:        ${{ inputs.environment }}
        run: |
          . ".\.github\scripts\deployment.ps1"
          Install-TenantKeys -ConfigDir "${{ vars.CONFIG_DIR }}" -TenantName $env:TENANT_NAME -AppPool "${{ vars.APP_POOL }}"
        timeout-minutes: 2
```
- `start IIS` keeps `if: always()`, as today. If `install keys` fails, the merge validated before deleting anything, so `CONFIG_DIR\Keys` still holds the previous set.
- On the very first deploy, though, the folder is empty, so a failure leaves a site with no keys. Check the logs and redeploy.

### 3.4 `production-deployment-all.yml`

**`list_environments`:** add the `key_tenants` output. This job is `pwsh`, so it can use pwsh syntax.

```yaml
    outputs:
      environments: ${{ steps.list.outputs.environments }}
      runners: ${{ steps.list.outputs.runners }}
      key_tenants: ${{ steps.list.outputs.key_tenants }}
    ...
      - id: list
        shell: pwsh
        env:
          GH_TOKEN: ${{ steps.token.outputs.token }}
          TENANTS_WITH_CUSTOM_KEYS: ${{ vars.TENANTS_WITH_CUSTOM_KEYS }}
        run: |
          # ... existing code that builds $envs and $pairs ...

          # Tenants with their own keys: [{environment, runner}] for the tenant_keys matrix.
          if ([string]::IsNullOrWhiteSpace($env:TENANTS_WITH_CUSTOM_KEYS)) {
            Write-Host "::error::Repository variable TENANTS_WITH_CUSTOM_KEYS is not set (JSON array, may be [])"; exit 1
          }
          $listed = @($env:TENANTS_WITH_CUSTOM_KEYS | ConvertFrom-Json)
          $missing = @($listed | Where-Object { $_ -like 'prod:*' -and $envs -notcontains $_ })
          if ($missing.Count -gt 0) {
            Write-Host "::error::TENANTS_WITH_CUSTOM_KEYS lists environments that don't exist: $($missing -join ', ')"; exit 1
          }
          $keyTenants = @($pairs | Where-Object { $listed -contains $_.environment } |
            ForEach-Object { [ordered]@{ environment = $_.environment; runner = $_.runner } })
          "key_tenants=$(ConvertTo-Json -InputObject $keyTenants -Compress -AsArray)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
```

**New job `tenant_keys`**, between the two existing jobs:
```yaml
  # Tenant-only keys. Environment secrets reach only jobs that name the environment, and a job
  # names one environment, so this is a matrix. Runs on the tenant's own runner, so the keys
  # land on the disk build_and_deploy reads. Any failure stops build_and_deploy for every site.
  tenant_keys:
    needs: list_environments
    if: needs.list_environments.outputs.key_tenants != '[]'
    strategy:
      fail-fast: false
      matrix:
        include: ${{ fromJson(needs.list_environments.outputs.key_tenants) }}
    name: tenant keys (${{ matrix.environment }})
    runs-on: ${{ matrix.runner }}
    environment: ${{ matrix.environment }}
    timeout-minutes: 5
    defaults:
      run:
        shell: powershell
    steps:
      - uses: actions/checkout@v7.0.0
        with:
          ref: main
          persist-credentials: false
          sparse-checkout: .github/scripts
      - name: stage tenant keys
        env:
          TENANT_KEYS: ${{ secrets.TENANT_KEYS }}
          TENANTS_WITH_CUSTOM_KEYS: ${{ vars.TENANTS_WITH_CUSTOM_KEYS }}
          TENANT_NAME: ${{ matrix.environment }}
        run: |
          . "${{ github.workspace }}\.github\scripts\deployment.ps1"
          [void](Write-TenantKeys -ConfigDir "${{ vars.CONFIG_DIR }}" -TenantName $env:TENANT_NAME)
```

**`build_and_deploy`:**
```yaml
  build_and_deploy:
    needs: [list_environments, tenant_keys]
    # tenant_keys is skipped when no tenant has its own keys; a plain needs would skip this job too
    if: ${{ !cancelled() && needs.list_environments.result == 'success' && (needs.tenant_keys.result == 'success' || needs.tenant_keys.result == 'skipped') }}
    ...
      - name: migrate and deploy all tenants on this runner
        env:
          ENVIRONMENTS: ${{ needs.list_environments.outputs.environments }}
          KEY_SFTP_PRIVATE:   ${{ secrets.KEY_SFTP_PRIVATE }}
          KEY_PGP_PRIVATE:    ${{ secrets.KEY_PGP_PRIVATE }}
          KEY_PGP_PUBLIC:     ${{ secrets.KEY_PGP_PUBLIC }}
          KEY_PGP_PASSPHRASE: ${{ secrets.KEY_PGP_PASSPHRASE }}
          TENANTS_WITH_CUSTOM_KEYS: ${{ vars.TENANTS_WITH_CUSTOM_KEYS }}
```

**Requirements:**
- Each `GH_RUNNER` label must map to exactly one machine. If two runners share a label, `tenant_keys` can land on a different machine than `build_and_deploy`; `Assert-TenantKeysStaged` then fails that tenant (safe, but a failed deploy).
- If `prod:*` environments have required reviewers, every `tenant_keys` job waits for approval.

### 3.5 `qa-deployment.yml` (decision needed: see section 8)

Its deploy job has no `environment:`, so it can't read `TENANT_KEYS`. The default (same as today's QA behaviour: shared keys only):
- in `copy configs`, replace `Assert-SharedKeys` with `Assert-SharedKeySecrets` (add the `KEY_*` env);
- replace `copy tenant keys` with `Install-TenantKeys` (add the `KEY_*` and `TENANTS_WITH_CUSTOM_KEYS` env);
- stamp `KeysPath` like 3.3.

QA site names aren't in the list, so `Merge-TenantKeys` uses shared keys only.

### 3.6 Other files

- **`.github/scripts/Install-SscKeys.ps1`:** turn it into `Export-SscKeys.ps1`. Keep `-FromGitRef` / `-Source`, add `-OutDir`, and have it write the four files plus a `<file>.b64` for each, ready for `gh secret set`. Remove its copy to `$SharedKeysDir` and to tenants.
- **`.github/scripts/Pack-TenantKeys.ps1`:** copy from `keys-poc/scripts/pack-tenant-keys.ps1` (folder → zip → base64 on stdout, no trailing newline, rejects subfolders).
- **`docs/key-management.md`:** rewrite "How keys reach a tenant" and the DevOps sections to match this design and section 6. Flip the `KeysPath` guidance: it is now set by the deploy and points to `CONFIG_DIR\Keys`. Remove `D:\SSC-Shared\Keys` and `SSC_KEYS_DIR`.
- **`KeyStore.cs`:** update the class comment ("filled by the deploy from the server's shared keys folder" → `CONFIG_DIR\Keys` via `KeysPath`). No code change.
- **`pr-build-check.yml` `secret_scan`:** unchanged. Optionally add gitleaks as in `keys-poc/.github/workflows/gitleaks.yml`; it caught a renamed key in the prototype.

### 3.7 How to test before merging

1. **Local, PS 5.1:** dot-source `deployment.ps1` and run `Install-TenantKeys` against a temp `CONFIG_DIR`, with `KEY_*`, `TENANT_KEYS` and the list set from throwaway keys (`keys-poc/scripts/generate-test-keys.sh`). Check:
   - every SHA256 matches;
   - a hand-placed file in `Keys\` makes `Merge-TenantKeys` throw;
   - a listed tenant without `TENANT_KEYS` throws;
   - an unlisted tenant gets shared keys only;
   - an unset list throws.
2. **QA:** one `qa-deployment.yml` run. Then check that `CONFIG_DIR\Keys` holds the 4 files, `APP_DIR\XML\Keys` is gone, and `KeysPath` is in the deployed AppConfig.xml. In the app, run a payroll export or an SFTP connection test.
3. **One production site:** `production-deployment.yml` for one unlisted tenant, then one listed tenant.
4. **All sites:** `production-deployment-all.yml`.

---

## 4. Pitfalls found in the prototype (do not repeat)

| Pitfall | Rule |
|---|---|
| Raw-text secret loses its final newline | Every secret is base64 of the file bytes |
| `toJSON(secrets)` blocks the run (`action_required`) | Name each secret explicitly in a step `env:` |
| Piping a value from Windows PowerShell 5.1 into `gh` re-encodes it | `gh secret set NAME < file.b64` from Git Bash or cmd |
| `> file` in Windows PowerShell 5.1 writes UTF-16 | Redirect `Pack-TenantKeys.ps1` output from Git Bash or cmd, never PowerShell |
| `Set-Content` / `Out-File` add a BOM and CRLF | `[IO.File]::WriteAllBytes` only |
| Decoded key bytes are not masked in logs (only the base64 secret is) | Never print file contents; log names only |
| `environment: <typo>` creates an empty environment | The list check (`Test-CustomKeyTenant` + "listed but empty" error) catches it |
| A matrix from an empty JSON array fails | `if: ... != '[]'` on `tenant_keys`, plus the `!cancelled()` condition on `build_and_deploy` |
| PS 5.1 `ConvertFrom-Json` returns a JSON array as one object | `| ForEach-Object { $_ }` before `-contains` |
| A copy that keeps old timestamps hides ordering bugs | `Merge-TenantKeys` stamps the merge time |
| A wildcard artifact path kept the folder structure | Not relevant in prod (no artifacts); never upload keys as artifacts |
| The jobs API sometimes reports a finished job as `in_progress` | Don't script against job status; use the run conclusion |

---

## 5. Acceptance criteria

- No key file in the repository, in any build output, or under any `APP_DIR`. Old `APP_DIR\XML\Keys` copies are gone after the first deploy.
- Every tenant's `CONFIG_DIR\Keys` holds the 4 shared files. Listed tenants also have their own files, and a file with a shared name has the tenant's content.
- `keys-manifest.json` hashes match the files.
- Deployed AppConfig.xml has `KeysPath = <CONFIG_DIR>\Keys`. The app finds its keys: no `KeyStore: key file not found` errors in the logs, and payroll export, SFTP import and PGP decrypt work.
- App pools start only after `Install-TenantKeys`. A missing or invalid secret fails before any pool stops: shared keys in `copy configs` / `Invoke-RunnerDeployment`, tenant keys in `tenant_keys` / `Write-TenantKeys`.
- Hand-placed files in `CONFIG_DIR\Keys` are never deleted silently.
- `D:\SSC-Shared\Keys`, `SSC_KEYS_DIR`, `Assert-SharedKeys` and `Copy-TenantKeys` are gone from code and docs.

---

## 6. DevOps runbook

Use Git Bash (or cmd) for every `gh` command, never a PowerShell pipe. `gh` must be logged in with admin on `StaffScheduleCare/ssc-web-app`. Keep every value under 32,000 bytes: `wc -c file.b64`. Delete `.b64` and exported key files when done.

### 6.1 Before the first deploy with this change

1. **Get the current key files** from the secure store, or export them from git:
   ```bash
   powershell -File .github/scripts/Export-SscKeys.ps1 -FromGitRef 5d9545e0e -OutDir C:/Temp/ssc-keys
   ```
   That gives `SSC_SFTPPrivateKey.openSSH`, `PGPPrivateKey.pgp`, `PGPPublicKey.pgp`, `PGPPassPhrase.txt`, plus a `.b64` of each.
2. **Create the shared secrets:**
   ```bash
   cd C:/Temp/ssc-keys
   R=StaffScheduleCare/ssc-web-app
   gh secret set KEY_SFTP_PRIVATE   --repo $R < SSC_SFTPPrivateKey.openSSH.b64
   gh secret set KEY_PGP_PRIVATE    --repo $R < PGPPrivateKey.pgp.b64
   gh secret set KEY_PGP_PUBLIC     --repo $R < PGPPublicKey.pgp.b64
   gh secret set KEY_PGP_PASSPHRASE --repo $R < PGPPassPhrase.txt.b64
   gh variable set TENANTS_WITH_CUSTOM_KEYS --repo $R --body '[]'
   ```
   (No `.b64` yet? `base64 -w0 <file> > <file>.b64`.)
3. **Inventory every server's `CONFIG_DIR\Keys`.** Any tenant whose folder has files (its own client keys from the old setup) becomes a custom-keys tenant: follow 6.2 for it. **Then delete those files on the server.** The first new deploy refuses to run while unknown files are there, and names them.
4. **Check runners:** each `GH_RUNNER` label must be on exactly one machine (Settings → Actions → Runners).
5. **Optional:** if `prod:*` environments have required reviewers, decide whether the `tenant_keys` jobs should need approval too.

### 6.2 Add a tenant with its own keys

1. Put the tenant's files in an empty folder, with the exact names the app uses (the report SFTP settings' *Key File Name* / *Public Key File Name*). A file named like a shared key (e.g. `SSC_SFTPPrivateKey.openSSH`) replaces the shared one for this tenant only.
2. Pack and upload the folder:
   ```bash
   powershell -File .github/scripts/Pack-TenantKeys.ps1 -Folder C:/Temp/carecorp1-keys > carecorp1.b64
   wc -c carecorp1.b64          # must be < 32000
   gh secret set TENANT_KEYS --repo $R --env "prod:carecorp1" < carecorp1.b64
   ```
3. **Only after step 2**, add the tenant to the list (exact environment name, keeping the others):
   ```bash
   gh variable set TENANTS_WITH_CUSTOM_KEYS --repo $R --body '["prod:carecorp1"]'
   ```
   A listed tenant without its secret fails both deploy workflows, and in deploy-all that stops every site.
4. Deploy that site (`Production Deployment`, environment `prod:carecorp1`).
5. Check `CONFIG_DIR\keys-manifest.json`: its files show `tenant` / `tenant (replaces shared)`.

### 6.3 Rotate a shared key

1. Encode the new file to base64 and set the same secret again (6.1 step 2, one line).
2. For a new PGP key, rotate `KEY_PGP_PRIVATE`, `KEY_PGP_PUBLIC` and `KEY_PGP_PASSPHRASE` together, and send partners the new public key.
3. Run `Production Deployment — All Sites`. Each site uses the new key from its deploy on.

### 6.4 Rotate or change a tenant key

1. Repack the tenant's **complete** folder: `TENANT_KEYS` replaces the tenant's whole set, so include unchanged files.
2. Set `TENANT_KEYS` for that environment again (6.2 step 2).
3. Deploy that site.

### 6.5 Remove a tenant's own keys

1. Remove the tenant from `TENANTS_WITH_CUSTOM_KEYS`.
2. Delete its `TENANT_KEYS`: `gh secret delete TENANT_KEYS --repo $R --env "prod:x"`.
3. Deploy the site. It goes back to shared keys only; its old files are removed because the manifest lists them.

### 6.6 After rollout

- Delete `D:\SSC-Shared\Keys` on every server, and the `SSC_KEYS_DIR` machine variable where set.
- After ENG-2712, purge the old key files from git history as `docs/key-management.md` describes.

### 6.7 If a deploy fails on keys

| Message | Fix |
|---|---|
| `KEY_... is empty` | Set the repository secret (6.1) |
| `... is not valid base64` | Re-create the `.b64` from Git Bash/cmd and set it again |
| `TENANTS_WITH_CUSTOM_KEYS is not set` | `gh variable set TENANTS_WITH_CUSTOM_KEYS --body '[]'` |
| `TENANT_KEYS is empty for 'prod:x'` | Set the tenant's secret (6.2), or remove it from the list |
| `TENANTS_WITH_CUSTOM_KEYS lists environments that don't exist` | Fix the typo in the list |
| `Tenant keys for 'prod:x' are not staged` | The `tenant_keys` job ran on another machine; fix the runner labels (6.1 step 4) |
| `has key files no deploy wrote` | Move those files into the tenant's `TENANT_KEYS` (6.2) and delete them from the server |

---

## 7. Prototype reference (`Alexey-Stp/keys-poc`)

| Production piece | Prototype file |
|---|---|
| `Write-SharedKeys` | `scripts/write-shared-keys.ps1` |
| `Write-TenantKeys` + list rule | `scripts/write-tenant-keys.ps1` (`-TenantsWithCustomKeys`) |
| `Merge-TenantKeys` | `scripts/merge-keys.ps1` (the manifest guard is new here) |
| Per-tenant order (mirror, keys, merge, robocopy check, start pool) | `scripts/deploy-tenant.ps1` |
| Post-deploy checks | `scripts/verify-keys.ps1` |
| `Pack-TenantKeys.ps1` | `scripts/pack-tenant-keys.ps1` |
| Secret upload with size check | `scripts/set-secrets.sh` |
| tenant-keys matrix → deploy-all | `.github/workflows/deploy-to-all.yml` |
| single job with environment | `.github/workflows/deploy-to-tenant.yml` |
| negative checks | `.github/workflows/negative.yml` |

---

## 8. Open decisions (ask the team; don't guess)

1. **QA keys.** QA has no `environment:` today, so it gets the production shared keys, as it does now from `D:\SSC-Shared\Keys`. If QA should use test keys instead, give its deploy job `environment: qa-<site>` and add same-named `KEY_*` secrets to those environments. GitHub's docs say an environment secret takes precedence over a repository secret with the same name; confirm that on one QA run.
2. **Approval gates.** Should `tenant_keys` jobs require the same reviewers as the `prod:*` environments?
3. **ACL hardening.** `Grant-KeysReadAccess` only adds read access for the app pool. Removing broader inherited access from `CONFIG_DIR\Keys` must keep the runner's service account able to write. Decide per server.
