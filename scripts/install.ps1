# Installs the droves bridge from GitHub Releases.
#
#   irm https://github.com/ihsan-ramadhan/droves/releases/latest/download/install.ps1 | iex
#
# Environment:
#   DROVES_VERSION    tag to install (default: latest release)
#   DROVES_BIN_DIR    where the binary goes (default: %LOCALAPPDATA%\droves\bin)
#   DROVES_SHARE_DIR  where the web build goes (default: %LOCALAPPDATA%\droves)
#   DROVES_NO_WEB     set to 1 to skip the web build
$ErrorActionPreference = 'Stop'

$repo     = if ($env:DROVES_REPO) { $env:DROVES_REPO } else { 'ihsan-ramadhan/droves' }
$version  = if ($env:DROVES_VERSION) { $env:DROVES_VERSION } else { 'latest' }
$binDir   = if ($env:DROVES_BIN_DIR) { $env:DROVES_BIN_DIR } else { Join-Path $env:LOCALAPPDATA 'droves\bin' }
$shareDir = if ($env:DROVES_SHARE_DIR) { $env:DROVES_SHARE_DIR } else { Join-Path $env:LOCALAPPDATA 'droves' }
$skipWeb  = $env:DROVES_NO_WEB -eq '1'

if ($version -eq 'latest') {
  $base = "https://github.com/$repo/releases/latest/download"
} else {
  $base = "https://github.com/$repo/releases/download/$version"
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("droves-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Get-Checksum([string]$file) {
  $expected = Select-String -Path "$tmp\SHA256SUMS.txt" -Pattern (' ' + [regex]::Escape($file) + '$') |
    ForEach-Object { ($_.Line -split '\s+')[0] } | Select-Object -First 1
  if (-not $expected) { throw "release has no checksum for $file; refusing to install" }
  $actual = (Get-FileHash (Join-Path $tmp $file) -Algorithm SHA256).Hash
  if ($actual -ne $expected) { throw "checksum mismatch for $file" }
}

try {
  Write-Host "fetching droves bridge from $base"
  Invoke-WebRequest -UseBasicParsing -Uri "$base/droves-bridge-windows-amd64.exe" -OutFile "$tmp\droves-bridge-windows-amd64.exe"
  Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS.txt" -OutFile "$tmp\SHA256SUMS.txt"
  Get-Checksum 'droves-bridge-windows-amd64.exe'

  if (-not $skipWeb) {
    Invoke-WebRequest -UseBasicParsing -Uri "$base/droves-web.tar.gz" -OutFile "$tmp\droves-web.tar.gz"
    Get-Checksum 'droves-web.tar.gz'
  }

  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  $dest = Join-Path $binDir 'droves-bridge.exe'
  # a running bridge locks its exe and would keep serving the old build
  $running = Get-Process -Name 'droves-bridge' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $dest }
  $oldCmdline = $null
  if ($running) {
    # capture before killing: the process object outlives its WMI entry
    $oldCmdline = (Get-CimInstance Win32_Process -Filter "ProcessId=$($running[0].Id)" -ErrorAction SilentlyContinue).CommandLine
    $running | Stop-Process -Force
    Start-Sleep -Milliseconds 500
  }
  Copy-Item "$tmp\droves-bridge-windows-amd64.exe" $dest -Force

  if (-not $skipWeb) {
    $webDir = Join-Path $shareDir 'web'
    if (Test-Path $webDir) { Remove-Item -Recurse -Force $webDir }
    New-Item -ItemType Directory -Force -Path $webDir | Out-Null
    # tar.exe ships with Windows 10 1803+ and reads the gzip tarball
    tar -xzf "$tmp\droves-web.tar.gz" -C $webDir
    if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }
    # the manifest points the app at <bridge>/droves/download/<apk>
    $downloadDir = Join-Path $webDir 'download'
    New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
    foreach ($apk in @('droves-arm64.apk', 'droves-arm.apk', 'droves-x86_64.apk')) {
      try {
        Invoke-WebRequest -UseBasicParsing -Uri "$base/$apk" -OutFile (Join-Path $downloadDir $apk)
      } catch {
        Write-Host "warning: $apk not in this release"
      }
    }
    # the app reads the manifest from the bridge origin, so it sits in the
    # same directory the bridge serves
    try {
      Invoke-WebRequest -UseBasicParsing -Uri "$base/update.json" -OutFile (Join-Path $webDir 'update.json')
    } catch {
      Write-Host 'warning: no update.json in this release; in-app update checks stay quiet'
    }
    Write-Host "web build: $webDir"
  }

  $bridge = Join-Path $binDir 'droves-bridge.exe'
  $installed = & $bridge -version
  Write-Host "bridge:    $bridge ($installed)"

  if ($running) {
    # relaunch detached with the arguments the old process had
    $bridgeArgs = if ($oldCmdline -and $oldCmdline -match '^"[^"]*"\s+(.*)$') { $Matches[1] } else { '' }
    if ($bridgeArgs) {
      Start-Process -FilePath $dest -ArgumentList $bridgeArgs -WindowStyle Hidden
    } else {
      Start-Process -FilePath $dest -WindowStyle Hidden
    }
    Write-Host 'service:   running bridge restarted onto the new build'
  }

  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath -notlike "*$binDir*") {
    Write-Host "note: $binDir is not on PATH. Add it for this session with:"
    Write-Host "      `$env:Path += ';$binDir'"
  }

  Write-Host ""
  Write-Host "Next steps"
  Write-Host "  1. install herdr: https://github.com/herdrdev/herdr"
  Write-Host "  2. start the bridge:"
  Write-Host "       droves-bridge -addr 127.0.0.1:13030 -web `"$shareDir\web`""
  Write-Host "  3. read the access token:"
  Write-Host "       type `"`$env:USERPROFILE\.config\droves-bridge\token`""
  Write-Host "  4. expose the port on your tailnet only:"
  Write-Host "       tailscale serve --bg 13030"
  Write-Host ""
  Write-Host "Update later by running this script again."
}
finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
