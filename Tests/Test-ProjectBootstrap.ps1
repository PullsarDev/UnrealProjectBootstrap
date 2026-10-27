#requires -Version 5.1
<# Isolated tests: no installs, real Editor launches or real native compilation.
   Optional -CompatibilityProject performs read-only project/engine/prerequisite
   inspection against an existing .uproject or project folder.
#>
[CmdletBinding()]
param([string]$CompatibilityProject)
$ErrorActionPreference = 'Stop'
$packageRoot = Split-Path $PSScriptRoot -Parent
$runtimeScripts = Join-Path $packageRoot 'Scripts'
$fixtureRoot = Join-Path $packageRoot ('Saved\BootstrapTests\' + [guid]::NewGuid().ToString('N') + ' space ' + [char]0x00e7)
$utf8 = New-Object Text.UTF8Encoding($false)
$script:passed = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:passed++
}
function Expect-Code([int]$Expected, [scriptblock]$Action) {
    try { & $Action | Out-Null } catch {
        Assert ($_.Exception.Data['BootstrapCode'] -eq $Expected) "Expected code $Expected; got $($_.Exception.Message)"
        return
    }
    throw "FAILED: expected code $Expected"
}
function Write-Fixture([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, ($Text -replace '\r?\n', "`r`n"), $utf8)
}
function New-ProjectFixture([string]$Folder, [string]$Name, [string]$Target, [string]$Association) {
    $path = Join-Path $fixtureRoot $Folder
    Write-Fixture (Join-Path $path "$Name.uproject") (@{ EngineAssociation=$Association; Modules=@(@{Name=$Name;Type='Runtime'}) } | ConvertTo-Json -Depth 4)
    Write-Fixture (Join-Path $path "Source\$Target.Target.cs") "public class $($Target)Target : TargetRules { /* Type=TargetType.Game; */ public $($Target)Target(TargetInfo Target) : base(Target) { Type = TargetType.Editor; } }"
    $path
}
function New-EngineFixture([string]$Name, [string]$Version, [string]$CompilerFamily, [string]$DotnetVersion, [string]$Architecture='win-x64') {
    $path = Join-Path $fixtureRoot "Engines\$Name"
    $versionObject = [version]$Version
    Write-Fixture (Join-Path $path 'Engine\Build\Build.version') (@{MajorVersion=$versionObject.Major;MinorVersion=$versionObject.Minor;PatchVersion=$versionObject.Build} | ConvertTo-Json)
    Write-Fixture (Join-Path $path 'Engine\Build\BatchFiles\Build.bat') "@echo off`nif not exist `"%~4`" exit /b 91`necho isolated successful compiler`nexit /b 0`n"
    Write-Fixture (Join-Path $path 'Engine\Build\BatchFiles\GetDotnetPath.bat') "@echo off`nset UE_DOTNET_ARCH=$Architecture`nset UE_DOTNET_VERSION=$DotnetVersion`nset UE_DOTNET_DIR=%~dp0..\..\Binaries\ThirdParty\DotNet\%UE_DOTNET_VERSION%\%UE_DOTNET_ARCH%`n"
    foreach ($file in @('Engine\Binaries\Win64\UnrealEditor.exe','Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.dll',"Engine\Binaries\ThirdParty\DotNet\$DotnetVersion\$Architecture\dotnet.exe")) { Write-Fixture (Join-Path $path $file) '' }
    Write-Fixture (Join-Path $path 'Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.runtimeconfig.json') '{"runtimeOptions":{"framework":{"name":"Microsoft.NETCore.App","version":"8.0.0"}}}'
    $component = switch ($CompilerFamily) { '14.38' { '14.38.17.8' }; '14.44' { '14.44.17.14' } }
    Write-Fixture (Join-Path $path 'Engine\Config\Windows\Windows_SDK.json') (@{
        MainVersion='10.0.22621.0';MinVersion='10.0.19041.0';MaxVersion='10.9.99999.0';MinimumVisualCppVersion="$CompilerFamily.33130";
        PreferredVisualCppVersions=@("$CompilerFamily.33130-$CompilerFamily.99999");BannedVisualCppVersions=@();
        VisualStudio2022SuggestedComponents=@("Microsoft.VisualStudio.Component.VC.$component.x86.x64")
    } | ConvertTo-Json -Depth 4)
    $path
}

foreach ($file in @((Get-Item -LiteralPath $PSCommandPath)) + @(Get-ChildItem -LiteralPath $runtimeScripts -Filter *.ps1)) {
    $tokens=$null; $parseErrors=$null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors) | Out-Null
    Assert ($parseErrors.Count -eq 0) "Syntax: $($file.Name): $parseErrors"
}
. (Join-Path $runtimeScripts 'ProjectBootstrap.ps1')

$project54Root = New-ProjectFixture 'Folder is not the project' 'Seaside' 'ToolsEditor' '5.4'
$project57Root = New-ProjectFixture ('Unicode ' + [char]0x0131 + ' path') 'Museum' 'MuseumEditor' '5.7'
$project58Root = New-ProjectFixture 'Third Project' 'Galaxy' 'WorkbenchEditor' '5.8'
Write-Fixture (Join-Path $project58Root 'Source\Game.Target.cs') 'public class GameTarget : TargetRules { string note = "Type = TargetType.Editor;"; Type = TargetType.Game; }'
$engine54Root = New-EngineFixture 'Older engine' '5.4.4' '14.38' '6.0.302' 'windows'
$engine57Root = New-EngineFixture 'Middle engine' '5.7.4' '14.44' '8.0.412'
$engine58Root = New-EngineFixture 'Current engine' '5.8.4' '14.44' '10.0'
$script:registrations = @(
    [pscustomobject]@{Association='5.4';Root=$engine54Root},
    [pscustomobject]@{Association='5.7';Root=$engine57Root},
    [pscustomobject]@{Association='5.8';Root=$engine58Root},
    [pscustomobject]@{Association='{12345678-ABCD-4567-ABCD-123456789ABC}';Root=$engine57Root}
)
foreach ($case in @(@($project54Root,'ToolsEditor','5.4'),@($project57Root,'MuseumEditor','5.7'),@($project58Root,'WorkbenchEditor','5.8'))) {
    $project = Get-ProjectInfo $case[0]
    Assert ($project.Target -eq $case[1] -and $project.Association -eq $case[2]) "Independent project/target discovery $($case[1])"
    New-Item -ItemType Directory -Path (Join-Path $case[0] 'Utilities\Nested') -Force | Out-Null
    Assert ((Get-ProjectInfo (Join-Path $case[0] 'Utilities\Nested')).Root -eq $case[0]) 'Find nearest project ancestor'
    & {
        function Get-EngineRegistrations { $script:registrations }
        $resolved = Resolve-Engine $project '' $false
        Assert ("$($resolved.Version.Major).$($resolved.Version.Minor)" -eq $case[2]) 'Match engine association, never highest installed minor'
        $policy = Get-EnginePolicy $resolved
        Assert ($policy.PreferredVisualCppVersions.Count -gt 0) 'Read selected engine compiler policy'
        Assert (Test-Path -LiteralPath (Get-BundledDotNetPath $resolved)) 'Resolve version-dependent .NET layout'
    }
}
$project = Get-ProjectInfo $project58Root
$script:fixtureProject = $project
$script:fixtureEngine = Test-Engine $engine58Root
Expect-Code 20 { Resolve-Engine $project $engine57Root $false }
& {
    function Get-EngineRegistrations { $script:registrations }
    $custom = Get-ProjectInfo $project58Root
    $custom.Association = '{12345678-ABCD-4567-ABCD-123456789ABC}'
    Assert ((Resolve-Engine $custom '' $false).Root -eq $engine57Root) 'Custom/GUID registration'
    $custom.Association = '5.8.3'
    Expect-Code 20 { Resolve-Engine $custom '' $false }
    $custom.Association = ''
    Expect-Code 20 { Resolve-Engine $custom '' $false }
    Assert ((Resolve-Engine $custom $engine54Root $false).Root -eq $engine54Root) 'Explicit path resolves empty association'
    function Get-EngineRegistrations { @() }
    function Read-Host { '' }
    Expect-Code 21 { Resolve-Engine $project '' $true }
}
# Multiple project files and multiple targets must be explicit, never arbitrary.
Copy-Item -LiteralPath (Join-Path $project54Root 'Seaside.uproject') -Destination (Join-Path $project54Root 'Second.uproject')
Expect-Code 10 { Get-ProjectInfo $project54Root }
Assert ((Get-ProjectInfo (Join-Path $project54Root 'Seaside.uproject')).Target -eq 'ToolsEditor') 'Explicit file disambiguates projects'
Write-Fixture (Join-Path $project58Root 'Source\OtherEditor.Target.cs') 'public class OtherEditorTarget : TargetRules { Type=TargetType.Editor; }'
Expect-Code 10 { Get-ProjectInfo $project58Root }
Assert ((Get-ProjectInfo $project58Root 'WorkbenchEditor').Target -eq 'WorkbenchEditor') 'Explicit Editor target'

$jsonc = Join-Path $fixtureRoot 'commented.json'
Write-Fixture $jsonc '{"url":"https://example.test/a//b", /* block */ "items":[1,2,], // line
"value":true,}'
$parsed = Read-JsonFile $jsonc
Assert ($parsed.url -eq 'https://example.test/a//b' -and $parsed.items.Count -eq 2) 'JSON comments/trailing commas preserve strings'
$policy = Get-EnginePolicy $script:fixtureEngine
$policy.BannedVisualCppVersions = @('14.44.0-14.44.35210')
Assert (-not (Test-CompilerPolicy ([version]'14.44.35207') ([version]'14.44.35207') $policy)) 'Reject banned executable version'
Assert (Test-CompilerPolicy ([version]'14.44.35229') ([version]'14.44.35207') $policy) 'Accept patched executable in preferred family'
Assert (-not (Test-CompilerPolicy ([version]'14.50.35729') ([version]'14.50.35717') $policy)) 'Do not select untested newer compiler family'
$script:missing = [pscustomobject]@{ Tool=$null;SDK=$null;Instances=@();Ready=$false;DotNet='mock .NET';Policy=$policy }
$plan = Get-InstallPlan $script:missing
Assert ($plan.Edition -eq 'buildtools' -and $plan.Components.Count -eq 3) 'New standalone Build Tools plan'
Assert ($plan.Components -contains 'Microsoft.VisualStudio.Component.VC.14.44.17.14.x86.x64') 'Engine-specific MSVC component'
$olderPolicy = Get-EnginePolicy (Test-Engine $engine54Root)
$olderPlan = Get-InstallPlan ([pscustomobject]@{Tool=$null;SDK=$true;Instances=@();Policy=$olderPolicy})
Assert ($olderPlan.Components -contains 'Microsoft.VisualStudio.Component.VC.14.38.17.8.x86.x64') 'Different engine requires different MSVC component'
$existingVS = [pscustomobject]@{installationVersion='17.8.1';installationPath='D:\Existing VS';productId='Microsoft.VisualStudio.Product.Community'}
$olderModify = Get-InstallPlan ([pscustomobject]@{Tool=$null;SDK=$true;Instances=@($existingVS);Policy=$olderPolicy})
Assert ($olderModify.Existing -and -not $olderModify.Update -and $olderModify.Components.Count -eq 1) 'Older engine modifies only missing toolset without unnecessary VS update'
$newerModify = Get-InstallPlan ([pscustomobject]@{Tool=$null;SDK=$true;Instances=@($existingVS);Policy=$policy})
Assert ($newerModify.Existing -and $newerModify.Update -and $newerModify.Edition -eq 'community') 'Newer component updates correct existing VS edition'
foreach ($code in 1602,1223,5004) { Expect-Code 33 { Assert-InstallerExit $code } }
foreach ($code in 3010,1641) { Expect-Code 31 { Assert-InstallerExit $code } }
foreach ($code in 1618,1) { Expect-Code 32 { Assert-InstallerExit $code } }
& {
    # Exercise the signature gate without downloading or running an installer.
    function Invoke-WebRequest { }
    function Get-AuthenticodeSignature { $script:installerSignature }
    $script:installerSignature = [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Microsoft Corporation, O=Microsoft Corporation, C=US'}}
    $protocol = [Net.ServicePointManager]::SecurityProtocol
    Assert ((Get-MicrosoftBootstrapper 'buildtools' $fixtureRoot) -eq (Join-Path $fixtureRoot 'vs_buildtools.exe')) 'Accept a valid Microsoft installer signature'
    Assert ([Net.ServicePointManager]::SecurityProtocol -eq $protocol) 'Restore TLS settings after download'
    foreach ($signature in @(
        [pscustomobject]@{Status='NotSigned';SignerCertificate=$null},
        [pscustomobject]@{Status='HashMismatch';SignerCertificate=$script:installerSignature.SignerCertificate},
        [pscustomobject]@{Status='Valid';SignerCertificate=[pscustomobject]@{Subject='CN=Example, O=Example, C=US'}}
    )) {
        $script:installerSignature = $signature
        Expect-Code 32 { Get-MicrosoftBootstrapper 'buildtools' $fixtureRoot }
    }
}
& {
    function Confirm-Installation { $false }
    function Get-MicrosoftBootstrapper { throw 'Must not download' }
    Expect-Code 33 { Install-Prerequisites $script:missing $script:fixtureEngine $fixtureRoot }
}
& {
    function Start-Process { throw (New-Object ComponentModel.Win32Exception(1223)) }
    Assert ((Invoke-Installer 'mock.exe' @('--passive')) -eq 1223) 'UAC cancellation'
}
& {
    function Confirm-Installation { $true }
    function Get-MicrosoftBootstrapper { 'mock.exe' }
    function Invoke-Installer { 0 }
    function Get-Prerequisites { $script:missing }
    Expect-Code 32 { Install-Prerequisites $script:missing $script:fixtureEngine $fixtureRoot }
}
Expect-Code 40 { Assert-EditorClosed $project @([pscustomobject]@{ProcessId=1;CommandLine="UnrealEditor.exe `"$($project.File)`""}) }
Expect-Code 40 { Assert-EditorClosed $project @([pscustomobject]@{ProcessId=1;CommandLine=$null}) }
Assert-EditorClosed $project @([pscustomobject]@{ProcessId=2;CommandLine='UnrealEditor.exe D:\Other\Other.uproject'})

$script:fixturePrerequisites = [pscustomobject]@{Tool=[pscustomobject]@{Version='14.44.35229';Root='mock';Compiler='-2022'};SDK=[pscustomobject]@{Version='10.0.26100.0'};Ready=$true;DotNet='mock';Policy=$policy}
& {
    function Confirm-Installation { $true }
    function Get-MicrosoftBootstrapper { 'mock.exe' }
    function Invoke-Installer([string]$File, [string[]]$Arguments) {
        Assert ($Arguments -contains '--wait' -and $Arguments -contains '--norestart' -and $Arguments -contains '--passive') 'Installer waiting and restart arguments'
        return 0
    }
    function Get-Prerequisites { $script:fixturePrerequisites }
    Assert ((Install-Prerequisites $script:missing $script:fixtureEngine $fixtureRoot).Ready) 'Install success requires post-install verification'
}
Invoke-ProjectBuild $script:fixtureProject $script:fixtureEngine $script:fixturePrerequisites (Join-Path $fixtureRoot 'successful build')
$literalLogBase = Join-Path $fixtureRoot 'literal %PROJECT_BOOTSTRAP_PROJECT% & (log)'
Invoke-ProjectBuild $script:fixtureProject $script:fixtureEngine $script:fixturePrerequisites $literalLogBase
Assert ((Get-Content -LiteralPath "$literalLogBase.build.log" -Raw -Encoding UTF8).Trim() -eq 'isolated successful compiler') 'Build log path preserves literal percent signs and shell characters'
$build = Join-Path $engine58Root 'Engine\Build\BatchFiles\Build.bat'
Write-Fixture $build "@echo off`necho isolated failed compiler`nexit /b 7`n"
Expect-Code 50 { Invoke-ProjectBuild $script:fixtureProject $script:fixtureEngine $script:fixturePrerequisites (Join-Path $fixtureRoot 'failed build') }
Expect-Code 50 { Invoke-ProjectBuild $script:fixtureProject $script:fixtureEngine $script:fixturePrerequisites $literalLogBase }
Assert ((Get-Content -LiteralPath "$literalLogBase.build.log" -Raw -Encoding UTF8).Trim() -eq 'isolated failed compiler') 'Build failure log remains readable with literal percent signs and shell characters'
& {
    function Resolve-Engine { $script:fixtureEngine }
    function Get-EditorProcesses { @() }
    function Get-Prerequisites { $script:missing }
    function Install-Prerequisites { throw 'Must not install unattended' }
    function Start-ProjectEditor { throw 'Must not launch' }
    Assert ((Invoke-Bootstrap $script:fixtureProject $false $false $true '') -eq 30) 'Missing prerequisite orchestration'
    function Get-Prerequisites { $script:fixturePrerequisites }
    function Invoke-ProjectBuild { Stop-Bootstrap 50 'Simulated compilation failure' }
    Assert ((Invoke-Bootstrap $script:fixtureProject $false $false $true '') -eq 50) 'No launch after build failure'
    Assert ((Invoke-Bootstrap $script:fixtureProject $true $false $true '') -eq 0) 'Diagnostic never builds/launches'
}
& {
    function Invoke-Bootstrap($Project) {
        Assert ($Project.Target -eq 'WorkbenchEditor') 'Entry preserves explicit Editor target'
        Assert ($Project.File -eq $script:fixtureProject.File) 'Entry preserves selected project file'
        return 0
    }
    New-Item -ItemType Directory -Path (Join-Path $project58Root 'Scripts') -Force | Out-Null
    Assert ((Invoke-BootstrapEntry (Join-Path $project58Root 'Scripts') '' 'WorkbenchEditor' $true $false $true '') -eq 0) 'Automatic entry discovery independent of CWD'
    Assert ((Invoke-BootstrapEntry (Join-Path $project58Root 'Scripts') 'Galaxy.uproject' 'WorkbenchEditor' $true $false $true '') -eq 0) 'Explicit relative project path uses launcher root'
}

# Real batch wrapper from unrelated CWD and Unicode/spaced location. The fixture
# entry point is harmless; exercise failure pause with redirected keyboard input.
Copy-Item -LiteralPath (Join-Path $packageRoot 'OpenProject.bat') -Destination $fixtureRoot
$stub = Join-Path $fixtureRoot 'Scripts\ProjectBootstrap.ps1'
foreach ($expected in 0,17) {
    Write-Fixture $stub "exit $expected"
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$env:ComSpec; $start.Arguments='/d /s /c ""%PROJECT_TEST_BATCH%""'
    $start.EnvironmentVariables['PROJECT_TEST_BATCH']=Join-Path $fixtureRoot 'OpenProject.bat'
    $start.WorkingDirectory=$env:SystemRoot; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process = New-Object Diagnostics.Process; $process.StartInfo=$start
    try {
        [void]$process.Start()
        $output=$process.StandardOutput.ReadToEndAsync(); $errorOutput=$process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine(' '); $process.StandardInput.Close()
        Assert ($process.WaitForExit(15000)) 'Batch timeout'
        Assert ($process.ExitCode -eq $expected) "Batch exit code $expected; $($errorOutput.Result)"
    } finally { $process.Dispose() }
}
if ($CompatibilityProject) {
    $realProject = Get-ProjectInfo $CompatibilityProject
    $realEngine = Resolve-Engine $realProject '' $false
    $realPrerequisites = Get-Prerequisites $realEngine
    Assert $realPrerequisites.Ready 'Real project engine/toolchain compatibility'
    Write-Host "Compatibility passed: $($realProject.File); $($realProject.Target); UE $($realEngine.Version)"
}
Write-Host "PASS: $script:passed assertions. Isolated fixtures/logs: $fixtureRoot"
