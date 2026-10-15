<#
.SYNOPSIS
    Aplica os cumulative updates mais recentes e os drivers criticos dentro da
    ISO do Windows 11, gerando uma ISO nova que ja nasce atualizada.

.DESCRIPTION
    Resolve as duas dores do processo de formatacao:

      1. Windows Update pos-instalacao demorado
         O install.wim recebe o LCU mais recente (e o checkpoint, quando exigido)
         direto do Microsoft Update Catalog. A maquina termina a instalacao com
         meses de atualizacao ja embutidos.

      2. Maquina sem driver de rede depois de instalar
         Os drivers criticos (rede, Wi-Fi, chipset, storage) sao injetados tanto
         no install.wim quanto no boot.wim - o segundo garante que o disco e a
         rede aparecam ja durante o Setup.

    EXIGE PowerShell elevado. O diretorio de trabalho precisa estar em volume
    NTFS: o DISM grava ACLs que o exFAT do Ventoy nao suporta, entao nunca
    monte a imagem direto no SSD.

.PARAMETER SourceIso
    ISO de origem. Se omitido, usa a ISO de Windows mais recente encontrada no
    SSD (D:\ISO e a raiz).

.PARAMETER WindowsVersion
    Versao alvo no catalogo (24H2, 25H2...). Se omitido, e deduzida do nome da ISO.

.PARAMETER ScratchRoot
    Pasta de trabalho em NTFS. Precisa de ~40 GB livres.

.PARAMETER DriverPath
    Pasta com os drivers a injetar. Padrao: D:\Drivers\_Critical
    (gerada por New-CriticalDriverSet.ps1).

.PARAMETER ImageIndex
    Indices do install.wim a atualizar. Padrao: apenas as edicoes Pro.
    Use -ImageIndex 0 para processar todas (bem mais demorado).

.PARAMETER IsoPrefix
    Prefixo do nome e do rotulo da ISO gerada. Saida:
    <IsoPrefix>_<WindowsVersion>_<AAAAMM>.iso (rotulo limitado a 32 caracteres).

.EXAMPLE
    .\Update-WindowsImage.ps1

.EXAMPLE
    .\Update-WindowsImage.ps1 -WindowsVersion 25H2 -SkipDrivers
#>
[CmdletBinding()]
param(
    [string]   $SourceIso,
    [string]   $WindowsVersion,
    [string]   $ScratchRoot = 'C:\VentoyBuild',
    [string]   $DriverPath,
    [int[]]    $ImageIndex,
    [string]   $OutputDir,
    [string]   $IsoPrefix = 'WIN11_UPD',
    [switch]   $SkipUpdates,
    [switch]   $SkipDrivers,
    [switch]   $SkipDotNet,
    [switch]   $KeepScratch,
    # Reaproveita a ISO ja extraida e os .msu ja baixados em ScratchRoot.
    # Numa nova tentativa isso poupa ~10 GB de download e a extracao inteira.
    [switch]   $ReuseScratch
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib\Common.ps1"
. "$PSScriptRoot\lib\MsCatalog.ps1"

$SsdRoot = Split-Path $PSScriptRoot -Parent
if (-not $DriverPath) { $DriverPath = Join-Path $SsdRoot 'Drivers\_Critical' }
if (-not $OutputDir)  { $OutputDir  = Join-Path $SsdRoot 'ISO' }

# ------------------------------------------------------------------ pre-voo
function Resolve-Oscdimg {
    $candidatos = @(
        (Join-Path $PSScriptRoot 'bin\oscdimg.exe'),
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    foreach ($c in $candidatos) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    throw @"
oscdimg.exe nao encontrado - sem ele nao da para remontar a ISO.

Como resolver (uma vez so):
  1. Instale o Windows ADK marcando apenas "Deployment Tools", ou
  2. Copie oscdimg.exe de uma maquina que ja tenha o ADK para:
     $(Join-Path $PSScriptRoot 'bin\oscdimg.exe')

Caminho de origem tipico:
  C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\
"@
}

function Find-SourceIso {
    param([string]$Raiz)
    $busca = @((Join-Path $Raiz 'ISO'), $Raiz) | Where-Object { Test-Path $_ }
    $isos = foreach ($b in $busca) {
        Get-ChildItem $b -Filter *.iso -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Win(dows)?[ _]?1[01]' }
    }
    $escolhida = $isos | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $escolhida) { throw "Nenhuma ISO de Windows encontrada em $Raiz. Use -SourceIso." }
    return $escolhida.FullName
}

function Invoke-Dism {
    param([Parameter(Mandatory)][string[]]$Argumentos, [switch]$Tolerante)
    $saida = & dism.exe @Argumentos 2>&1
    $code  = $LASTEXITCODE
    if ($code -ne 0 -and -not $Tolerante) {
        $saida | Select-Object -Last 15 | ForEach-Object { Write-Log $_ 'ERRO' }
        throw "DISM falhou (codigo $code): dism $($Argumentos -join ' ')"
    }
    [pscustomobject]@{ Code = $code; Saida = $saida }
}

<#
    Aplica os .msu em laco com retentativa. Isso resolve sozinho a ordem exigida
    pelo checkpoint update do 24H2 sem precisar codificar qual KB vem antes.
#>
function Add-PacotesComRetentativa {
    param([Parameter(Mandatory)][string]$MountDir, [Parameter(Mandatory)][string[]]$Pacotes)

    $pendentes  = [System.Collections.ArrayList]@($Pacotes)
    $aplicados  = 0
    $rodada     = 0

    while ($pendentes.Count -gt 0) {
        $rodada++
        $aplicadosNaRodada = 0
        $motivos = @{}

        foreach ($p in @($pendentes)) {
            $nome = Split-Path $p -Leaf
            Write-Log "  [rodada $rodada] $nome" 'INFO'
            $r = Invoke-Dism -Tolerante -Argumentos @(
                "/Image:$MountDir", '/Add-Package', "/PackagePath:$p", '/NoRestart'
            )
            if ($r.Code -eq 0 -or $r.Code -eq 3010) {
                Write-Log "  aplicado: $nome" 'OK'
                [void]$pendentes.Remove($p)
                $aplicadosNaRodada++
                $aplicados++
            } else {
                $motivos[$nome] = $r.Code
            }
        }

        # Sem progresso numa rodada significa que o que sobrou nao vai entrar.
        # Isso e NORMAL e nao e erro: o LCU mais recente ja contem o checkpoint,
        # entao o DISM marca o checkpoint como "Superseded" e recusa. Tratar isso
        # como falha fatal descartaria uma imagem que ficou correta - foi o que
        # aconteceu em 05/09/2026, jogando fora 40 min de servicing bem-sucedido.
        if ($aplicadosNaRodada -eq 0) {
            foreach ($n in $motivos.Keys) {
                Write-Log ("  dispensado (ja coberto ou nao aplicavel): {0} [codigo {1}]" -f $n, $motivos[$n]) 'WARN'
            }
            break
        }
    }

    if ($aplicados -eq 0) {
        throw "Nenhum pacote pode ser aplicado a esta imagem - abortando para nao gerar ISO sem update."
    }
    Write-Log "$aplicados de $($Pacotes.Count) pacote(s) aplicados." 'OK'
}

# --------------------------------------------------------------------- main
Assert-Admin
Write-Log '=== Update-WindowsImage ===' 'STEP'

$oscdimg = Resolve-Oscdimg
Write-Log "oscdimg: $oscdimg" 'OK'

if (-not $SourceIso) { $SourceIso = Find-SourceIso -Raiz $SsdRoot }
if (-not (Test-Path $SourceIso)) { throw "ISO nao encontrada: $SourceIso" }
Write-Log "ISO de origem: $SourceIso" 'INFO'

if (-not $WindowsVersion) {
    $m = [regex]::Match((Split-Path $SourceIso -Leaf), '(2[0-9]H[12])')
    $WindowsVersion = if ($m.Success) { $m.Groups[1].Value } else { '24H2' }
    Write-Log "Versao deduzida do nome da ISO: $WindowsVersion" 'INFO'
}

$livreGB = [math]::Round((Get-PSDrive (Split-Path $ScratchRoot -Qualifier).TrimEnd(':')).Free / 1GB, 1)
if ($livreGB -lt 40) { throw "Espaco insuficiente em $ScratchRoot ($livreGB GB livres; precisa de ~40 GB)." }
$fsScratch = (Get-Volume -DriveLetter (Split-Path $ScratchRoot -Qualifier).TrimEnd(':')[0]).FileSystem
if ($fsScratch -ne 'NTFS') { throw "ScratchRoot precisa estar em NTFS (atual: $fsScratch). O DISM nao monta imagem em exFAT." }

$dirIso   = Join-Path $ScratchRoot 'iso'
$dirMount = Join-Path $ScratchRoot 'mount'
$dirMsu   = Join-Path $ScratchRoot 'msu'
$installWim = Join-Path $dirIso 'sources\install.wim'
$bootWim    = Join-Path $dirIso 'sources\boot.wim'

# O mount SEMPRE comeca limpo: sobra de montagem anterior corrompe o servicing.
if (Test-Path $dirMount) { Remove-Item $dirMount -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $dirMount -Force | Out-Null
if (-not (Test-Path $dirMsu)) { New-Item -ItemType Directory -Path $dirMsu -Force | Out-Null }

$podeReusar = $ReuseScratch -and (Test-Path $installWim)

if ($podeReusar) {
    Write-Log "Reaproveitando ISO ja extraida em $dirIso" 'OK'
    # A extracao anterior pode ter parado no meio; conferimos o essencial.
    foreach ($obrig in $installWim, (Join-Path $dirIso 'sources\boot.wim'),
                       (Join-Path $dirIso 'boot\etfsboot.com'),
                       (Join-Path $dirIso 'efi\microsoft\boot\efisys.bin')) {
        if (-not (Test-Path $obrig)) { throw "Scratch reaproveitado esta incompleto: falta $obrig. Rode sem -ReuseScratch." }
    }
} else {
    if (Test-Path $dirIso) { Remove-Item $dirIso -Recurse -Force }
    New-Item -ItemType Directory -Path $dirIso -Force | Out-Null

    # ------------------------------------------------ 1. extrair a ISO origem
    Write-Log 'Montando ISO de origem...' 'STEP'
    $mnt = Mount-DiskImage -ImagePath $SourceIso -PassThru
    try {
        $letra = ($mnt | Get-Volume).DriveLetter
        Write-Log "Copiando conteudo de ${letra}: para $dirIso ..." 'INFO'
        & robocopy "${letra}:\" $dirIso /E /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy falhou (codigo $LASTEXITCODE)." }
        $global:LASTEXITCODE = 0
    } finally {
        Dismount-DiskImage -ImagePath $SourceIso | Out-Null
    }
    Get-ChildItem $dirIso -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
}
if (-not (Test-Path $installWim)) {
    if (Test-Path (Join-Path $dirIso 'sources\install.esd')) {
        throw 'Esta ISO usa install.esd (comprimido, somente leitura). Baixe a ISO empresarial/MVS com install.wim.'
    }
    throw "install.wim nao encontrado em $dirIso\sources."
}

# ------------------------------------------------------ 2. baixar os pacotes
$pacotes = @()
if (-not $SkipUpdates) {
    Write-Log "Consultando LCU mais recente para Windows 11 $WindowsVersion ..." 'STEP'
    $lcu = Get-LatestCumulativeUpdate -Version $WindowsVersion
    Write-Log $lcu.Titulo 'INFO'
    foreach ($u in Get-CatalogFileUrl -UpdateID $lcu.UpdateID) {
        $pacotes += Get-RemoteFile -Uri $u -OutFile (Join-Path $dirMsu (Split-Path $u -Leaf))
    }

    if (-not $SkipDotNet) {
        $dn = Get-LatestDotNetUpdate -Version $WindowsVersion
        if ($dn) {
            Write-Log $dn.Titulo 'INFO'
            foreach ($u in Get-CatalogFileUrl -UpdateID $dn.UpdateID) {
                $pacotes += Get-RemoteFile -Uri $u -OutFile (Join-Path $dirMsu (Split-Path $u -Leaf))
            }
        }
    }
}

$temDrivers = (-not $SkipDrivers) -and (Test-Path $DriverPath) -and
              @(Get-ChildItem $DriverPath -Filter *.inf -Recurse -ErrorAction SilentlyContinue).Count -gt 0
if (-not $SkipDrivers -and -not $temDrivers) {
    Write-Log "Sem drivers em $DriverPath - rode New-CriticalDriverSet.ps1 antes. Seguindo sem injetar." 'WARN'
}

# --------------------------------------------------- 3. definir quais indices
$indices = Get-WindowsImage -ImagePath $installWim
Write-Log '--- Edicoes na imagem ---' 'STEP'
$indices | Format-Table ImageIndex, ImageName -AutoSize | Out-String | Write-Host

$alvos = if ($ImageIndex -and $ImageIndex -notcontains 0) {
    $ImageIndex
} elseif ($ImageIndex -contains 0) {
    $indices.ImageIndex
} else {
    $pro = $indices | Where-Object { $_.ImageName -match 'Pro' -and $_.ImageName -notmatch 'Education|Workstation|N$' }
    if ($pro) { @($pro.ImageIndex) } else { @($indices[0].ImageIndex) }
}
Write-Log "Indices a processar: $($alvos -join ', ')" 'INFO'

# ------------------------------------------------------- 4. servicing do WIM
function Update-Wim {
    param([string]$Wim, [int]$Indice, [switch]$AplicarPacotes, [switch]$ResetBase)

    Write-Log "Montando $(Split-Path $Wim -Leaf) indice $Indice ..." 'STEP'
    Invoke-Dism -Argumentos @('/Mount-Image', "/ImageFile:$Wim", "/Index:$Indice", "/MountDir:$dirMount") | Out-Null

    try {
        if ($AplicarPacotes -and $pacotes.Count -gt 0) {
            Write-Log "Aplicando $($pacotes.Count) pacote(s)..." 'STEP'
            Add-PacotesComRetentativa -MountDir $dirMount -Pacotes $pacotes
        }

        if ($temDrivers) {
            Write-Log "Injetando drivers de $DriverPath ..." 'STEP'
            Invoke-Dism -Argumentos @(
                "/Image:$dirMount", '/Add-Driver', "/Driver:$DriverPath", '/Recurse', '/ForceUnsigned'
            ) | Out-Null
            Write-Log 'Drivers injetados.' 'OK'
        }

        if ($ResetBase) {
            Write-Log 'Compactando (StartComponentCleanup /ResetBase)...' 'STEP'
            Invoke-Dism -Tolerante -Argumentos @(
                "/Image:$dirMount", '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase'
            ) | Out-Null
        }
    } catch {
        Write-Log "Erro no servicing - descartando alteracoes desta imagem." 'ERRO'
        Invoke-Dism -Tolerante -Argumentos @('/Unmount-Image', "/MountDir:$dirMount", '/Discard') | Out-Null
        throw
    }

    Write-Log 'Gravando alteracoes (commit)...' 'STEP'
    Invoke-Dism -Argumentos @('/Unmount-Image', "/MountDir:$dirMount", '/Commit') | Out-Null
    Write-Log "Indice $Indice concluido." 'OK'
}

foreach ($i in $alvos) {
    Update-Wim -Wim $installWim -Indice $i -AplicarPacotes -ResetBase
}

# boot.wim indice 2 = ambiente do Setup. So drivers: e o que faz o disco e a
# rede aparecerem durante a instalacao. Aplicar LCU aqui incha sem ganho real.
if ($temDrivers -and (Test-Path $bootWim)) {
    Update-Wim -Wim $bootWim -Indice 2
}

# ---------------------------------------------------------- 5. remontar a ISO
$rotulo  = "${IsoPrefix}_${WindowsVersion}_$(Get-Date -Format 'yyyyMM')"
$destIso = Join-Path $OutputDir "$rotulo.iso"
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
if (Test-Path $destIso) { Remove-Item $destIso -Force }

Write-Log "Gerando ISO: $destIso" 'STEP'
$etfs = Join-Path $dirIso 'boot\etfsboot.com'
$efi  = Join-Path $dirIso 'efi\microsoft\boot\efisys.bin'
foreach ($b in $etfs, $efi) {
    if (-not (Test-Path $b)) { throw "Arquivo de boot ausente na ISO extraida: $b" }
}

# O -bootdata carrega aspas internas. Passar isso como array de argumentos faz o
# PowerShell reescrever as aspas e o oscdimg recebe lixo; por isso montamos a
# linha de comando inteira como string e deixamos o Start-Process repassa-la
# intacta ao CreateProcess.
$bootData = '2#p0,e,b"{0}"#pEF,e,b"{1}"' -f $etfs, $efi
$linha    = '-m -o -u2 -udfver102 -bootdata:{0} -l{1} "{2}" "{3}"' -f $bootData, $rotulo, $dirIso, $destIso

Write-Log "oscdimg $linha" 'INFO'
$proc = Start-Process -FilePath $oscdimg -ArgumentList $linha -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) { throw "oscdimg falhou (codigo $($proc.ExitCode))." }
if (-not (Test-Path $destIso)) { throw "oscdimg terminou sem erro mas a ISO nao foi criada." }

$tamGB = [math]::Round((Get-Item $destIso).Length / 1GB, 2)
Write-Log "ISO gerada: $destIso ($tamGB GB)" 'OK'

if (-not $KeepScratch) {
    Write-Log 'Limpando pasta de trabalho...' 'INFO'
    Remove-Item $ScratchRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Log '=== Concluido ===' 'OK'
Write-Log "Proximo passo: conferir o menu em $SsdRoot\ventoy\ventoy.json" 'INFO'
