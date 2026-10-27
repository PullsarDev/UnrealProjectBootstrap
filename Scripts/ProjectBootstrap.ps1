#requires -Version 5.1
<#
Explorer entry point: ..\OpenProject.bat
-Diagnose: inspect only; no downloads, installation, build or launch.
-NoLaunch: build without opening the Editor. -NonInteractive: never prompt/install.
Dot-sourcing defines functions only, for isolated tests without system changes.
#>
[CmdletBinding()]
param(
    [switch]$Diagnose,
    [switch]$NoLaunch,
    [switch]$NonInteractive,
    [string]$EnginePath,
    [string]$ProjectPath,
    [string]$EditorTarget
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Stop-Bootstrap([int]$Code, [string]$Message) {
    $errorRecord = New-Object System.Exception($Message)
    $errorRecord.Data['BootstrapCode'] = $Code
    throw $errorRecord
}

function Get-VSInstances {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return }
    # Windows PowerShell otherwise decodes UTF-8 native output using the console
    # code page, corrupting installation paths containing non-ASCII characters.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $vswhere
    $start.Arguments = '-all -products * -format json -utf8'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $errorText = $process.StandardError.ReadToEndAsync()
        $json = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { Stop-Bootstrap 30 "Visual Studio discovery failed: $($errorText.Result). Repair Visual Studio Installer and retry." }
    } finally { $process.Dispose() }
    # -all is intentional: a partial VS installation may still contain a usable compiler.
    @($json | ConvertFrom-Json) | Where-Object {
        $_.isPrerelease -ne $true -and [version]$_.installationVersion -ge [version]'17.0' -and
        [version]$_.installationVersion -lt [version]'19.0'
    }
}

function Test-VersionRange([version]$Version, [string]$Range) {
    $bounds = $Range.Split('-')
    $Version -ge [version]$bounds[0] -and $Version -le [version]$bounds[1]
}

function Get-WindowsSDK {
    $roots = @('HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots')
    foreach ($key in $roots) {
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if (-not $item -or -not $item.PSObject.Properties['KitsRoot10']) { continue }
        $sdkRoot = $item.KitsRoot10
        foreach ($folder in @(Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Include') -Directory -ErrorAction SilentlyContinue)) {
            if ($folder.Name -notmatch '^10\.0\.\d+\.0$') { continue }
            $complete = $true
            foreach ($file in @("Include\$($folder.Name)\um\Windows.h", "Include\$($folder.Name)\shared\sdkddkver.h",
                "Include\$($folder.Name)\ucrt\stdio.h", "Lib\$($folder.Name)\um\x64\kernel32.lib",
                "Lib\$($folder.Name)\ucrt\x64\ucrt.lib", "bin\$($folder.Name)\x64\rc.exe", "bin\$($folder.Name)\x64\mt.exe")) {
                if (-not (Test-Path -LiteralPath (Join-Path $sdkRoot $file))) { $complete = $false }
            }
            if ($complete) { [pscustomobject]@{ Root = $sdkRoot; Version = $folder.Name } }
        }
    }
}

function Confirm-Installation($Plan) {
    Write-Host ''
    if ($Plan.Existing) { Write-Host "Add missing components to Visual Studio 2022: $($Plan.Path)" }
    else { Write-Host 'Install standalone Microsoft Visual Studio 2022 Build Tools (no full IDE).' }
    if ($Plan.Update) { Write-Host 'This also updates this Visual Studio 2022 installation to the latest servicing release to support the required components.' }
    Write-Host "Components: $($Plan.Components -join ', ')"
    Write-Host 'Microsoft downloads require internet, several GB of free disk space and administrator approval.'
    Write-Host 'Progress is shown by Microsoft Installer. A reboot may be required; no automatic reboot is requested.'
    (Read-Host 'Install these prerequisites? Type YES to continue') -ceq 'YES'
}

function Get-MicrosoftBootstrapper([string]$Edition, [string]$Directory) {
    $destination = Join-Path $Directory "vs_$Edition.exe"
    $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_$Edition.exe" -OutFile $destination -UseBasicParsing
    } finally { [Net.ServicePointManager]::SecurityProtocol = $oldProtocol }
    $signature = Get-AuthenticodeSignature -LiteralPath $destination
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
        Stop-Bootstrap 32 'Microsoft installer signature validation failed. No installer was run. Check Windows date, certificates and network access.'
    }
    $destination
}

function Invoke-Installer([string]$File, [string[]]$Arguments) {
    try {
        # Only the signed Microsoft bootstrapper is elevated; project builds stay unelevated.
        $process = Start-Process -FilePath $File -ArgumentList ($Arguments -join ' ') -Verb RunAs -Wait -PassThru -WorkingDirectory (Split-Path $File)
        [int]$process.ExitCode
    } catch {
        $exception = $_.Exception
        while ($exception) {
            if ($exception.PSObject.Properties['NativeErrorCode'] -and $exception.NativeErrorCode -eq 1223) { return 1223 }
            $exception = $exception.InnerException
        }
        throw
    }
}

function Assert-InstallerExit([int]$Code) {
    switch ($Code) {
        0 { return }
        { $_ -in 3010, 1641 } { Stop-Bootstrap 31 "Microsoft Installer returned $Code (restart required). Save your work, restart Windows, then run OpenProject.bat again." }
        { $_ -in 1602, 1223, 5004 } { Stop-Bootstrap 33 "Installation or administrator approval was canceled (Microsoft code $Code). Run OpenProject.bat again when ready." }
        1618 { Stop-Bootstrap 32 'Another installer is running (1618). Let it finish, then retry.' }
        default { Stop-Bootstrap 32 "Microsoft Installer failed (code $Code). See Microsoft dd_* logs in your Windows TEMP folder, or open Visual Studio Installer to repair the installation." }
    }
}

function Install-Prerequisites($Prerequisites, $Engine, [string]$LogDirectory) {
    $plan = Get-InstallPlan $Prerequisites
    if (-not (Confirm-Installation $plan)) { Stop-Bootstrap 33 'Installation declined. No system software was changed.' }
    $installer = Get-MicrosoftBootstrapper $plan.Edition $LogDirectory
    $common = @('--passive', '--wait', '--norestart')
    if ($plan.Existing) { $common += @('--installPath', ('"' + $plan.Path + '"')) }
    if ($plan.Update) { Assert-InstallerExit (Invoke-Installer $installer (@('update') + $common)) }
    $arguments = $common
    if ($plan.Existing) { $arguments = @('modify') + $arguments }
    foreach ($component in $plan.Components) { $arguments += @('--add', $component) }
    Assert-InstallerExit (Invoke-Installer $installer $arguments)
    $verified = Get-Prerequisites $Engine
    if (-not $verified.Ready) { Stop-Bootstrap 32 'Installer completed but the required compiler/SDK is still missing. Restart Windows if requested, then repair the listed components in Visual Studio Installer.' }
    $verified
}

function Get-EditorProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name LIKE 'UnrealEditor%.exe'" -ErrorAction Stop)
}

function Assert-EditorClosed($Project, [object[]]$Processes) {
    foreach ($process in $Processes) {
        # An inaccessible command line cannot be proven safe: ask for a normal close.
        if (-not $process.CommandLine -or $process.CommandLine.Replace('/', '\').IndexOf($Project.File, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $process.CommandLine -match ('(?i)(?:^|[\s"/\\])' + [regex]::Escape([IO.Path]::GetFileName($Project.File)) + '(?:["\s]|$)')) {
            Stop-Bootstrap 40 "Unreal Editor may have this project open (PID $($process.ProcessId)). Save your work, close that Editor normally, and run OpenProject.bat again. No processes were terminated."
        }
    }
}

function Invoke-ProjectBuild($Project, $Engine, $Prerequisites, [string]$LogBase) {
    if (($Project.File + $Engine.Root).Contains('!')) { Stop-Bootstrap 10 'Epic Build.bat does not safely support exclamation marks in paths. Use a project/engine folder without !.' }
    $build = Join-Path $Engine.Root 'Engine\Build\BatchFiles\Build.bat'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $env:ComSpec
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WorkingDirectory = $Project.Root
    # Environment expansion keeps paths literal, including spaces, Unicode, %, &, and parentheses.
    $start.EnvironmentVariables['PROJECT_BOOTSTRAP_BUILD'] = $build
    $start.EnvironmentVariables['PROJECT_BOOTSTRAP_PROJECT'] = $Project.File
    $start.EnvironmentVariables['PROJECT_BOOTSTRAP_LOG'] = "$LogBase.build.log"
    # Always use the verified bundled SDK, regardless of developer-shell overrides.
    $start.EnvironmentVariables['UE_USE_SYSTEM_DOTNET'] = '0'
    $start.EnvironmentVariables.Remove('UE_DOTNET_VERSION')
    $start.Arguments = '/d /s /c ""%PROJECT_BOOTSTRAP_BUILD%" ' + $Project.Target + ' Win64 Development "%PROJECT_BOOTSTRAP_PROJECT%" -WaitMutex -NoHotReloadFromIDE ' + $Prerequisites.Tool.Compiler + ' -CompilerVersion=' + $Prerequisites.Tool.Version + ' -WindowsSDKVersion=' + $Prerequisites.SDK.Version + ' -UTF8Output > "%PROJECT_BOOTSTRAP_LOG%" 2>&1"'
    Write-Host "Building $($Project.Target) (Win64 Development Editor). This may take several minutes."
    Write-Host "Compiler output: $LogBase.build.log"
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { Stop-Bootstrap 50 'Could not start Unreal Build.bat.' }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(1000)) {
            if ($timer.Elapsed.TotalSeconds -ge 15) { Write-Host 'Build is still running. Full progress is in the compiler log.'; $timer.Restart() }
        }
        $code = $process.ExitCode
    } finally { $process.Dispose() }
    Write-Host "Unreal Build.bat exit code: $code"
    if ($code -ne 0) {
        Write-Host 'Last compiler messages:'
        Get-Content -LiteralPath "$LogBase.build.log" -Tail 24 -Encoding UTF8 | ForEach-Object { Write-Host $_ }
        Stop-Bootstrap 50 "Compilation failed (Unreal exit code $code). The Editor was not launched. If Live Coding or locked DLLs are mentioned, close the Editor normally. Otherwise send the logs to a developer; verify the Perforce sync is complete."
    }
}

function Start-ProjectEditor($Project, $Engine) {
    $editor = Join-Path $Engine.Root 'Engine\Binaries\Win64\UnrealEditor.exe'
    $process = Start-Process -FilePath $editor -ArgumentList ('"' + $Project.File + '"') -WorkingDirectory $Project.Root -PassThru
    if ($process.WaitForExit(5000)) { Stop-Bootstrap 51 "Unreal Editor exited during startup (code $($process.ExitCode)). Check Saved\Logs and Windows crash diagnostics." }
    Write-Host "Unreal Editor started (PID $($process.Id)). Project loading and shader compilation can take additional time."
}

function Invoke-Bootstrap($Project, [bool]$Diagnostic, [bool]$SkipLaunch, [bool]$Unattended, [string]$ExplicitEngine) {
    $Root = $Project.Root
    $logDirectory = Join-Path $Root 'Saved\Logs\ProjectBootstrap'
    $transcribing = $false
    $lock = $null
    try {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        $logBase = Join-Path $logDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + "-$PID")
        Start-Transcript -LiteralPath "$logBase.log" | Out-Null
        $transcribing = $true
        Write-Host "Project bootstrap log: $logBase.log"
        if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { Stop-Bootstrap 10 'This bootstrap supports Windows x64. Use 64-bit Windows PowerShell on an x64 PC.' }
        try { $lock = [IO.File]::Open((Join-Path $logDirectory 'bootstrap.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { Stop-Bootstrap 41 'Another project bootstrap is running, or the local Saved folder is not writable. Wait for setup to finish and retry.' }
        Write-Host "Project: $($project.File); Editor target: $($project.Target)"
        $engine = Resolve-Engine $project $ExplicitEngine (-not ($Unattended -or $Diagnostic))
        Write-Host "Engine: UE $($engine.Version) at $($engine.Root)"
        $prerequisites = Get-Prerequisites $engine
        if ($prerequisites.Tool) { Write-Host "MSVC: $($prerequisites.Tool.Version) at $($prerequisites.Tool.Root)" }
        else { Write-Host 'Missing: usable x64 MSVC toolchain preferred by this engine.' }
        if ($prerequisites.SDK) { Write-Host "Windows SDK: $($prerequisites.SDK.Version)" }
        else { Write-Host 'Missing: complete x64 Windows SDK allowed by this engine policy.' }
        Write-Host "Bundled .NET SDK/runtime verified: $($prerequisites.DotNet)"
        if ($Diagnostic) {
            Assert-EditorClosed $project @(Get-EditorProcesses)
            if (-not $prerequisites.Ready) { Stop-Bootstrap 30 'Diagnostic: build prerequisites are missing. Run OpenProject.bat without -Diagnose to review installation.' }
            Write-Host 'Diagnostic passed. No downloads, installs, builds or launches were performed.'
            return 0
        }
        Assert-EditorClosed $project @(Get-EditorProcesses)
        if (-not $prerequisites.Ready) {
            if ($Unattended) { Stop-Bootstrap 30 'Build prerequisites are missing. Run interactively to review and approve installation.' }
            $prerequisites = Install-Prerequisites $prerequisites $engine $logDirectory
        }
        # Repeat after installation: the artist could have opened the project meanwhile.
        Assert-EditorClosed $project @(Get-EditorProcesses)
        Invoke-ProjectBuild $project $engine $prerequisites $logBase
        if (-not $SkipLaunch) { Start-ProjectEditor $project $engine }
        Write-Host 'Completed successfully.'
        return 0
    } catch {
        Write-Host ''
        Write-Host "STOPPED: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ScriptStackTrace) { Write-Verbose $_.ScriptStackTrace }
        Write-Host "Diagnostic logs: $logDirectory"
        if ($_.Exception.Data.Contains('BootstrapCode')) { return [int]$_.Exception.Data['BootstrapCode'] }
        return 1
    } finally {
        if ($lock) { $lock.Dispose() }
        if ($transcribing) { Stop-Transcript | Out-Null }
    }
}

. (Join-Path $PSScriptRoot 'BootstrapDiscovery.ps1')

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-BootstrapEntry $PSScriptRoot $ProjectPath $EditorTarget $Diagnose.IsPresent $NoLaunch.IsPresent $NonInteractive.IsPresent $EnginePath)
}
