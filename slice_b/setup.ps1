# Slice B 一键准备：同步 MCP 插件 + 合成音频素材（全部幂等，不动存档）。
# 用法：powershell -File slice_b/setup.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root "addons/godot_mcp"
$dst = Join-Path $PSScriptRoot "addons/godot_mcp"
if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
New-Item -ItemType Directory -Force -Path (Join-Path $PSScriptRoot "addons") | Out-Null
Copy-Item -Recurse $src $dst
# 插件启用：切片项目自己的 project.godot 保持受控更新。
$project = Join-Path $PSScriptRoot "project.godot"
$text = Get-Content $project -Raw
if ($text -notmatch 'res://addons/godot_mcp/plugin.cfg') {
    $text = $text.Replace("enabled=PackedStringArray()", "enabled=PackedStringArray(`"res://addons/godot_mcp/plugin.cfg`")")
    Set-Content $project $text -NoNewline
}
Write-Host "slice_b addon synced from $src"
# 素材准备：天空纹理随仓库；音频由幂等脚本合成（存在且大小符合即跳过）。
$prepare = Join-Path $PSScriptRoot "prepare_assets.py"
$python = (Get-Command python -ErrorAction SilentlyContinue)
if ($python) {
    & $python.Source $prepare
    if ($LASTEXITCODE -ne 0) { throw "asset preparation failed" }
} else {
    Write-Warning "python not found - run 'python slice_b/prepare_assets.py' manually before playing"
}
