<#
.SYNOPSIS
    Aplica o driver pack correto numa maquina ja instalada, direto do SSD.

.DESCRIPTION
    Rode este script NA MAQUINA RECEM-FORMATADA, com o SSD Ventoy plugado.
    Ele identifica o modelo, procura o pack correspondente em D:\Drivers e
    instala tudo com pnputil.

    Complementa o Update-WindowsImage.ps1: a imagem ja traz rede e chipset
    embutidos, e este script completa o resto (video, audio, leitor de digital,
    docking) sem precisar baixar nada da internet.

    EXIGE PowerShell elevado.

.PARAMETER Modelo
    Forca um pack especifico em vez de auto-detectar. Aceita parte do nome,
    ex. -Modelo 'Latitude 3540'.

.PARAMETER SsdRoot
    Raiz do SSD Ventoy. Auto-detectada pela presenca da pasta _toolkit.

.PARAMETER RelatorioSomente
    Nao instala nada: apenas lista os dispositivos sem driver e o pack que seria usado.

.EXAMPLE
    .\Apply-Drivers.ps1

.EXAMPLE
    .\Apply-Drivers.ps1 -RelatorioSomente
#>
[CmdletBinding()]
param(
    [string] $Modelo,
    [string] $SsdRoot,
    [switch] $RelatorioSomente,
    [switch] $IncluirCriticos
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Common.ps1"

function Find-SsdRoot {
    if ($SsdRoot) { return $SsdRoot }
    # O proprio script mora em <SSD>\_toolkit, entao o pai e a raiz.
    $porScript = Split-Path $PSScriptRoot -Parent
    if (Test-Path (Join-Path $porScript 'Drivers')) { return $porScript }

    foreach ($v in Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Removable' -or $_.FileSystem -eq 'exFAT' }) {
        $raiz = "$($v.DriveLetter):\"
        if (Test-Path (Join-Path $raiz '_toolkit\Sync-DriverPacks.ps1')) { return $raiz.TrimEnd('\') }
    }
    throw 'Nao encontrei o SSD Ventoy. Informe com -SsdRoot.'
}

function Get-DispositivosSemDriver {
    Get-CimInstance Win32_PnPEntity |
        Where-Object { $_.ConfigManagerErrorCode -in @(28, 31, 37, 39, 41) } |
        Select-Object Name, DeviceID, ConfigManagerErrorCode
}

# ----------------------------------------------------------------------- main
Assert-Admin
Write-Log '=== Apply-Drivers ===' 'STEP'

$raiz       = Find-SsdRoot
$driversDir = Join-Path $raiz 'Drivers'
Write-Log "SSD: $raiz" 'INFO'

$local = Get-LocalMachine
Write-Log "Maquina: $($local.Fabricante) $($local.Modelo) | serial $($local.Serial)" 'INFO'

$semDriver = @(Get-DispositivosSemDriver)
Write-Log "Dispositivos sem driver antes: $($semDriver.Count)" $(if ($semDriver.Count) { 'WARN' } else { 'OK' })
$semDriver | ForEach-Object { Write-Host ("    - " + $_.Name) }

# --------------------------------------------------------- localizar o pack
$busca = if ($Modelo) { $Modelo } else { $local.Modelo }
$candidatos = @()
if (Test-Path $driversDir) {
    $candidatos = Get-ChildItem $driversDir -Directory |
        Where-Object { $_.Name -notin @('_Critical', '_stage') } |
        ForEach-Object { Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue } |
        Where-Object { $busca -and ($_.Name -like "*$busca*" -or $busca -like "*$($_.Name)*") }
}

if (-not $candidatos) {
    Write-Log "Nenhum pack para '$busca' em $driversDir." 'WARN'
    Write-Log "Para baixar agora: .\Sync-DriverPacks.ps1 -Auto" 'INFO'
    if (-not $IncluirCriticos) { return }
}

$pastas = @($candidatos | ForEach-Object { $_.FullName })
if ($IncluirCriticos) {
    $crit = Join-Path $driversDir '_Critical'
    if (Test-Path $crit) { $pastas += $crit }
}

Write-Log '--- Pastas que serao aplicadas ---' 'STEP'
foreach ($p in $pastas) {
    $n = @(Get-ChildItem $p -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue).Count
    Write-Host ("    {0}  ({1} INF)" -f $p, $n)
}

if ($RelatorioSomente) { Write-Log 'RelatorioSomente - nada instalado.' 'INFO'; return }
if (-not $pastas) { Write-Log 'Nada a aplicar.' 'WARN'; return }

# ------------------------------------------------------------------ instalar
foreach ($p in $pastas) {
    Write-Log "pnputil em $p ..." 'STEP'
    $saida = & pnputil.exe /add-driver "$p\*.inf" /subdirs /install 2>&1
    $ok    = @($saida | Select-String -Pattern 'importado com|imported successfully|adicionado').Count
    Write-Log "pnputil retornou codigo $LASTEXITCODE ($ok pacote(s) confirmado(s))" $(if ($LASTEXITCODE -in 0, 259, 3010) { 'OK' } else { 'WARN' })
}

Start-Sleep -Seconds 5
$depois = @(Get-DispositivosSemDriver)
Write-Log "Dispositivos sem driver depois: $($depois.Count)" $(if ($depois.Count) { 'WARN' } else { 'OK' })
$depois | ForEach-Object { Write-Host ("    - " + $_.Name) }

if ($depois.Count -lt $semDriver.Count) {
    Write-Log "Resolvidos: $($semDriver.Count - $depois.Count)" 'OK'
}
Write-Log 'Reinicie a maquina para concluir a instalacao dos drivers.' 'INFO'
