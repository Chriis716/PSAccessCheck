<#
.SYNOPSIS
  Tests access to UNC paths using multiple VA service accounts from a list.
  Adds: progress, live status, timeouts, and non-destructive "permission type" insights.

.DESCRIPTION
  For each account and each UNC path:
    1) Maps the ROOT share (\\server\share) with net use (required for SMB auth)
    2) Tests the EXACT target path you provided (including subfolders) for:
         - CanReach   (traverse / access folder object; no enumeration)
         - CanList    (enumerate contents)
         - CanReadFile (read 1 line from 1 file if one is found/accessible; optional)
         - CanReadAcl (read folder ACL metadata; optional, often blocked)
    3) Cleans up the mapping
  Includes per-test timeout to avoid hanging and a progress bar + status lines.

.INPUTS
  accounts.txt (one account per line, e.g. VA\OITXXXIA)
  shares.txt   (one UNC path per line, e.g. \\server\share\folder)

.OUTPUTS
  Console table and optional CSV export.
#>

param(
  [string]$AccountsFile = "$PSScriptRoot\accounts.txt",
  [string]$SharesFile   = "$PSScriptRoot\shares.txt",

  # Timeout for each "net use" mapping attempt (seconds)
  [int]$NetUseTimeoutSec = 20,

  # Read test settings (non-destructive)
  [switch]$EnableReadFileTest,   # off by default
  [switch]$ReadFileRecurse,      # off by default

  # Write test settings (creates + deletes a temp file)
  [switch]$EnableWriteTest,      # off by default (opt-in)
  [string]$WriteTestFileNamePrefix = "perm_test",

  # CSV export
  [switch]$ExportCsv,
  [string]$CsvPath = "$PSScriptRoot\ShareAccessResults.csv"
)

function Write-Status {
  param([string]$Message)
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$ts] $Message"
}

function Get-FreeDriveLetter {
  $used = (Get-PSDrive -PSProvider FileSystem).Name
  foreach ($letter in 'Z','Y','X','W','V','U','T','S','R','Q','P','O','N','M','L','K') {
    if ($used -notcontains $letter) { return $letter }
  }
  throw "No free drive letters available."
}

function Get-RootShareFromUnc {
  param([Parameter(Mandatory)][string]$UncPath)

  if ($UncPath -notmatch '^[\\]{2}[^\\]+\\[^\\]+') { return $null }
  $parts = ($UncPath -split '\\' | Where-Object { $_ -ne '' })
  if ($parts.Count -lt 2) { return $null }
  return "\\$($parts[0])\$($parts[1])"
}

function Invoke-CommandWithTimeout {
  param(
    [Parameter(Mandatory)][string]$CmdLine,
    [Parameter(Mandatory)][int]$TimeoutSec
  )

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "cmd.exe"
  $psi.Arguments = "/c $CmdLine"
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()

  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    try { $p.Kill() } catch {}
    return [pscustomobject]@{ TimedOut=$true; ExitCode=$null; StdOut=""; StdErr="Timed out after $TimeoutSec seconds." }
  }

  [pscustomobject]@{
    TimedOut = $false
    ExitCode = $p.ExitCode
    StdOut   = $p.StandardOutput.ReadToEnd().Trim()
    StdErr   = $p.StandardError.ReadToEnd().Trim()
  }
}

function Test-ShareAccess {
  param(
    [Parameter(Mandatory)][string]$UncPath,
    [Parameter(Mandatory)][pscredential]$Credential,
    [Parameter(Mandatory)][int]$TimeoutSec,
    [Parameter(Mandatory)][bool]$DoReadFileTest,
    [Parameter(Mandatory)][bool]$DoReadFileRecurse,
    [Parameter(Mandatory)][bool]$DoWriteTest,
    [Parameter(Mandatory)][string]$WritePrefix
  )

  $user = $Credential.UserName
  $pass = $Credential.GetNetworkCredential().Password

  $rootShare = Get-RootShareFromUnc -UncPath $UncPath
  if (-not $rootShare) {
    return [pscustomobject]@{
      User=$user; SharePath=$UncPath; RootShare=$null
      CanMap=$false; CanReach=$false; CanList=$false; CanReadFile=$false; CanReadAcl=$false
      CanWrite=$false; CanDelete=$false; PermissionSummary="Invalid UNC path"
      AclHint=$null; Error="Invalid UNC path."
    }
  }

  $drive     = Get-FreeDriveLetter
  $drivePath = "$drive`:"
  $mapped    = $false
  $errMsg    = $null

  $canReach    = $false
  $canList     = $false
  $canReadFile = $false
  $canReadAcl  = $false
  $aclHint     = $null

  $canWrite  = $false
  $canDelete = $false

  $permSummary = "Unknown"

  try {
    Invoke-CommandWithTimeout -CmdLine "net use $drivePath /delete /y" -TimeoutSec 5 | Out-Null

    $mapCmd = "net use $drivePath `"$rootShare`" /user:`"$user`" `"$pass`""
    $mapRes = Invoke-CommandWithTimeout -CmdLine $mapCmd -TimeoutSec $TimeoutSec

    if ($mapRes.TimedOut) {
      $errMsg = $mapRes.StdErr
      $permSummary = "No Access"
    }
    elseif ($mapRes.ExitCode -eq 0) {
      $mapped = $true

      $relative = $UncPath.Substring($rootShare.Length)
      $testPath = Join-Path $drivePath ($relative.TrimStart('\'))

      # 1) Reach (no enumeration)
      try {
        $null = Get-Item -LiteralPath $testPath -ErrorAction Stop
        $canReach = $true
      } catch {
        $errMsg = $_.Exception.Message
      }

      # 2) List (enumeration)
      if ($canReach) {
        try {
          $null = Get-ChildItem -LiteralPath $testPath -ErrorAction Stop
          $canList = $true
        } catch {
          if (-not $errMsg) { $errMsg = $_.Exception.Message }
        }
      }

      # 3) Read file (optional, non-destructive)
      if ($DoReadFileTest -and $canList) {
        try {
          $oneFile =
            if ($DoReadFileRecurse) {
              Get-ChildItem -LiteralPath $testPath -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            } else {
              Get-ChildItem -LiteralPath $testPath -File -ErrorAction SilentlyContinue | Select-Object -First 1
            }

          if ($oneFile) {
            $null = Get-Content -LiteralPath $oneFile.FullName -TotalCount 1 -ErrorAction Stop
            $canReadFile = $true
          }
        } catch {
          # optional
        }
      }

      # 4) ACL read (optional, non-destructive)
      if ($canReach) {
        try {
          $acl = Get-Acl -LiteralPath $testPath -ErrorAction Stop
          $canReadAcl = $true
          $aclHint = ($acl.Access |
            Select-Object -First 5 |
            ForEach-Object { "$($_.IdentityReference): $($_.FileSystemRights) ($($_.AccessControlType))" }) -join "; "
        } catch {
          $canReadAcl = $false
        }
      }

      # 5) Write/Delete test (OPTIONAL, opt-in)
      if ($DoWriteTest -and $canReach) {
        $tmpName = "{0}_{1}.tmp" -f $WritePrefix, ([guid]::NewGuid().ToString("N"))
        $tmpPath = Join-Path $testPath $tmpName

        try {
          # Create (write)
          Set-Content -LiteralPath $tmpPath -Value "perm test" -ErrorAction Stop
          $canWrite = $true

          # Delete (modify)
          Remove-Item -LiteralPath $tmpPath -Force -ErrorAction Stop
          $canDelete = $true
        }
        catch {
          # If create succeeded but delete failed, we don't want to leave litter
          if (Test-Path -LiteralPath $tmpPath) {
            try { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue } catch {}
          }
          if (-not $errMsg) { $errMsg = $_.Exception.Message }
        }
      }

      # Summary label
      $permSummary =
        if (-not $canReach) { "No Access (ACL/Path)" }
        elseif ($DoWriteTest -and $canWrite -and $canDelete) { "Modify Confirmed (Write/Delete)" }
        elseif ($DoWriteTest -and $canWrite -and -not $canDelete) { "Write Confirmed (Delete denied)" }
        elseif ($canList -and $canReadFile) { "Read Confirmed" }
        elseif ($canList) { "List Only" }
        else { "Traverse Only" }
    }
    else {
      $errMsg = ($mapRes.StdOut, $mapRes.StdErr | Where-Object { $_ }) -join " | "
      if (-not $errMsg) { $errMsg = "net use failed with exit code $($mapRes.ExitCode)" }
      $permSummary = "No Access"
    }
  }
  finally {
    Invoke-CommandWithTimeout -CmdLine "net use $drivePath /delete /y" -TimeoutSec 5 | Out-Null
  }

  [pscustomobject]@{
    User              = $user
    SharePath         = $UncPath
    RootShare         = $rootShare
    CanMap            = $mapped
    CanReach          = $canReach
    CanList           = $canList
    CanReadFile       = $canReadFile
    CanReadAcl        = $canReadAcl
    CanWrite          = $canWrite
    CanDelete         = $canDelete
    PermissionSummary = $permSummary
    AclHint           = $aclHint
    Error             = $errMsg
  }
}

# --- Validate input files ---
if (-not (Test-Path -LiteralPath $AccountsFile)) { throw "Accounts file not found: $AccountsFile" }
if (-not (Test-Path -LiteralPath $SharesFile))   { throw "Shares file not found:   $SharesFile" }

$accounts = Get-Content -LiteralPath $AccountsFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\s*#' } | Select-Object -Unique
$shares   = Get-Content -LiteralPath $SharesFile   | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\s*#' } | Select-Object -Unique

if ($accounts.Count -lt 1) { throw "No accounts found in $AccountsFile" }
if ($shares.Count -lt 1)   { throw "No shares found in $SharesFile" }

# --- Collect credentials ---
Write-Status "Collecting credentials for $($accounts.Count) accounts..."
$creds = foreach ($acct in $accounts) {
  Get-Credential -UserName $acct -Message "Enter password for $acct"
}

# --- Run tests with progress ---
$total = $creds.Count * $shares.Count
$done  = 0
$results = New-Object System.Collections.Generic.List[object]

Write-Status "Starting tests: $($creds.Count) accounts x $($shares.Count) paths = $total checks. NetUseTimeout=${NetUseTimeoutSec}s"
Write-Status ("ReadFileTest={0} (Recurse={1}) | WriteTest={2}" -f [bool]$EnableReadFileTest, [bool]$ReadFileRecurse, [bool]$EnableWriteTest)

for ($ci = 0; $ci -lt $creds.Count; $ci++) {
  $cred = $creds[$ci]
  for ($si = 0; $si -lt $shares.Count; $si++) {
    $share = $shares[$si]
    $done++

    $pct = [math]::Round(($done / $total) * 100, 0)
    Write-Progress -Activity "Testing share access ($done of $total)" `
      -Status "Account: $($cred.UserName) | Path: $share" `
      -CurrentOperation "Map + checks (timeout: ${NetUseTimeoutSec}s)" `
      -PercentComplete $pct

    Write-Status "[$done/$total] Testing $($cred.UserName) => $share"

    $results.Add(
      (Test-ShareAccess -UncPath $share -Credential $cred -TimeoutSec $NetUseTimeoutSec `
        -DoReadFileTest ([bool]$EnableReadFileTest) -DoReadFileRecurse ([bool]$ReadFileRecurse) `
        -DoWriteTest ([bool]$EnableWriteTest) -WritePrefix $WriteTestFileNamePrefix)
    )
  }
}

Write-Progress -Activity "Testing share access" -Completed
Write-Status "Completed all tests."

# --- Output ---
$results | Sort-Object User, SharePath |
  Format-Table User, SharePath, CanMap, CanReach, CanList, CanReadFile, CanWrite, CanDelete, PermissionSummary, Error -AutoSize

if ($ExportCsv) {
  $results | Export-Csv -NoTypeInformation -Path $CsvPath
  Write-Status "Exported results to: $CsvPath"
}
