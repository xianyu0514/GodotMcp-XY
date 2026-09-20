# Slice B addon 同步：把主仓库的 MCP 插件拷进切片项目（addons 不入 git）。
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
