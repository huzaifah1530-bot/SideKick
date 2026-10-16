# Run the existing installation without changing PATH or downloading packages.
$graphifyCommand = Get-Command graphify -CommandType Application -ErrorAction SilentlyContinue
$graphifyExecutable = if ($graphifyCommand) {
    $graphifyCommand.Source
} else {
    Join-Path $env:USERPROFILE '.local\bin\graphify.exe'
}
if (-not (Test-Path -LiteralPath $graphifyExecutable -PathType Leaf)) {
    throw 'Graphify is not installed. Follow docs/graphify.md to install graphifyy with uv.'
}
& $graphifyExecutable @args
exit $LASTEXITCODE
