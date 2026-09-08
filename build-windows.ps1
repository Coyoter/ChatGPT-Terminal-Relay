param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string]$Runtime = 'win-x64'
)
$ErrorActionPreference = 'Stop'
$Version = '0.5.0'
$Architecture = $Runtime.Replace('win-', '')
$Output = Join-Path $PSScriptRoot "dist/windows-$Architecture"
$Archive = Join-Path $PSScriptRoot "dist/ChatGPT-Terminal-Relay-v$Version-Windows-$Architecture.zip"
New-Item -ItemType Directory -Path $Output -Force | Out-Null
dotnet publish (Join-Path $PSScriptRoot 'windows/ChatGPTTerminalRelay.csproj') -c Release -r $Runtime --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $Output
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
Copy-Item (Join-Path $PSScriptRoot 'README.md') $Output
Copy-Item (Join-Path $PSScriptRoot 'PROJECT_PROMPT.md') $Output
Copy-Item (Join-Path $PSScriptRoot 'LICENSE') $Output
Compress-Archive -Path "$Output/*" -DestinationPath $Archive -Force
Get-FileHash -Algorithm SHA256 $Archive
