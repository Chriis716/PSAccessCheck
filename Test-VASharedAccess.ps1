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
  [switch]$EnableReadFileTest,   # off by default; use -EnableReadFileTest to turn on
  [switch]$ReadFileRecurse,      # off by default; use -ReadFileRecurse to allow deep scan for a file

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
  <#
    Runs a command line via cmd.exe, captures stdout/stderr, and kills it if it exceeds timeout.
  #>
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
    return [pscustomobject]@{
      TimedOut = $true
      ExitCode = $null
      StdOut   = ""
      StdErr   = "Timed out after $TimeoutSec seconds."
    }
  }

  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()

  [pscustomobject]@{
    TimedOut = $false
    ExitCode = $p.ExitCode
    StdOut   = $out.Trim()
    StdErr   = $err.Trim()
  }
}

function Test-ShareAccess {
  param(
    [Parameter(Mandatory)][string]$UncPath,
    [Parameter(Mandatory)][pscredential]$Credential,
    [Parameter(Mandatory)][int]$TimeoutSec,
    [Parameter(Mandatory)][bool]$DoReadFileTest,
    [Parameter(Mandatory)][bool]$DoReadFileRecurse
  )

  $user = $Credential.UserName
  $pass = $Credential.GetNetworkCredential().Password

  $rootShare = Get-RootShareFromUnc -UncPath $UncPath
  if (-not $rootShare) {
    return [pscustomobject]@{
      User             = $user
      SharePath        = $UncPath
      RootShare        = $null
      CanMap           = $false
      CanReach         = $false
      CanList          = $false
      CanReadFile      = $false
      CanReadAcl       = $false
      PermissionSummary= "Invalid UNC path"
      AclHint          = $null
      Error            = "Invalid UNC path."
    }
  }

  $drive     = Get-FreeDriveLetter
  $drivePath = "$drive`:"
  $mapped    = $false
  $errMsg    = $null

  # Non-destructive "permission type" signals
  $canReach    = $false
  $canList     = $false
  $canReadFile = $false
  $canReadAcl  = $false
  $aclHint     = $null
  $permSummary = "Unknown"

  try {
    # Best-effort cleanup
    Invoke-CommandWithTimeout -CmdLine "net use $drivePath /delete /y" -TimeoutSec 5 | Out-Null

    # Map ROOT share (required for SMB auth), then test exact target path
    $mapCmd = "net use $drivePath `"$rootShare`" /user:`"$user`" `"$pass`""
    $mapRes = Invoke-CommandWithTimeout -CmdLine $mapCmd -TimeoutSec $TimeoutSec

    if ($mapRes.TimedOut) {
      $errMsg = $mapRes.StdErr
      $permSummary = "No Access"
    }
    elseif ($mapRes.ExitCode -eq 0) {
      $mapped = $true

      # Translate requested UNC into mapped path, preserving subfolder path
      $relative = $UncPath.Substring($rootShare.Length) # "" or "\sub\path"
      $testPath = Join-Path $drivePath ($relative.TrimStart('\'))

      # 1) Reach test (NO enumeration)
      try {
        $null = Get-Item -LiteralPath $testPath -ErrorAction Stop
        $canReach = $true
      }
      catch {
        $canReach = $false
        $errMsg = $_.Exception.Message
      }

      # 2) List test (enumeration)
      if ($canReach) {
        try {
          $null = Get-ChildItem -LiteralPath $testPath -ErrorAction Stop
          $canList = $true
        }
        catch {
          $canList = $false
          if (-not $errMsg) { $errMsg = $_.Exception.Message }
        }
      }

      # 3) Read file test (non-destructive; optional; only if you enable it)
      if ($DoReadFileTest -and $canList) {
        try {
          if ($DoReadFileRecurse) {
            $oneFile = Get-ChildItem -LiteralPath $testPath -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
          } else {
            $oneFile = Get-ChildItem -LiteralPath $testPath -File -ErrorAction SilentlyContinue | Select-Object -First 1
          }

          if ($oneFile) {
            $null = Get-Content -LiteralPath $oneFile.FullName -TotalCount 1 -ErrorAction Stop
            $canReadFile = $true
          }
        }
        catch {
          # Optional test, do not override primary error message
        }
      }

      # 4) ACL read test (non-destructive; may be denied)
      if ($canReach) {
        try {
          $acl = Get-Acl -LiteralPath $testPath -ErrorAction Stop
          $canReadAcl = $true

          # Keep this short and safe (first few entries only)
          $aclHint = ($acl.Access |
            Select-Object -First 5 |
            ForEach-Object { "$($_.IdentityReference): $($_.FileSystemRights) ($($_.AccessControlType))" }) -join "; "
        }
        catch {
          $canReadAcl = $false
        }
      }

      # Summary label (no write test per your requirement)
      $permSummary =
        if (-not $canReach) { "No Access" }
        elseif ($canReach -and -not $canList) { "Traverse Only" }
        elseif ($canList -and $canReadFile) { "Read Confirmed" }
        elseif ($canList) { "List Only" }
        else { "Reach Only" }
    }
    else {
      # net use failed
      $errMsg = ($mapRes.StdOut, $mapRes.StdErr | Where-Object { $_ }) -join " | "
      if (-not $errMsg) { $errMsg = "net use failed with exit code $($mapRes.ExitCode)" }
      $permSummary = "No Access"
    }
  }
  catch {
    $errMsg = $_.Exception.Message
    $permSummary = "No Access"
  }
  finally {
    # Always attempt to remove mapping
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
    PermissionSummary = $permSummary
    AclHint           = $aclHint
    Error             = $errMsg
  }
}

# -----------------------------
# Validate input files
# -----------------------------
if (-not (Test-Path -LiteralPath $AccountsFile)) { throw "Accounts file not found: $AccountsFile" }
if (-not (Test-Path -LiteralPath $SharesFile))   { throw "Shares file not found:   $SharesFile" }

$accounts = Get-Content -LiteralPath $AccountsFile |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ -and $_ -notmatch '^\s*#' } |
  Select-Object -Unique

$shares = Get-Content -LiteralPath $SharesFile |
  ForEach-Object { $_.Trim() } |
  Where-Object { $_ -and $_ -notmatch '^\s*#' } |
  Select-Object -Unique

if ($accounts.Count -lt 1) { throw "No accounts found in $AccountsFile" }
if ($shares.Count -lt 1)   { throw "No shares found in $SharesFile" }

# -----------------------------
# Collect credentials
# -----------------------------
Write-Status "Collecting credentials for $($accounts.Count) accounts..."
$creds = foreach ($acct in $accounts) {
  Get-Credential -UserName $acct -Message "Enter password for $acct"
}

# -----------------------------
# Run tests with progress + live status
# -----------------------------
$total = $creds.Count * $shares.Count
$done  = 0
$results = New-Object System.Collections.Generic.List[object]

Write-Status "Starting tests: $($creds.Count) accounts x $($shares.Count) paths = $total checks. NetUseTimeout=${NetUseTimeoutSec}s"

for ($ci = 0; $ci -lt $creds.Count; $ci++) {
  $cred = $creds[$ci]
  for ($si = 0; $si -lt $shares.Count; $si++) {
    $share = $shares[$si]
    $done++

    $pct = [math]::Round(($done / $total) * 100, 0)
    $activity = "Testing share access ($done of $total)"
    $status   = "Account: $($cred.UserName) | Path: $share"
    $current  = "Map + Reach/List/ACL checks (timeout: ${NetUseTimeoutSec}s)"

    Write-Progress -Activity $activity -Status $status -CurrentOperation $current -PercentComplete $pct
    Write-Status "[$done/$total] Testing $($cred.UserName) => $share"

    $results.Add(
      (Test-ShareAccess -UncPath $share -Credential $cred -TimeoutSec $NetUseTimeoutSec `
        -DoReadFileTest ([bool]$EnableReadFileTest) -DoReadFileRecurse ([bool]$ReadFileRecurse))
    )
  }
}

Write-Progress -Activity "Testing share access" -Completed
Write-Status "Completed all tests."

# -----------------------------
# Output
# -----------------------------
$results |
  Sort-Object User, SharePath |
  Format-Table User, SharePath, CanMap, CanReach, CanList, CanReadAcl, PermissionSummary, Error -AutoSize

if ($ExportCsv) {
  $results | Export-Csv -NoTypeInformation -Path $CsvPath
  Write-Status "Exported results to: $CsvPath"
}

<# 
USAGE:

1) Put these in the same folder as this script:
   - accounts.txt
   - shares.txt

2) Run:
   .\Test-VAShareAccess.ps1

3) Export CSV:
   .\Test-VAShareAccess.ps1 -ExportCsv

4) If you want to also confirm file read (non-destructive) when possible:
   .\Test-VAShareAccess.ps1 -EnableReadFileTest

   If you need to search deeper for a file (slower):
   .\Test-VAShareAccess.ps1 -EnableReadFileTest -ReadFileRecurse

5) Increase/decrease net use timeout:
   .\Test-VAShareAccess.ps1 -NetUseTimeoutSec 10
#>
