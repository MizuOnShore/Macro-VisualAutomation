$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $root "Macro.Windows\Macro.Windows.csproj"

dotnet run --project (Join-Path $root "Macro.Tests\Macro.Tests.csproj") -c Release
dotnet publish $project -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -o (Join-Path $root "artifacts\win-x64")
dotnet publish $project -c Release -r win-arm64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -o (Join-Path $root "artifacts\win-arm64")

Write-Host "Windows builds are in WindowsApp\artifacts."
