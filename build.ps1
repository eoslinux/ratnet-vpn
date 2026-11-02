# Сборка портативного RatnetVPN.exe (Windows, PowerShell)
# Требуется: Python 3.10+, pip install -r requirements.txt pyinstaller

$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    python -m pip install --quiet --disable-pip-version-check pyinstaller

    python -m PyInstaller --noconfirm --clean --onefile --windowed `
        --name RatnetVPN `
        --icon "docs\icon.ico" `
        --version-file "version_info.txt" `
        --add-data "ratnet/scripts;ratnet/scripts" `
        launcher.py

    $out = Join-Path $PSScriptRoot 'RatnetVPN-portable'
    New-Item -ItemType Directory -Force -Path (Join-Path $out 'scripts') | Out-Null
    Copy-Item "dist\RatnetVPN.exe" (Join-Path $out 'RatnetVPN.exe') -Force
    Copy-Item "ratnet\scripts\*.sh" (Join-Path $out 'scripts') -Force
    Copy-Item "docs\ЧИТАЙ-МЕНЯ.txt" $out -Force -ErrorAction SilentlyContinue

    $size = (Get-Item (Join-Path $out 'RatnetVPN.exe')).Length / 1MB
    Write-Host ("Готово: {0} ({1:N1} МБ)" -f (Join-Path $out 'RatnetVPN.exe'), $size)
}
finally {
    Pop-Location
}
