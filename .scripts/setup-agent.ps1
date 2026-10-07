
# ============================================================
# Bitwarden SSH Agent + Windows OpenSSH Setup
# Run this script in PowerShell AS ADMINISTRATOR
#
# Prerequisite:
#   Bitwarden Desktop -> Settings -> SSH Agent -> Enable SSH agent
# ============================================================

$ErrorActionPreference = "Stop"

$sshDir      = "$HOME\.ssh"
$pubkeysDir  = "$sshDir\pubkeys"
$configPath  = "$sshDir\config"
$testHost    = "sun-git"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Bitwarden SSH Agent Setup" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# 1. Check Administrator privileges
# ------------------------------------------------------------

Write-Host "[1/7] Checking Administrator privileges..." -ForegroundColor Cyan

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)

$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "ERROR: Run PowerShell as Administrator." -ForegroundColor Red
    exit 1
}

Write-Host "OK: Running as Administrator." -ForegroundColor Green

# ------------------------------------------------------------
# 2. Disable Windows native ssh-agent
# ------------------------------------------------------------

Write-Host ""
Write-Host "[2/7] Disabling native Windows ssh-agent..." -ForegroundColor Cyan

try {
    Stop-Service ssh-agent -Force -ErrorAction SilentlyContinue
    Set-Service ssh-agent -StartupType Disabled

    Write-Host "OK: Native Windows ssh-agent disabled." -ForegroundColor Green
}
catch {
    Write-Host "WARNING: Could not modify ssh-agent service." -ForegroundColor Yellow
    Write-Host $_.Exception.Message
}


# ------------------------------------------------------------
# 3. Create SSH directories
# ------------------------------------------------------------

Write-Host ""
Write-Host "[3/7] Creating SSH directories..." -ForegroundColor Cyan

New-Item `
    -ItemType Directory `
    -Force `
    -Path $sshDir |
    Out-Null

New-Item `
    -ItemType Directory `
    -Force `
    -Path $pubkeysDir |
    Out-Null

if (-not (Test-Path $configPath)) {
    New-Item `
        -ItemType File `
        -Path $configPath |
        Out-Null
}

Write-Host "OK: $sshDir" -ForegroundColor Green
Write-Host "OK: $pubkeysDir" -ForegroundColor Green


# ------------------------------------------------------------
# 4. Check Bitwarden SSH agent
# ------------------------------------------------------------

Write-Host ""
Write-Host "[4/7] Checking Bitwarden SSH agent..." -ForegroundColor Cyan

$agentOutput = & ssh-add -L 2>&1
$agentExitCode = $LASTEXITCODE

if ($agentExitCode -ne 0) {

    Write-Host ""
    Write-Host "ERROR: Bitwarden SSH agent is not available." -ForegroundColor Red
    Write-Host ""
    Write-Host "Make sure:" -ForegroundColor Yellow
    Write-Host "  1. Bitwarden Desktop is running"
    Write-Host "  2. Bitwarden is unlocked"
    Write-Host "  3. Settings -> SSH Agent -> Enable SSH agent is enabled"
    Write-Host ""
    Write-Host "ssh-add returned:" -ForegroundColor Yellow
    Write-Host $agentOutput
    Write-Host ""
    exit 1
}

$keys = @(
    $agentOutput |
    Where-Object {
        $_ -match '^(ssh-|ecdsa-)'
    }
)

if ($keys.Count -eq 0) {

    Write-Host ""
    Write-Host "ERROR: Bitwarden SSH agent is reachable but exposes no keys." -ForegroundColor Red
    Write-Host ""
    Write-Host "Add your SSH key to Bitwarden and enable it for the SSH agent."
    exit 1
}

Write-Host "OK: Bitwarden SSH agent is working." -ForegroundColor Green
Write-Host "Found $($keys.Count) SSH key(s)." -ForegroundColor Green


# ------------------------------------------------------------
# 5. Recreate public-key files
# ------------------------------------------------------------

Write-Host ""
Write-Host "[5/7] Regenerating public-key files..." -ForegroundColor Cyan

# Delete only generated .pub files
Get-ChildItem `
    -Path $pubkeysDir `
    -Filter "*.pub" `
    -File `
    -ErrorAction SilentlyContinue |
    Remove-Item -Force


$keyNumber = 0

foreach ($line in $keys) {

    $line = $line.Trim()

    if (
        $line -match
        '^(ssh-\S+|ecdsa-\S+)\s+\S+(?:\s+(.+))?$'
    ) {

        $keyNumber++

        $comment = $Matches[2]

        if ([string]::IsNullOrWhiteSpace($comment)) {
            $comment = "key-$keyNumber"
        }

        # Convert comment to safe Windows filename
        $filename = $comment `
            -replace '[\\/:*?"<>|]', '_' `
            -replace '\s+$', ''

        if ([string]::IsNullOrWhiteSpace($filename)) {
            $filename = "key-$keyNumber"
        }

        $path = Join-Path `
            $pubkeysDir `
            "$filename.pub"

        # ASCII is appropriate for OpenSSH public-key files.
        Set-Content `
            -Path $path `
            -Value $line `
            -Encoding ascii `
            -NoNewline

        # OpenSSH accepts final newline as well
        Add-Content `
            -Path $path `
            -Value "" `
            -Encoding ascii

        Write-Host ""
        Write-Host "Created:" -ForegroundColor Green
        Write-Host "  $path"

        # Validate the public key
        & ssh-keygen -lf $path *> $null

        if ($LASTEXITCODE -eq 0) {

            Write-Host "  VALID OpenSSH public key" -ForegroundColor Green

        }
        else {

            Write-Host "  INVALID PUBLIC KEY" -ForegroundColor Red
            Write-Host "  Removing malformed file."

            Remove-Item $path -Force
        }
    }
    else {

        Write-Host ""
        Write-Host "WARNING: Skipping malformed agent output:" -ForegroundColor Yellow
        Write-Host $line
    }
}


# ------------------------------------------------------------
# 6. Validate everything
# ------------------------------------------------------------

Write-Host ""
Write-Host "[6/7] Validating generated keys..." -ForegroundColor Cyan
Write-Host ""

$generatedKeys = @(
    Get-ChildItem `
        -Path $pubkeysDir `
        -Filter "*.pub" `
        -File `
        -ErrorAction SilentlyContinue
)

if ($generatedKeys.Count -eq 0) {

    Write-Host "ERROR: No valid public keys were generated." -ForegroundColor Red
    exit 1
}

foreach ($keyFile in $generatedKeys) {

    Write-Host $keyFile.Name -ForegroundColor Yellow

    & ssh-keygen -lf $keyFile.FullName

    if ($LASTEXITCODE -ne 0) {

        Write-Host "INVALID: $($keyFile.FullName)" -ForegroundColor Red
    }

    Write-Host ""
}

# ------------------------------------------------------------
# 7. Install npiperelay
# ------------------------------------------------------------


$toolsDir = "C:\tools"
$zipPath  = "$toolsDir\npiperelay.zip"

New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null

Invoke-WebRequest `
    -Uri "https://github.com/jstarks/npiperelay/releases/latest/download/npiperelay_windows_amd64.zip" `
    -OutFile $zipPath

Expand-Archive `
    -Path $zipPath `
    -DestinationPath $toolsDir `
    -Force

Remove-Item $zipPath -Force

if (Test-Path "$toolsDir\npiperelay.exe") {
    Write-Host "npiperelay installed successfully:" -ForegroundColor Green
    Write-Host "  $toolsDir\npiperelay.exe"
} else {
    Write-Host "ERROR: npiperelay.exe was not found after extraction." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------
# 8. Show agent state + test SSH config
# ------------------------------------------------------------

Write-Host ""
Write-Host "[7/7] Final SSH agent status..." -ForegroundColor Cyan
Write-Host ""

& ssh-add -l

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " Setup complete" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green

Write-Host ""
Write-Host "Public keys:" -ForegroundColor Cyan
Write-Host "  $pubkeysDir"

Write-Host ""
Write-Host "SSH config:" -ForegroundColor Cyan
Write-Host "  $configPath"

Write-Host ""
Write-Host "Your SSH config can reference a Bitwarden key like:" -ForegroundColor Cyan
Write-Host ""

Write-Host @"
Host sun-git
    HostName <your-git-server>
    User git
    IdentityFile C:/Users/$env:USERNAME/.ssh/pubkeys/sun-git.pub
    IdentitiesOnly yes
"@

Write-Host ""
Write-Host "Testing configured SSH host: $testHost" -ForegroundColor Cyan
Write-Host ""

& ssh -T $testHost

Write-Host ""
Write-Host "If authentication succeeds, Git should now work:" -ForegroundColor Green
Write-Host ""
Write-Host "  git pull"
Write-Host ""

