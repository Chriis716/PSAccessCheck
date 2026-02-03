<#
.SYNOPSIS
  Tests access to UNC paths using multiple service accounts from a list.

.INPUTS
  accounts.txt  (one account per line, e.g. VA\OITXXXIA)
  shares.txt    (one UNC path per line, e.g. \\server\share or \\server\share\subfolder)

.OUTPUTS
  Console table and optional CSV

.NOTES
  - Uses 'net use' to map the ROOT share (\\server\share) with each credential.
  - Then attempts to list the requested path (share root or subfolder).
  - Cleans up mappings after each test.
#>


param(
  [string]$AccountsFile = "$PSScriptRoot\accounts.txt",
  [string]$SharesFile   = "$PSScriptRoot\shares.txt",
  [switch]$ExportCsv,
  [string]$CsvPath      = "$PSScriptRoot\ShareAccessResults.csv",

  # Timeout for each net use call (seconds)
  [int]$NetUseTimeoutSec = 20
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
  "\\$($parts[0])\$($parts[1])"
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
    [Parameter(Mandatory)][int]$TimeoutSec
  )

  $user = $Credential.UserName
  $pass = $Credential.GetNetworkCredential().Password

  $rootShare = Get-RootShareFromUnc -UncPath $UncPath
  if (-not $rootShare) {
    return [pscustomobject]@{
      User      = $user
      SharePath = $UncPath
      RootShare = $null
      CanMap    = $false
      CanList   = $false
      Error     = "Invalid UNC path."
    }
  }

  $drive = Get-FreeDriveLetter
  $drivePath = "$drive`:"
  $mapped = $false
  $canList = $false
  $errMsg = $null

  try {
    # Best effort cleanup
    Invoke-CommandWithTimeout -CmdLine "net use $drivePath /delete /y" -TimeoutSec 5 | Out-Null

    # Map root share
    $mapCmd = "net use $drivePath `"$rootShare`" /user:`"$user`" `"$pass`""
    $mapRes = Invoke-CommandWithTimeout -CmdLine $mapCmd -TimeoutSec $TimeoutSec

    if ($mapRes.TimedOut) {
      $errMsg = $mapRes.StdErr
    }
    elseif ($mapRes.ExitCode -eq 0) {
      $mapped = $true

      # Convert requested UNC path into mapped path (subfolders included)
      $relative = $UncPath.Substring($rootShare.Length) # "" or "\sub\path"
      $testPath = Join-Path $drivePath ($relative.TrimStart('\'))

      try {
        Get-ChildItem -LiteralPath $testPath -ErrorAction Stop | Out-Null
        $canList = $true
      }
      catch {
        $canList = $false
        $errMsg = $_.Exception.Message
      }
    }
    else {
      # net use failed
      $errMsg = ($mapRes.StdOut, $mapRes.StdErr | Where-Object { $_ }) -join " | "
      if (-not $errMsg) { $errMsg = "net use failed with exit code $($mapRes.ExitCode)" }
    }
  }
  finally {
    Invoke-CommandWithTimeout -CmdLine "net use $drivePath /delete /y" -TimeoutSec 5 | Out-Null
  }

  [pscustomobject]@{
    User      = $user
    SharePath = $UncPath
    RootShare = $rootShare
    CanMap    = $mapped
    CanList   = $canList
    Error     = $errMsg
  }
}

# --- Load lists ---
if (-not (Test-Path -LiteralPath $AccountsFile)) { throw "Accounts file not found: $AccountsFile" }
if (-not (Test-Path -LiteralPath $SharesFile))   { throw "Shares file not found:   $SharesFile" }

$accounts = Get-Content -LiteralPath $AccountsFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\s*#' } | Select-Object -Unique
$shares   = Get-Content -LiteralPath $SharesFile   | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^\s*#' } | Select-Object -Unique

# --- Prompt creds ---
Write-Status "Collecting credentials for $($accounts.Count) accounts..."
$creds = foreach ($acct in $accounts) { Get-Credential -UserName $acct -Message "Enter password for $acct" }

# --- Run tests with progress ---
$total = $creds.Count * $shares.Count
$done  = 0
$results = New-Object System.Collections.Generic.List[object]

for ($ci = 0; $ci -lt $creds.Count; $ci++) {
  $cred = $creds[$ci]
  for ($si = 0; $si -lt $shares.Count; $si++) {
    $share = $shares[$si]
    $done++

    $pct = [math]::Round(($done / $total) * 100, 0)
    $activity = "Testing share access ($done of $total)"
    $status   = "Account: $($cred.UserName) | Path: $share"
    $current  = "Mapping and listing (timeout: ${NetUseTimeoutSec}s)"

    Write-Progress -Activity $activity -Status $status -CurrentOperation $current -PercentComplete $pct
    Write-Status "Testing: $($cred.UserName) => $share"

    $results.Add((Test-ShareAccess -UncPath $share -Credential $cred -TimeoutSec $NetUseTimeoutSec))
  }
}

Write-Progress -Activity "Testing share access" -Completed

# --- Output ---
$results | Sort-Object User, SharePath | Format-Table User, SharePath, CanMap, CanList, Error -AutoSize

if ($ExportCsv) {
  $results | Export-Csv -NoTypeInformation -Path $CsvPath
  Write-Status "Exported results to: $CsvPath"
}
