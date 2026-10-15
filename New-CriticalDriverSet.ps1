<#
.SYNOPSIS
    Monta o conjunto _Critical: so os drivers que precisam estar DENTRO da imagem.

.DESCRIPTION
    Os packs completos da Dell/Lenovo tem 3-4 GB cada. Injetar tudo isso no
    install.wim deixaria a imagem gigante e a instalacao lenta, sem ganho real -
    video, audio e biometria o Windows resolve depois, ou o tecnico aplica com
    Apply-Drivers.ps1.

    O que realmente precisa estar embutido e o minimo para a maquina "nascer"
    utilizavel e para o disco aparecer durante o Setup:

      Net          placa de rede e Wi-Fi   -> resolve o problema de ficar sem internet
      System       chipset                 -> inclui Intel VMD/DPTF
      HDC          controladora de disco
      SCSIAdapter  RAID / NVMe / Intel RST -> sem isso o Setup nao lista o SSD
      USB          controladoras USB       -> teclado/mouse e o proprio Ventoy
      Bluetooth    opcional, leve

    Le de D:\Drivers\<Fabricante>\<Modelo>\ e escreve em D:\Drivers\_Critical\.
    Nao exige privilegio de administrador.

.PARAMETER Classes
    Sobrescreve as classes consideradas criticas.

.PARAMETER Arquitetura
    Filtra por arquitetura no INF. Padrao: NTamd64.

.EXAMPLE
    .\New-CriticalDriverSet.ps1

.EXAMPLE
    .\New-CriticalDriverSet.ps1 -Classes Net,SCSIAdapter -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]] $Classes = @('Net', 'System', 'HDC', 'SCSIAdapter', 'USB'),
    [string]   $Arquitetura = 'NTamd64',
    # Teto por driver. Existe porque pacotes de video/audio trazem INF auxiliar
    # com Class=System; sem o teto, o conjunto "critico" passou de 9,8 GB.
    [int]      $MaxDriverMB = 150,
    [switch]   $Limpar
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Common.ps1"

$SsdRoot    = Split-Path $PSScriptRoot -Parent
$DriversDir = Join-Path $SsdRoot 'Drivers'
$CriticalDir= Join-Path $DriversDir '_Critical'

<#
    Le a classe declarada na secao [Version] do INF.
    Aceita tanto "Class=Net" quanto "ClassGuid=" (mapeado pelos GUIDs conhecidos).
#>
function Get-InfClass {
    param([Parameter(Mandatory)][string]$InfPath)

    $guidMap = @{
        '{4d36e972-e325-11ce-bfc1-08002be10318}' = 'Net'
        '{4d36e97d-e325-11ce-bfc1-08002be10318}' = 'System'
        '{4d36e96a-e325-11ce-bfc1-08002be10318}' = 'HDC'
        '{4d36e97b-e325-11ce-bfc1-08002be10318}' = 'SCSIAdapter'
        '{36fc9e60-c465-11cf-8056-444553540000}' = 'USB'
        '{e0cbf06c-cd8b-4647-bb8a-263b43f0f974}' = 'Bluetooth'
    }

    try {
        # Os primeiros ~120 linhas cobrem a secao [Version] em praticamente todo INF.
        $head = Get-Content -LiteralPath $InfPath -TotalCount 120 -ErrorAction Stop
    } catch { return $null }

    $classe = ($head | Where-Object { $_ -match '^\s*Class\s*=' } |
               Select-Object -First 1) -replace '^\s*Class\s*=\s*', '' -replace '\s*;.*$', ''
    $classe = $classe.Trim().Trim('"')
    if ($classe) { return $classe }

    $guid = ($head | Where-Object { $_ -match '^\s*ClassGuid\s*=' } |
             Select-Object -First 1) -replace '^\s*ClassGuid\s*=\s*', '' -replace '\s*;.*$', ''
    $guid = $guid.Trim().ToLower()
    if ($guid -and $guidMap.ContainsKey($guid)) { return $guidMap[$guid] }

    return $null
}

function Test-InfArquitetura {
    param([Parameter(Mandatory)][string]$InfPath, [string]$Arch)
    try {
        $txt = Get-Content -LiteralPath $InfPath -Raw -ErrorAction Stop
    } catch { return $false }
    # INF sem secao de arquitetura e generico; aceitamos.
    if ($txt -notmatch '\[Manufacturer\]') { return $true }
    return ($txt -match [regex]::Escape($Arch)) -or ($txt -notmatch 'NTamd64|NTx86|NTarm')
}

# ----------------------------------------------------------------------- main
Write-Log '=== New-CriticalDriverSet ===' 'STEP'
Write-Log "Classes criticas: $($Classes -join ', ')" 'INFO'

if (-not (Test-Path $DriversDir)) { throw "Pasta de drivers nao encontrada: $DriversDir" }

$packs = Get-ChildItem $DriversDir -Directory |
         Where-Object { $_.Name -notin @('_Critical', '_stage') } |
         ForEach-Object { Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue }

if (-not $packs) {
    Write-Log 'Nenhum driver pack extraido encontrado. Rode Sync-DriverPacks.ps1 antes.' 'WARN'
    return
}

if ($Limpar -and (Test-Path $CriticalDir)) {
    if ($PSCmdlet.ShouldProcess($CriticalDir, 'Remover conteudo anterior')) {
        Get-ChildItem $CriticalDir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if (-not (Test-Path $CriticalDir)) { New-Item -ItemType Directory -Path $CriticalDir -Force | Out-Null }

$resumo = @{}
$totalCopiados = 0

foreach ($pack in $packs) {
    $fabricante = Split-Path (Split-Path $pack.FullName -Parent) -Leaf
    $etiqueta   = "$fabricante`_$($pack.Name)"
    Write-Log "Analisando $etiqueta ..." 'STEP'

    $infs = @(Get-ChildItem $pack.FullName -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue)
    if ($infs.Count -eq 0) { Write-Log '  sem .inf' 'WARN'; continue }

    # Um driver mora numa pasta com seu .sys/.cat; copiamos a pasta do INF inteira.
    $pastasCopiadas = @{}
    $copiadosAqui = 0
    $ignoradosTamanho = 0

    # Ordenar por profundidade faz a pasta mais externa ser avaliada primeiro,
    # para que a checagem de ancestral abaixo funcione.
    $ordenados = $infs | Sort-Object { ($_.Directory.FullName -split '\\').Count }

    foreach ($inf in $ordenados) {
        $classe = Get-InfClass -InfPath $inf.FullName
        if (-not $classe -or ($Classes -notcontains $classe)) { continue }
        if (-not (Test-InfArquitetura -InfPath $inf.FullName -Arch $Arquitetura)) { continue }

        $origem = $inf.Directory.FullName
        if ($pastasCopiadas.ContainsKey($origem)) { continue }

        # Um INF dentro de uma pasta ja copiada viria junto na copia recursiva;
        # sem isso o mesmo payload entra duas vezes (foi o caso do pacote de video).
        $jaCoberto = $false
        foreach ($k in $pastasCopiadas.Keys) {
            if ($origem.StartsWith($k + '\', [StringComparison]::OrdinalIgnoreCase)) { $jaCoberto = $true; break }
        }
        if ($jaCoberto) { continue }

        # Driver de rede/chipset/storage e pequeno. Quando a pasta de um INF passa
        # de algumas centenas de MB, quase sempre e um pacote de video ou audio que
        # tem um INF auxiliar declarando Class=System. Injetar isso no install.wim
        # incharia a imagem sem resolver a dor de rede - entao fica de fora, e o
        # Apply-Drivers.ps1 instala depois a partir do pack completo.
        $tamMB = [math]::Round((Get-ChildItem $origem -Recurse -File -ErrorAction SilentlyContinue |
                  Measure-Object Length -Sum).Sum / 1MB, 1)
        if ($tamMB -gt $MaxDriverMB) {
            Write-Log ("  ignorado por tamanho: [{0}] {1} ({2} MB > {3} MB)" -f $classe, $inf.Directory.Name, $tamMB, $MaxDriverMB) 'WARN'
            $ignoradosTamanho++
            continue
        }

        $destino = Join-Path $CriticalDir "$classe\$etiqueta`_$($inf.Directory.Name)"
        if (Test-Path $destino) {
            $destino = Join-Path $CriticalDir "$classe\$etiqueta`_$($inf.Directory.Name)_$($inf.BaseName)"
        }

        if ($PSCmdlet.ShouldProcess($destino, "Copiar driver classe $classe")) {
            New-Item -ItemType Directory -Path $destino -Force | Out-Null
            Copy-Item "$origem\*" $destino -Recurse -Force -ErrorAction SilentlyContinue
        }

        $pastasCopiadas[$origem] = $true
        $copiadosAqui++
        if (-not $resumo.ContainsKey($classe)) { $resumo[$classe] = 0 }
        $resumo[$classe]++
    }

    if ($ignoradosTamanho) { Write-Log "  $ignoradosTamanho pacote(s) grande(s) deixado(s) de fora" 'INFO' }

    $totalCopiados += $copiadosAqui
    Write-Log "  $copiadosAqui driver(s) critico(s) de $($infs.Count) INF no pack" 'OK'
}

Write-Log '--- Resumo por classe ---' 'STEP'
$resumo.GetEnumerator() | Sort-Object Name |
    ForEach-Object { Write-Host ("  {0,-14} {1}" -f $_.Key, $_.Value) }

if (Test-Path $CriticalDir) {
    $mb = [math]::Round((Get-ChildItem $CriticalDir -Recurse -File -ErrorAction SilentlyContinue |
          Measure-Object Length -Sum).Sum / 1MB, 1)
    Write-Log "Total: $totalCopiados drivers, $mb MB em $CriticalDir" 'OK'
}
Write-Log 'Proximo passo: Update-WindowsImage.ps1 (elevado) injeta este conjunto na ISO.' 'INFO'
