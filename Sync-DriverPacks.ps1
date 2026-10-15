<#
.SYNOPSIS
    Baixa e extrai driver packs oficiais Dell / Lenovo para o SSD Ventoy.

.DESCRIPTION
    Consulta os catalogos oficiais (Dell DriverPackCatalog, Lenovo catalogv2),
    resolve o pack correto para cada modelo, baixa com verificacao de hash e
    extrai em D:\Drivers\<Fabricante>\<Modelo>\.

    Nao exige privilegio de administrador.

.PARAMETER Auto
    Detecta o fabricante/modelo da maquina onde o script esta rodando e
    sincroniza apenas o pack dela. Util para cobrir o parque organicamente:
    rode em cada maquina nova que aparecer para manutencao.

.PARAMETER DellSku
    Um ou mais SystemSKU Dell (4 caracteres, ex. 0C1E).

.PARAMETER LenovoMtm
    Um ou mais Machine Type Lenovo (4 caracteres, ex. 20M5).

.PARAMETER FromManifest
    Le a lista de modelos de models.json.

.PARAMETER OsCode
    win11 (padrao) ou win10.

.PARAMETER ListOnly
    Nao baixa: apenas mostra o que seria baixado, com tamanho e data.

.EXAMPLE
    .\Sync-DriverPacks.ps1 -Auto

.EXAMPLE
    .\Sync-DriverPacks.ps1 -FromManifest

.EXAMPLE
    .\Sync-DriverPacks.ps1 -LenovoMtm 21F6,20M5 -ListOnly
#>
[CmdletBinding(DefaultParameterSetName = 'Manifest')]
param(
    [Parameter(ParameterSetName = 'Auto')]     [switch]  $Auto,
    [Parameter(ParameterSetName = 'Explicit')] [string[]]$DellSku,
    [Parameter(ParameterSetName = 'Explicit')] [string[]]$LenovoMtm,
    [Parameter(ParameterSetName = 'Manifest')] [switch]  $FromManifest,
    [ValidateSet('win11', 'win10')]            [string]  $OsCode = 'win11',
                                               [switch]  $ListOnly,
                                               [switch]  $RefreshCatalog
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Common.ps1"

$Root       = $PSScriptRoot
$CacheDir   = Join-Path $Root 'catalog'
$DriversDir = Join-Path (Split-Path $Root -Parent) 'Drivers'
$Manifest   = Join-Path $Root 'models.json'

# ---------------------------------------------------------------- resolucao Dell
function Resolve-DellPack {
    param([xml]$Catalog, [string]$Sku, [string]$Os)

    $osFiltro = if ($Os -eq 'win11') { 'Windows11' } else { 'Windows10' }
    $achados = @()

    foreach ($p in $Catalog.DriverPackManifest.DriverPackage) {
        $osOk = @($p.SupportedOperatingSystems.OperatingSystem) |
                Where-Object { $_.osCode -eq $osFiltro -and $_.osArch -eq 'x64' }
        if (-not $osOk) { continue }

        foreach ($b in @($p.SupportedSystems.Brand)) {
            foreach ($m in @($b.Model)) {
                if ($m.systemID -ieq $Sku) {
                    $achados += [pscustomobject]@{
                        Fabricante = 'Dell'
                        Chave      = $Sku
                        Modelo     = (Format-NomePasta $m.name)
                        Versao     = $p.dellVersion
                        Data       = [datetime]$p.dateTime
                        Bytes      = [int64]$p.size
                        Url        = 'https://' + $Catalog.DriverPackManifest.baseLocation + '/' + $p.path
                        Hash       = $p.hashMD5
                        Algoritmo  = 'MD5'
                        Arquivo    = Split-Path $p.path -Leaf
                    }
                }
            }
        }
    }
    # O catalogo lista revisoes antigas junto - ficamos com a mais recente.
    $achados | Sort-Object Data -Descending | Select-Object -First 1
}

# -------------------------------------------------------------- resolucao Lenovo
function Resolve-LenovoPack {
    param([xml]$Catalog, [string]$Mtm, [string]$Os)

    $achados = @()
    foreach ($m in $Catalog.ModelList.Model) {
        $tipos = @($m.Types.Type)
        if ($tipos -notcontains $Mtm) { continue }

        foreach ($s in @($m.SCCM)) {
            if ($s.os -ne $Os) { continue }
            $url = ([string]$s.'#text').Trim()
            if (-not $url) { continue }
            $achados += [pscustomobject]@{
                Fabricante = 'Lenovo'
                Chave      = $Mtm
                Modelo     = (Format-NomePasta $m.name)
                Versao     = $s.version
                Data       = [datetime]$s.date
                Bytes      = 0            # o catalogo Lenovo nao publica o tamanho
                Url        = $url
                Hash       = $s.crc
                Algoritmo  = 'SHA256'
                Arquivo    = Split-Path $url -Leaf
            }
        }
    }
    # Preferimos a build mais nova (24H2 > 23H2 > 22H2 > 21H2).
    $achados | Sort-Object Versao, Data -Descending | Select-Object -First 1
}

# ------------------------------------------------------------------- extracao
function Expand-DriverPack {
    param([pscustomobject]$Pack, [string]$Instalador, [string]$Destino)

    $marcador = Join-Path $Destino '.extraido'
    if (Test-Path $marcador) {
        Write-Log "Ja extraido: $($Pack.Modelo)" 'OK'
        return
    }
    if (Test-Path $Destino) { Remove-Item $Destino -Recurse -Force -ErrorAction SilentlyContinue }

    # Os extratores da Dell (DUP) e da Lenovo quebram quando o caminho de destino
    # tem espaco - o pack sai com exit code 10 e nenhum arquivo. Por isso sempre
    # extraimos num diretorio temporario sem espaco, em disco local NTFS (que
    # tambem e bem mais rapido que exFAT via USB), e so depois movemos.
    $tempExtract = Join-Path $env:TEMP ('dup_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null

    try {
        Write-Log "Extraindo $($Pack.Arquivo) em area temporaria..." 'STEP'
        $argumentos = switch ($Pack.Fabricante) {
            'Dell'   { @('/s', "/e=$tempExtract") }
            'Lenovo' { @('/VERYSILENT', "/DIR=$tempExtract", '/EXTRACT=YES') }
        }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $proc = Start-Process -FilePath $Instalador -ArgumentList $argumentos -Wait -PassThru -NoNewWindow
        $sw.Stop()
        if ($proc.ExitCode -ne 0) {
            Write-Log "Extrator retornou codigo $($proc.ExitCode)" 'WARN'
        }

        $infs = @(Get-ChildItem $tempExtract -Filter *.inf -Recurse -ErrorAction SilentlyContinue)
        if ($infs.Count -eq 0) {
            throw "Nenhum .inf encontrado apos extrair $($Pack.Arquivo) (exit $($proc.ExitCode))."
        }
        Write-Log ("{0} INF extraidos em {1:mm\:ss}" -f $infs.Count, $sw.Elapsed) 'OK'

        # O extrator costuma criar uma subpasta propria (ex. Latitude-3540\).
        # Se houver exatamente uma pasta na raiz e nenhum arquivo solto, subimos
        # um nivel para nao aninhar sem necessidade.
        $raiz = $tempExtract
        $itens = @(Get-ChildItem $tempExtract -Force)
        if ($itens.Count -eq 1 -and $itens[0].PSIsContainer) { $raiz = $itens[0].FullName }

        $mb = [math]::Round((Get-ChildItem $raiz -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 0)
        Write-Log "Copiando $mb MB para $Destino ..." 'STEP'
        New-Item -ItemType Directory -Path $Destino -Force | Out-Null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & robocopy $raiz $Destino /E /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy falhou ao copiar para $Destino (codigo $LASTEXITCODE)." }
        # O robocopy usa 1 para "arquivos copiados com sucesso". Se deixarmos esse
        # valor em LASTEXITCODE, o script inteiro termina reportando falha.
        $global:LASTEXITCODE = 0
        $sw.Stop()

        $infsFinal = @(Get-ChildItem $Destino -Filter *.inf -Recurse -ErrorAction SilentlyContinue)
        if ($infsFinal.Count -ne $infs.Count) {
            throw "Copia incompleta: $($infsFinal.Count) INF no destino, esperava $($infs.Count)."
        }

        $Pack | ConvertTo-Json | Set-Content $marcador -Encoding UTF8
        Write-Log ("{0} INF em {1} (copia em {2:mm\:ss})" -f $infsFinal.Count, $Destino, $sw.Elapsed) 'OK'
    } finally {
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------------- main
Write-Log "=== Sync-DriverPacks | destino: $DriversDir ===" 'STEP'

$alvos = @()
switch ($PSCmdlet.ParameterSetName) {
    'Auto' {
        $local = Get-LocalMachine
        Write-Log "Maquina local: $($local.Fabricante) $($local.Modelo) (chave $($local.Chave))" 'INFO'
        if (-not $local.Chave) { throw 'Nao consegui determinar a chave de catalogo desta maquina.' }
        $alvos += [pscustomobject]@{ Fabricante = $local.Fabricante; Chave = $local.Chave }
    }
    'Explicit' {
        foreach ($s in @($DellSku))   { $alvos += [pscustomobject]@{ Fabricante = 'Dell';   Chave = $s } }
        foreach ($s in @($LenovoMtm)) { $alvos += [pscustomobject]@{ Fabricante = 'Lenovo'; Chave = $s } }
    }
    'Manifest' {
        if (-not (Test-Path $Manifest)) { throw "models.json nao encontrado em $Manifest" }
        $j = Get-Content $Manifest -Raw | ConvertFrom-Json
        foreach ($m in $j.modelos) {
            if ($m.ativo -eq $false) { continue }
            $alvos += [pscustomobject]@{ Fabricante = $m.fabricante; Chave = $m.chave }
        }
    }
}

if ($alvos.Count -eq 0) { Write-Log 'Nenhum modelo a processar.' 'WARN'; return }

$catDell = $null
$catLnv  = $null
if (@($alvos.Fabricante) -contains 'Dell')   { $catDell = Get-DellCatalog   -CacheDir $CacheDir -Refresh:$RefreshCatalog }
if (@($alvos.Fabricante) -contains 'Lenovo') { $catLnv  = Get-LenovoCatalog -CacheDir $CacheDir -Refresh:$RefreshCatalog }

$resolvidos = @()
foreach ($a in $alvos) {
    $pk = switch ($a.Fabricante) {
        'Dell'   { Resolve-DellPack   -Catalog $catDell -Sku $a.Chave -Os $OsCode }
        'Lenovo' { Resolve-LenovoPack -Catalog $catLnv  -Mtm $a.Chave -Os $OsCode }
        default  { $null }
    }
    if (-not $pk) {
        Write-Log "Sem pack $OsCode para $($a.Fabricante) chave $($a.Chave)" 'WARN'
        continue
    }
    $resolvidos += $pk
}

if ($resolvidos.Count -eq 0) { Write-Log 'Nenhum pack resolvido.' 'WARN'; return }

Write-Log '--- Packs resolvidos ---' 'STEP'
$resolvidos | Format-Table Fabricante, Chave, Modelo, Versao,
    @{ n = 'MB';   e = { if ($_.Bytes) { [math]::Round($_.Bytes / 1MB, 0) } else { '?' } } },
    @{ n = 'Data'; e = { $_.Data.ToString('yyyy-MM-dd') } } -AutoSize | Out-String | Write-Host

if ($ListOnly) { Write-Log 'ListOnly - nada baixado.' 'INFO'; return }

$stageDir = Join-Path $DriversDir '_stage'
foreach ($pk in $resolvidos) {
    $destino = Join-Path $DriversDir ($pk.Fabricante + '\' + $pk.Modelo)
    $inst    = Join-Path $stageDir $pk.Arquivo
    try {
        Get-RemoteFile -Uri $pk.Url -OutFile $inst -ExpectedHash $pk.Hash -Algorithm $pk.Algoritmo | Out-Null
        Expand-DriverPack -Pack $pk -Instalador $inst -Destino $destino
        Remove-Item $inst -Force -ErrorAction SilentlyContinue
    } catch {
        Write-Log "$($pk.Modelo): $($_.Exception.Message)" 'ERRO'
    }
}

Write-Log '=== Concluido ===' 'OK'
