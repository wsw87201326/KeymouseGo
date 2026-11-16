<#
.SYNOPSIS
    KeymouseGo Windows 一键打包（Python 3.14）。

.DESCRIPTION
    从零复现 dist\KeymouseGo.exe 的完整流程：
      1. 建 .venv314 虚拟环境
      2. 装 requirements-windows.txt 里对齐到 3.14 的运行时依赖
      3. 从 vendor\ 编译安装打过补丁的 pyWinhook（3.14 没有预编译轮子）
      4. 跑 PyInstaller 出单文件 exe

.PARAMETER SkipVenv
    复用已有的 .venv314，不重新创建。

.PARAMETER PyVersion
    Python 版本，默认 3.14。

.EXAMPLE
    pwsh -File .\build_windows.ps1
    pwsh -File .\build_windows.ps1 -SkipVenv
#>

[CmdletBinding()]
param(
    [switch]$SkipVenv,
    [string]$PyVersion = '3.14'
)

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$VenvPath   = Join-Path $PSScriptRoot '.venv314'
$PyExe      = Join-Path $VenvPath 'Scripts\python.exe'
$ScriptsDir = Join-Path $VenvPath 'Scripts'
$VendorSrc  = Join-Path $PSScriptRoot 'vendor\pyWinhook-1.6.2'
$WheelOut   = Join-Path $PSScriptRoot 'vendor_wheels'

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }

# ---------------------------------------------------------------- 1. 虚拟环境
Write-Step "1/4 虚拟环境 (.venv314, Python $PyVersion)"
if ($SkipVenv -and (Test-Path $PyExe)) {
    Write-Ok "复用已存在的 venv"
} else {
    if (-not (Test-Path $PyExe)) {
        Write-Host "    用 py -$PyVersion -m venv 创建中..."
        & py "-$PyVersion" -m venv $VenvPath
        if ($LASTEXITCODE -ne 0) { throw "创建 venv 失败，确认机器上装了 Python $PyVersion" }
    }
    Write-Ok (& $PyExe --version)
}

# pip 在 .venv314\Scripts 下必须能被找到：swig.exe 是个 Python 壳程序，
# 靠 PATH 找到它之后还要能 import 到 swig 模块。
if ($env:PATH -notlike "*$ScriptsDir*") {
    $env:PATH = "$ScriptsDir;$env:PATH"
}

$pipArgs  = @('-m','pip','install','--disable-pip-version-check')
$wheelArgs = @('-m','pip','wheel','--disable-pip-version-check')

# ---------------------------------------------------------------- 2. 运行时依赖
Write-Step "2/4 运行时依赖"
& $PyExe @pipArgs -r (Join-Path $PSScriptRoot 'requirements-windows.txt')
if ($LASTEXITCODE -ne 0) { throw "装运行时依赖失败" }
Write-Ok "requirements-windows.txt 安装完成"

# ---------------------------------------------------------------- 3. pyWinhook
Write-Step "3/4 编译 pyWinhook (vendor 源码, 见 vendor/pyWinhook-1.6.2/PATCHES.md)"

if (-not (Test-Path (Join-Path $VendorSrc 'pyWinhook\cpyHook.i'))) {
    throw "找不到 vendor 源码：$VendorSrc"
}

# 补丁校验：源码里必须已经是 PyLong_AsLong
$HookI = Get-Content (Join-Path $VendorSrc 'pyWinhook\cpyHook.i') -Raw
if ($HookI -match 'PyInt_AsLong') {
    throw "vendor 源码里还有 PyInt_AsLong，补丁没打上，编不过（见 PATCHES.md）"
}
if ($HookI -notmatch 'PyLong_AsLong') {
    throw "vendor 源码里找不到 PyLong_AsLong，源码可能不完整"
}
Write-Ok "补丁校验通过"

# swig（编译 _cpyHook 扩展要用）+ setuptools
& $PyExe @pipArgs swig setuptools wheel
if ($LASTEXITCODE -ne 0) { throw "装 swig/setuptools/wheel 失败" }

# MSVC 存在性检查
$VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $VsWhere) {
    $Msvc = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($Msvc) { Write-Ok "MSVC: $Msvc" } else { Write-Warning "没找到 MSVC，编译 _cpyHook 会失败（装 VS 的「使用 C++ 的桌面开发」工作负载）" }
} else {
    Write-Warning "没找到 vswhere.exe，编译 _cpyHook 可能失败"
}

New-Item -ItemType Directory -Path $WheelOut -Force | Out-Null

# --no-build-isolation 必须加：pip 隔离环境会遮蔽 venv 的 site-packages，
# 导致 pip 装的 swig.exe（Python 壳）import 不到 swig 模块。
Push-Location $VendorSrc
try {
    & $PyExe @wheelArgs . --no-build-isolation --no-deps -w $WheelOut
    if ($LASTEXITCODE -ne 0) { throw "编译 pyWinhook 失败" }
} finally {
    Pop-Location
}

$Wheel = Get-ChildItem $WheelOut -Filter 'pywinhook-*.whl' |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $Wheel) { throw "编译完了但没找到 wheel，检查 $WheelOut" }
Write-Ok "wheel: $($Wheel.Name)"

& $PyExe -m pip install --disable-pip-version-check --no-index --no-deps --force-reinstall $Wheel.FullName
if ($LASTEXITCODE -ne 0) { throw "安装 pyWinhook 失败" }
Write-Ok "pyWinhook 安装完成"

# ---------------------------------------------------------------- 4. 打包
Write-Step "4/4 PyInstaller 打包"
& $PyExe @pipArgs pyinstaller
if ($LASTEXITCODE -ne 0) { throw "装 pyinstaller 失败" }

if (Test-Path 'build')    { Write-Ok "复用/覆盖 build 目录" }
if (Test-Path 'KeymouseGo.spec') { Write-Ok "复用已有 KeymouseGo.spec" }

& $PyExe -m PyInstaller -F -w --clean `
    --add-data "./assets;assets" `
    --name "KeymouseGo" `
    KeymouseGo.py
if ($LASTEXITCODE -ne 0) { throw "PyInstaller 打包失败" }

$Exe = Join-Path $PSScriptRoot 'dist\KeymouseGo.exe'
if (-not (Test-Path $Exe)) { throw "打包结束了但 dist\KeymouseGo.exe 不存在" }

$SizeMB = [math]::Round((Get-Item $Exe).Length / 1MB, 1)
Write-Host "`n打包成功: dist\KeymouseGo.exe  ($SizeMB MB)" -ForegroundColor Green
