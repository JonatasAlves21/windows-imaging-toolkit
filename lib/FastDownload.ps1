<#
    FastDownload.ps1 - Download por faixas (HTTP Range) em paralelo.

    POR QUE ISSO EXISTE
    Medido em 04/09/2026 numa rede corporativa:
        downloads.dell.com, 1 conexao .... 182 KB/s
        downloads.dell.com, 6 conexoes ... 11.904 KB/s  (65x)
        download.microsoft.com, 1 conexao . 7.357 KB/s

    Ou seja: a Dell (ou o proxy no caminho) limita por CONEXAO, nao por banda.
    Baixar o pack de 3,4 GB em fluxo unico levaria mais de 5 horas; em 6 faixas
    paralelas leva poucos minutos.

    Implementado com RunspacePool em vez de Start-ThreadJob/ForEach-Object -Parallel
    para funcionar tanto no PowerShell 5.1 quanto no 7.
#>

function Get-RemoteFileFast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$ExpectedHash,
        [ValidateSet('MD5', 'SHA256')][string]$Algorithm = 'MD5',
        [ValidateRange(1, 16)][int]$Connections = 6,
        [switch]$Force
    )

    $dir = Split-Path $OutFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $nome = Split-Path $OutFile -Leaf

    if ((Test-Path $OutFile) -and -not $Force) {
        if (-not $ExpectedHash) {
            Write-Log "Ja existe (sem hash para conferir): $nome" 'OK'
            return $OutFile
        }
        if ((Get-FileHash $OutFile -Algorithm $Algorithm).Hash -ieq $ExpectedHash) {
            Write-Log "Ja existe e o hash confere: $nome" 'OK'
            return $OutFile
        }
        Write-Log 'Hash divergente no arquivo existente. Rebaixando.' 'WARN'
    }

    # --- descobrir tamanho e se o servidor aceita Range
    $tamanho = 0
    $aceitaRange = $false
    try {
        $head = [System.Net.HttpWebRequest]::Create($Uri)
        $head.Method = 'HEAD'
        $head.UserAgent = 'Mozilla/5.0'
        $head.Timeout = 60000
        $resp = $head.GetResponse()
        $tamanho = [int64]$resp.ContentLength
        $aceitaRange = ($resp.Headers['Accept-Ranges'] -eq 'bytes')
        $resp.Close()
    } catch {
        Write-Log "HEAD falhou ($($_.Exception.Message)) - caindo para fluxo unico." 'WARN'
    }

    if (-not $aceitaRange -or $tamanho -le 8MB -or $Connections -eq 1) {
        Write-Log "Baixando $nome em fluxo unico..." 'STEP'
        return Get-RemoteFileSimple -Uri $Uri -OutFile $OutFile -ExpectedHash $ExpectedHash -Algorithm $Algorithm
    }

    Write-Log ("Baixando $nome ({0} MB) em $Connections faixas paralelas..." -f [math]::Round($tamanho/1MB,0)) 'STEP'
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("dl_" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $tamFaixa = [math]::Ceiling($tamanho / $Connections)
    $trabalho = @()
    for ($i = 0; $i -lt $Connections; $i++) {
        $ini = [int64]($i * $tamFaixa)
        $fim = [int64][Math]::Min($ini + $tamFaixa - 1, $tamanho - 1)
        if ($ini -gt $fim) { continue }
        $trabalho += [pscustomobject]@{
            Indice = $i
            Inicio = $ini
            Fim    = $fim
            Parte  = Join-Path $tempDir ("parte{0:D2}" -f $i)
        }
    }

    $codigo = {
        param($Uri, $Inicio, $Fim, $Parte)

        # Runspace novo nao herda estas configuracoes do processo principal.
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        [System.Net.ServicePointManager]::DefaultConnectionLimit = 64
        [System.Net.ServicePointManager]::Expect100Continue = $false

        $esperado = $Fim - $Inicio + 1
        $ultimoErro = 'sem detalhe'

        for ($tentativa = 1; $tentativa -le 3; $tentativa++) {
            $fs = $null; $resp = $null
            try {
                $req = [System.Net.HttpWebRequest]::Create($Uri)
                $req.UserAgent = 'Mozilla/5.0'
                $req.Timeout = 120000
                # O corpo pode levar muito tempo: sem limite de leitura.
                $req.ReadWriteTimeout = [int]::MaxValue
                $req.KeepAlive = $true
                $req.AllowAutoRedirect = $true
                $req.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
                $req.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
                $req.AddRange($Inicio, $Fim)

                $resp = $req.GetResponse()
                $fs = [System.IO.File]::Create($Parte)
                $resp.GetResponseStream().CopyTo($fs, 1MB)
                $fs.Close(); $fs = $null
                $resp.Close(); $resp = $null

                $obtido = (Get-Item $Parte).Length
                if ($obtido -eq $esperado) {
                    return @{ Ok = $true; Bytes = $obtido; Erro = $null }
                }
                $ultimoErro = "recebeu $obtido bytes, esperava $esperado"
            } catch {
                $ultimoErro = $_.Exception.Message
                if ($_.Exception.InnerException) {
                    $ultimoErro += ' >> ' + $_.Exception.InnerException.Message
                }
            } finally {
                if ($fs)   { $fs.Close() }
                if ($resp) { $resp.Close() }
            }
            Start-Sleep -Seconds (2 * $tentativa)
        }
        return @{ Ok = $false; Bytes = 0; Erro = $ultimoErro }
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $Connections)
    $pool.Open()
    $pendentes = @()
    try {
        foreach ($t in $trabalho) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($codigo).AddArgument($Uri).AddArgument($t.Inicio).AddArgument($t.Fim).AddArgument($t.Parte)
            $pendentes += [pscustomobject]@{ Ps = $ps; Handle = $ps.BeginInvoke(); Trabalho = $t }
        }

        $falhou = $false
        foreach ($p in $pendentes) {
            $r = $p.Ps.EndInvoke($p.Handle)
            $p.Ps.Dispose()
            if (-not ($r -and $r[0].Ok)) {
                $motivo = if ($r -and $r[0].Erro) { $r[0].Erro } else { 'runspace nao retornou resultado' }
                Write-Log "Faixa $($p.Trabalho.Indice) falhou: $motivo" 'WARN'
                $falhou = $true
            }
        }
    } finally {
        $pool.Close(); $pool.Dispose()
    }

    if ($falhou) {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log 'Download paralelo incompleto - refazendo em fluxo unico.' 'WARN'
        return Get-RemoteFileSimple -Uri $Uri -OutFile $OutFile -ExpectedHash $ExpectedHash -Algorithm $Algorithm
    }

    # --- juntar as faixas na ordem
    $destinoTmp = "$OutFile.part"
    $out = [System.IO.File]::Create($destinoTmp)
    try {
        foreach ($t in ($trabalho | Sort-Object Indice)) {
            $in = [System.IO.File]::OpenRead($t.Parte)
            $in.CopyTo($out, 1MB)
            $in.Close()
        }
    } finally {
        $out.Close()
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $sw.Stop()
    $mb = (Get-Item $destinoTmp).Length / 1MB
    Write-Log ("{0} MB em {1:mm\:ss} ({2} MB/s)" -f [math]::Round($mb,1), $sw.Elapsed,
               [math]::Round($mb/[Math]::Max($sw.Elapsed.TotalSeconds,1),1)) 'OK'

    if ($ExpectedHash) {
        $h = (Get-FileHash $destinoTmp -Algorithm $Algorithm).Hash
        if ($h -ine $ExpectedHash) {
            Remove-Item $destinoTmp -Force -ErrorAction SilentlyContinue
            throw "Hash $Algorithm nao confere para $Uri (esperado $ExpectedHash, obtido $h)."
        }
        Write-Log "Hash $Algorithm conferido." 'OK'
    }

    Move-Item $destinoTmp $OutFile -Force
    return $OutFile
}

function Get-RemoteFileSimple {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$ExpectedHash,
        [string]$Algorithm = 'MD5'
    )
    $tmp = "$OutFile.part"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
        $wc.DownloadFile($Uri, $tmp)
        $wc.Dispose()
    } catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        throw "Falha ao baixar $Uri :: $($_.Exception.Message)"
    }
    $sw.Stop()
    $mb = (Get-Item $tmp).Length / 1MB
    Write-Log ("{0} MB em {1:mm\:ss} ({2} MB/s)" -f [math]::Round($mb,1), $sw.Elapsed,
               [math]::Round($mb/[Math]::Max($sw.Elapsed.TotalSeconds,1),1)) 'OK'

    if ($ExpectedHash) {
        $h = (Get-FileHash $tmp -Algorithm $Algorithm).Hash
        if ($h -ine $ExpectedHash) {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            throw "Hash $Algorithm nao confere para $Uri."
        }
    }
    Move-Item $tmp $OutFile -Force
    return $OutFile
}
