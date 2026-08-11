param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $Arguments
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$flutter = Join-Path $repoRoot '.tooling\flutter\bin\flutter.bat'
$env:JAVA_HOME = Join-Path $repoRoot '.tooling\jdk-17.0.19+10'
$env:ANDROID_SDK_ROOT = Join-Path $repoRoot '.tooling\android\sdk'
$env:ANDROID_HOME = $env:ANDROID_SDK_ROOT

if (-not (Test-Path -LiteralPath $flutter)) {
  throw "Portable Flutter SDK fehlt: $flutter"
}

Push-Location (Join-Path $repoRoot 'flutter_app')
try {
  & $flutter @Arguments
  $script:LASTEXITCODE = $LASTEXITCODE
} finally {
  Pop-Location
}
