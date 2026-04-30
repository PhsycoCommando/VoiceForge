# Build VoiceForge distribution zip
# Run from the repo root (voice_forge/)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
if (-not $root) { $root = Get-Location }

$stagingDir = Join-Path $root ".tmp\VoiceForge"
$zipPath = Join-Path (Split-Path $root) "VoiceForge.zip"

Write-Host "`n  Building VoiceForge distribution...`n"

# Clean staging
if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
New-Item $stagingDir -ItemType Directory -Force | Out-Null

# --- Copy frontend ---
Copy-Item "$root\VoiceForge.exe" "$stagingDir\VoiceForge.exe"
Copy-Item "$root\flutter_windows.dll" "$stagingDir\flutter_windows.dll"
Copy-Item "$root\data" "$stagingDir\data" -Recurse

# --- Copy backend (no venv, no __pycache__, no tests) ---
$backendDest = Join-Path $stagingDir "backend"
New-Item $backendDest -ItemType Directory -Force | Out-Null

$backendFiles = @(
    "server.py", "config.py", "formatter.py", "ai_formatter.py",
    "audio_capture.py", "speech_detector.py", "transcriber.py",
    "session_manager.py", "voice_forge.json", "requirements.txt"
)
foreach ($f in $backendFiles) {
    Copy-Item "$root\backend\$f" "$backendDest\$f"
}

# --- Copy docs and installers ---
Copy-Item "$root\INSTALL.md" "$stagingDir\INSTALL.md"
Copy-Item "$root\README.md" "$stagingDir\README.md"
Copy-Item "$root\VERSION" "$stagingDir\VERSION"
Copy-Item "$root\LICENSE" "$stagingDir\LICENSE"
Copy-Item "$root\install_backend.bat" "$stagingDir\install_backend.bat"
Copy-Item "$root\install_ollama.bat" "$stagingDir\install_ollama.bat"

# --- Create zip ---
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stagingDir, $zipPath,
    [System.IO.Compression.CompressionLevel]::Optimal, $true
)

# Clean staging
Remove-Item $stagingDir -Recurse -Force

$size = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Host "  Done! VoiceForge.zip = $size MB"
Write-Host "  Path: $zipPath`n"
