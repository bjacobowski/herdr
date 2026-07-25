param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    [string]$Session = "ci-windows-$([guid]::NewGuid().ToString('N'))",
    [string]$RuntimeDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments, [string]$Context)
    $output = & $Exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$Context failed with exit code $LASTEXITCODE`: $($output -join "`n")"
    }
    return $output
}

function Normalize-Path {
    param([string]$Path)
    return ([IO.Path]::GetFullPath($Path) -replace '^\\\\\?\\', '').TrimEnd('\')
}

function Wait-ForServer {
    param([string]$Exe)
    $deadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 250
        $status = & $Exe status server 2>&1
        if ($LASTEXITCODE -eq 0 -and (($status -join "`n") -match "status: running")) {
            return
        }
    } while ((Get-Date) -lt $deadline)
    throw "server did not become ready: $($status -join "`n")"
}

function Invoke-PaneCase {
    param(
        [string]$Name,
        [string]$Exe,
        [string]$CaseSession,
        [bool]$ExpectAppLocal
    )

    $env:HERDR_SESSION = $CaseSession
    $server = $null
    try {
        $server = Start-Process -FilePath $Exe -ArgumentList "server" -PassThru -WindowStyle Hidden
        Wait-ForServer -Exe $Exe

        $created = Invoke-Checked -Exe $Exe `
            -Arguments @("workspace", "create", "--cwd", $PWD.Path) `
            -Context "$Name workspace creation"
        $paneId = [string](($created -join "`n" | ConvertFrom-Json).result.root_pane.pane_id)
        $marker = "HERDR_CONPTY_$($Name.ToUpperInvariant())"
        Invoke-Checked -Exe $Exe -Arguments @("pane", "run", $paneId, "echo $marker") `
            -Context "$Name pane command" | Out-Null

        $deadline = (Get-Date).AddSeconds(15)
        do {
            Start-Sleep -Milliseconds 250
            $text = (& $Exe pane read $paneId --source recent-unwrapped --lines 40 --format text 2>&1) -join "`n"
        } while ((Get-Date) -lt $deadline -and ($text -replace '\s', '') -notmatch $marker)
        if (($text -replace '\s', '') -notmatch $marker) {
            throw "$Name pane did not produce $marker`: $text"
        }

        $modules = @(Get-Process -Id $server.Id -Module |
            Where-Object { $_.ModuleName -ieq "conpty.dll" })
        if ($ExpectAppLocal) {
            $expectedDll = Normalize-Path (Join-Path (Split-Path -Parent $Exe) "conpty.dll")
            if ($modules.Count -ne 1 -or
                (Normalize-Path $modules[0].FileName) -ine $expectedDll) {
                throw "$Name did not load $expectedDll`: $($modules.FileName -join ', ')"
            }

            $expectedHost = Normalize-Path (Join-Path (Split-Path -Parent $Exe) "OpenConsole.exe")
            $hosts = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($server.Id) AND Name = 'OpenConsole.exe'" |
                Where-Object { (Normalize-Path $_.ExecutablePath) -ieq $expectedHost })
            if ($hosts.Count -lt 1) {
                throw "$Name did not spawn $expectedHost"
            }
        } elseif ($modules.Count -ne 0) {
            throw "$Name loaded an unexpected conpty.dll: $($modules.FileName -join ', ')"
        }

        Invoke-Checked -Exe $Exe `
            -Arguments @("pane", "split", $paneId, "--direction", "right", "--ratio", "0.5", "--no-focus") `
            -Context "$Name split" | Out-Null
        Invoke-Checked -Exe $Exe `
            -Arguments @("pane", "resize", "--pane", $paneId, "--direction", "right", "--amount", "0.05") `
            -Context "$Name resize" | Out-Null
        Invoke-Checked -Exe $Exe -Arguments @("pane", "close", $paneId) `
            -Context "$Name pane close" | Out-Null

        $server.Refresh()
        if ($server.HasExited) {
            throw "$Name server exited unexpectedly with code $($server.ExitCode)"
        }
    } finally {
        if ($null -ne $server -and -not $server.HasExited) {
            & $Exe server stop *> $null
            Wait-Process -Id $server.Id -Timeout 10 -ErrorAction SilentlyContinue
        }
        $global:LASTEXITCODE = 0
    }
    Write-Host "passed ConPTY smoke case: $Name"
}

$exe = (Resolve-Path $ExePath).Path
$runtime = if ([string]::IsNullOrWhiteSpace($RuntimeDir)) {
    ""
} else {
    (Resolve-Path $RuntimeDir).Path
}
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "herdr-conpty-smoke-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null

$originalPath = $env:PATH
$savedEnvironment = @{}
foreach ($name in @("HERDR_SESSION", "HERDR_SOCKET_PATH", "HERDR_CLIENT_SOCKET_PATH")) {
    $savedEnvironment[$name] = Get-Item "Env:$name" -ErrorAction SilentlyContinue
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}

try {
    $pathTrap = Join-Path $fixtureRoot "path-trap"
    New-Item -ItemType Directory -Force -Path $pathTrap | Out-Null
    Set-Content -NoNewline -Encoding ascii -LiteralPath (Join-Path $pathTrap "conpty.dll") `
        -Value "must not load through PATH"
    $env:PATH = "$pathTrap;$originalPath"
    Invoke-PaneCase -Name "system" -Exe $exe -CaseSession "$Session-system" -ExpectAppLocal $false

    $partialRoot = Join-Path $fixtureRoot "partial"
    New-Item -ItemType Directory -Force -Path $partialRoot | Out-Null
    $partialExe = Join-Path $partialRoot "herdr.exe"
    Copy-Item -LiteralPath $exe -Destination $partialExe
    Copy-Item -LiteralPath (Join-Path $pathTrap "conpty.dll") -Destination $partialRoot
    Invoke-Checked -Exe $partialExe -Arguments @("--version") `
        -Context "partial pair version" | Out-Null

    $env:HERDR_SESSION = "$Session-partial"
    foreach ($mode in @(
        @{ Name = "server"; Arguments = @("server") },
        @{ Name = "monolithic"; Arguments = @("--no-session") }
    )) {
        $partialStdout = Join-Path $partialRoot "$($mode.Name).stdout.txt"
        $partialStderr = Join-Path $partialRoot "$($mode.Name).stderr.txt"
        $partialProcess = Start-Process -FilePath $partialExe -ArgumentList $mode.Arguments `
            -RedirectStandardOutput $partialStdout -RedirectStandardError $partialStderr `
            -PassThru -WindowStyle Hidden
        if (-not $partialProcess.WaitForExit(10000)) {
            Stop-Process -Id $partialProcess.Id -Force -ErrorAction SilentlyContinue
            throw "partial-pair $($mode.Name) did not reject the incomplete runtime"
        }
        $partialOutput = @(
            Get-Content -LiteralPath $partialStdout -ErrorAction SilentlyContinue
            Get-Content -LiteralPath $partialStderr -ErrorAction SilentlyContinue
        ) -join "`n"
        if ($partialProcess.ExitCode -eq 0 -or $partialOutput -notmatch "missing .*OpenConsole\.exe") {
            throw "partial app-local runtime did not fail cleanly in $($mode.Name): $partialOutput"
        }
    }
    $global:LASTEXITCODE = 0
    Write-Host "passed ConPTY smoke case: partial pair"

    if (-not [string]::IsNullOrWhiteSpace($runtime)) {
        foreach ($name in @("conpty.dll", "OpenConsole.exe")) {
            if (-not (Test-Path -LiteralPath (Join-Path $runtime $name) -PathType Leaf)) {
                throw "runtime is missing $name`: $runtime"
            }
        }
        $appRoot = Join-Path $fixtureRoot "app-local"
        New-Item -ItemType Directory -Force -Path $appRoot | Out-Null
        Copy-Item -LiteralPath $exe -Destination (Join-Path $appRoot "herdr.exe")
        Copy-Item -LiteralPath (Join-Path $runtime "conpty.dll") -Destination $appRoot
        Copy-Item -LiteralPath (Join-Path $runtime "OpenConsole.exe") -Destination $appRoot
        Invoke-PaneCase -Name "app-local" -Exe (Join-Path $appRoot "herdr.exe") `
            -CaseSession "$Session-app-local" -ExpectAppLocal $true
    } else {
        Write-Host "app-local qualification requires -RuntimeDir with a matched Microsoft pair"
    }
} finally {
    $env:PATH = $originalPath
    foreach ($name in $savedEnvironment.Keys) {
        if ($null -eq $savedEnvironment[$name]) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item "Env:$name" -Value $savedEnvironment[$name].Value
        }
    }
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}
