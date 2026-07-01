#!/usr/bin/env bash
set -euo pipefail

src="${1:-setup.ps1}"
out="${2:-dist/setup.ps1}"
out_dir="$(dirname "$out")"

mkdir -p "$out_dir"

if base64 --help 2>&1 | grep -q -- '-w'; then
  payload="$(base64 -w 0 "$src")"
else
  payload="$(base64 "$src" | tr -d '\n')"
fi

cat > "$out" <<EOF
# ASCII-only bootstrap generated from setup.ps1. Do not edit.
[CmdletBinding()]
param(
    [ValidateSet('Install','UpgradeAll','ApplyPolicy','ProcessQueue','ProcessRequest','ProcessRequests')]
    [string]\$Mode = 'Install',
    [ValidateSet('Install','Uninstall')]
    [string]\$RequestAction = 'Install',
    [string]\$AppAlias,
    [string]\$RequestedBy,
    [string]\$RequestedBySid
)

Set-StrictMode -Version Latest
\$ErrorActionPreference = 'Stop'

\$Payload = @'
$payload
'@

\$PayloadBytes = [Convert]::FromBase64String(\$Payload)
\$OutputBytes = New-Object byte[] (\$PayloadBytes.Length + 3)
\$OutputBytes[0] = 0xEF
\$OutputBytes[1] = 0xBB
\$OutputBytes[2] = 0xBF
[Array]::Copy(\$PayloadBytes, 0, \$OutputBytes, 3, \$PayloadBytes.Length)

\$TempScript = Join-Path ([System.IO.Path]::GetTempPath()) ('softkat-{0}.ps1' -f [Guid]::NewGuid().ToString('N'))
[System.IO.File]::WriteAllBytes(\$TempScript, \$OutputBytes)

try {
    & \$TempScript -Mode \$Mode -RequestAction \$RequestAction -AppAlias \$AppAlias -RequestedBy \$RequestedBy -RequestedBySid \$RequestedBySid
}
finally {
    Remove-Item -LiteralPath \$TempScript -Force -ErrorAction SilentlyContinue
}
EOF
