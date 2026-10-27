# Discovery and engine policy helpers. Loaded by ProjectBootstrap.ps1.
# Keep policy in the selected engine: no project names, engine drives or UE minor versions here.

function Remove-CodeComments([string]$Text) {
    [regex]::Replace($Text, '(?s)"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\r\n]*', {
        param($match)
        if ($match.Value.StartsWith('"')) { $match.Value } else { '' }
    })
}

function Read-JsonFile([string]$Path) {
    $text = Remove-CodeComments (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
    $text = [regex]::Replace($text, '"(?:\\.|[^"\\])*"|,\s*(?=[}\]])', {
        param($match)
        if ($match.Value.StartsWith('"')) { $match.Value } else { '' }
    })
    $text | ConvertFrom-Json
}

function Get-OptionalProperty($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Read-TargetRules([string]$Path) {
    $text = Remove-CodeComments (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
    [regex]::Replace($text, '@"(?:[^"]|"")*"|"(?:\\.|[^"\\])*"', '')
}

function Get-ProjectInfo([string]$StartPath, [string]$TargetOverride = '') {
    if (-not (Test-Path -LiteralPath $StartPath)) { Stop-Bootstrap 10 "Project location does not exist: $StartPath" }
    $item = Get-Item -LiteralPath $StartPath
    $projects = @()
    if (-not $item.PSIsContainer) {
        if ($item.Extension -ne '.uproject') { Stop-Bootstrap 10 'Select a .uproject file or a folder containing one.' }
        $projects = @($item)
    } else {
        # Walk ancestors only. Never search unrelated projects below a folder.
        $directory = $item
        while ($directory) {
            $projects = @(Get-ChildItem -LiteralPath $directory.FullName -Filter *.uproject -File)
            if ($projects.Count) { break }
            $directory = $directory.Parent
        }
    }
    if ($projects.Count -ne 1) { Stop-Bootstrap 10 'Cannot find one unambiguous .uproject. Put the launcher in the project folder, or pass -ProjectPath with the exact .uproject file.' }
    $file = $projects[0]
    $metadata = Read-JsonFile $file.FullName
    $sourceRoot = Join-Path $file.DirectoryName 'Source'
    $targets = @()
    if (Test-Path -LiteralPath $sourceRoot) {
        $targets = @(Get-ChildItem -LiteralPath $sourceRoot -Filter *.Target.cs -File -Recurse | Where-Object {
            $text = Read-TargetRules $_.FullName
            $text -match '\bType\s*=\s*(?:UnrealBuildTool\.)?TargetType\.Editor\s*;'
        })
    }
    if ($TargetOverride) { $targets = @($targets | Where-Object { $_.Name -eq "$TargetOverride.Target.cs" }) }
    if ($targets.Count -ne 1) { Stop-Bootstrap 10 'Cannot identify one C++ Editor target from Source/*.Target.cs. Use -EditorTarget for multiple explicit Editor targets; inherited/computed target rules need developer review.' }
    $target = $targets[0].Name -replace '\.Target\.cs$', ''
    if ($target -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { Stop-Bootstrap 10 'The Editor target name contains unsupported characters.' }
    $text = Read-TargetRules $targets[0].FullName
    if ($text -notmatch ('\bclass\s+' + [regex]::Escape($target) + 'Target\b')) { Stop-Bootstrap 10 'Editor target class and filename disagree. Ask a developer to review the target rules.' }
    [pscustomobject]@{ Root = $file.DirectoryName; File = $file.FullName; Target = $target;
        Association = [string](Get-OptionalProperty $metadata 'EngineAssociation' '') }
}

function Get-EngineRegistrations {
    $manifest = Join-Path $env:ProgramData 'Epic\UnrealEngineLauncher\LauncherInstalled.dat'
    if (Test-Path -LiteralPath $manifest) {
        try {
            foreach ($install in (Read-JsonFile $manifest).InstallationList) {
                if ($install.AppName -match '^UE_(\d+\.\d+(?:\.\d+)?)$') {
                    [pscustomobject]@{ Association = $Matches[1]; Root = $install.InstallLocation }
                }
            }
        } catch { Write-Warning "Cannot read Epic Launcher metadata: $($_.Exception.Message)" }
    }
    foreach ($registryRoot in @('HKLM:\SOFTWARE\EpicGames\Unreal Engine', 'HKLM:\SOFTWARE\WOW6432Node\EpicGames\Unreal Engine')) {
        foreach ($key in @(Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            $directory = Get-OptionalProperty $properties 'InstalledDirectory' ''
            if ($directory) { [pscustomobject]@{ Association = $key.PSChildName; Root = $directory } }
        }
    }
    $builds = Get-ItemProperty -LiteralPath 'HKCU:\SOFTWARE\Epic Games\Unreal Engine\Builds' -ErrorAction SilentlyContinue
    if ($builds) {
        foreach ($property in $builds.PSObject.Properties) {
            if ($property.Name -notlike 'PS*') { [pscustomobject]@{ Association = $property.Name; Root = [string]$property.Value } }
        }
    }
}

function Test-Engine([string]$Root) {
    try {
        $Root = [IO.Path]::GetFullPath($Root.Trim().Trim('"')).TrimEnd('\')
        $version = Read-JsonFile (Join-Path $Root 'Engine\Build\Build.version')
        if ($version.MajorVersion -ne 5) { return $null }
        foreach ($relative in @('Engine\Build\BatchFiles\Build.bat', 'Engine\Build\BatchFiles\GetDotnetPath.bat',
            'Engine\Binaries\Win64\UnrealEditor.exe', 'Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.dll',
            'Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.runtimeconfig.json')) {
            if (-not (Test-Path -LiteralPath (Join-Path $Root $relative) -PathType Leaf)) { return $null }
        }
        [pscustomobject]@{ Root = $Root; Version = [version]::new($version.MajorVersion, $version.MinorVersion, $version.PatchVersion) }
    } catch { return $null }
}

function Test-EngineAssociation($Engine, [string]$Association, [object[]]$Registrations) {
    if (-not $Association) { return $true }
    if ($Association -match '^\d+\.\d+(?:\.\d+)?$') {
        $requested = [version]$Association
        return $Engine.Version.Major -eq $requested.Major -and $Engine.Version.Minor -eq $requested.Minor -and
            ($requested.Build -lt 0 -or $Engine.Version.Build -eq $requested.Build)
    }
    @($Registrations | Where-Object {
        $_.Association.Trim('{}') -eq $Association.Trim('{}') -and
        [IO.Path]::GetFullPath($_.Root).TrimEnd('\') -eq $Engine.Root
    }).Count -gt 0
}

function Resolve-Engine($Project, [string]$ExplicitPath, [bool]$Interactive) {
    $registrations = @(Get-EngineRegistrations)
    $association = $Project.Association
    if ($ExplicitPath) {
        $engine = Test-Engine $ExplicitPath
        # A GUID/custom association can be explicitly mapped without changing the
        # project or Windows registration. Numeric associations still must match.
        if ($engine -and ($association -notmatch '^\d+\.\d+(?:\.\d+)?$' -or (Test-EngineAssociation $engine $association $registrations))) { return $engine }
        Stop-Bootstrap 20 "Engine path is incomplete, unsupported, or does not match EngineAssociation '$association'. Select the matching UE5 root or Verify it in Epic Games Launcher."
    }
    $compatible = @(foreach ($registration in $registrations) {
        $engine = Test-Engine $registration.Root
        if ($engine -and (Test-EngineAssociation $engine $association $registrations)) { $engine }
    })
    $compatible = @($compatible | Sort-Object Root -Unique)
    # Empty association has no version authority: only auto-select if unique.
    if ($compatible.Count -and ($association -or $compatible.Count -eq 1)) {
        return $compatible | Sort-Object Version -Descending | Select-Object -First 1
    }
    if (-not $Interactive) { Stop-Bootstrap 20 "No unambiguous installed UE5 engine matches EngineAssociation '$association'. Use -EnginePath, or install/Verify the matching engine in Epic Games Launcher." }
    Write-Host "Choose the installed engine root (containing Engine) for association '$association'. No engine will be installed."
    while ($true) {
        $answer = Read-Host 'Engine folder (blank cancels)'
        if ([string]::IsNullOrWhiteSpace($answer)) { Stop-Bootstrap 21 'Engine selection canceled. Run OpenProject.bat again when ready.' }
        try { return Resolve-Engine $Project $answer $false }
        catch {
            if ($_.Exception.Data['BootstrapCode'] -ne 20) { throw }
            Write-Host $_.Exception.Message
        }
    }
}

function Get-CSharpRanges([string]$Text, [string]$Name) {
    $array = [regex]::Match($Text, '(?s)\b' + $Name + '\s*=[^{]*\{(.*?)\};')
    foreach ($match in [regex]::Matches($array.Groups[1].Value, 'VersionNumberRange\.Parse\("([\d.]+)",\s*"([\d.]+)"\)')) {
        "$($match.Groups[1].Value)-$($match.Groups[2].Value)"
    }
}

function Get-EnginePolicy($Engine) {
    $policyPath = Join-Path $Engine.Root 'Engine\Config\Windows\Windows_SDK.json'
    if (Test-Path -LiteralPath $policyPath) { $policy = Read-JsonFile $policyPath }
    else {
        # Earlier UE5 releases keep the same facts in installed UBT source.
        # Read declarations only; never execute engine/project source as script.
        $directory = Join-Path $Engine.Root 'Engine\Source\Programs\UnrealBuildTool\Platform\Windows'
        $text = (@(foreach ($name in @('MicrosoftPlatformSDK.Versions.cs', 'MicrosoftPlatformSDK.cs', 'MicrosoftPlatformSDK.VisualStudio.cs', 'UEBuildWindows.cs')) {
            $path = Join-Path $directory $name
            if (Test-Path -LiteralPath $path) { Remove-CodeComments (Get-Content -LiteralPath $path -Raw -Encoding UTF8) }
        })) -join "`n"
        $minimum = [regex]::Match($text, 'MinimumVisualCppVersion\s*=\s*new VersionNumber\(([\d,\s]+)\)')
        $sdkArray = [regex]::Match($text, '(?s)PreferredWindowsSdkVersions\s*=[^{]*\{(.*?)\};')
        $sdk = [regex]::Match($sdkArray.Groups[1].Value, 'VersionNumber\.Parse\("([\d.]+)"\)')
        if (-not $minimum.Success -or -not $sdk.Success) { Stop-Bootstrap 22 'Cannot read Windows build requirements from this engine. Ask a developer to review its UBT policy; no tool versions were guessed.' }
        $minSDK = [regex]::Match($text, 'MinimumWindowsSDKVersion\s*=\s*new VersionNumber\(([\d,\s]+)\)')
        $policy = [pscustomobject]@{ MinimumVisualCppVersion = ($minimum.Groups[1].Value -replace '\s','' -replace ',', '.');
            PreferredVisualCppVersions = @(Get-CSharpRanges $text 'PreferredVisualCppVersions');
            BannedVisualCppVersions = @(Get-CSharpRanges $text 'BannedVisualCppVersions');
            MainVersion = $sdk.Groups[1].Value; MinVersion = $sdk.Groups[1].Value; MaxVersion = '10.9.99999.0';
            VisualStudioSuggestedComponents = @([regex]::Matches($text, '"(Microsoft\.VisualStudio\.Component\.[^"\r\n]+)"') | ForEach-Object { $_.Groups[1].Value }) }
        if ($minSDK.Success) { $policy.MinVersion = $minSDK.Groups[1].Value -replace '\s','' -replace ',', '.' }
    }
    foreach ($required in @('MinimumVisualCppVersion','PreferredVisualCppVersions','MinVersion','MaxVersion','MainVersion')) {
        if (-not (Get-OptionalProperty $policy $required)) { Stop-Bootstrap 22 "Engine policy does not define $required. Ask a developer to review this engine; no tool versions were guessed." }
    }
    $policy
}

function Test-CompilerPolicy([version]$Version, [version]$Family, $Policy) {
    if ($Version -lt [version]$Policy.MinimumVisualCppVersion) { return $false }
    foreach ($range in @(Get-OptionalProperty $Policy 'BannedVisualCppVersions' @())) {
        if (Test-VersionRange $Version $range) { return $false }
    }
    # Use a family tested/preferred by this engine, rather than choosing a newer
    # compiler solely because it exceeds the minimum (older UE code can break).
    foreach ($range in $Policy.PreferredVisualCppVersions) {
        if (Test-VersionRange $Family $range) { return $true }
    }
    return $false
}

function Get-BundledDotNetPath($Engine) {
    $path = Join-Path $Engine.Root 'Engine\Build\BatchFiles\GetDotnetPath.bat'
    $text = Get-Content -LiteralPath $path -Raw
    $version = [regex]::Match($text, '(?im)^set "?UE_DOTNET_VERSION=([\d.]+)"?\s*$').Groups[1].Value
    $architecture = [regex]::Match($text, '(?im)^set "?UE_DOTNET_ARCH=([\w-]+)').Groups[1].Value
    $directory = [regex]::Match($text, '(?im)^set "?UE_DOTNET_DIR=([^\r\n"]+)').Groups[1].Value
    if ($directory.Contains('%UE_DOTNET_ARCH%') -and $architecture -notin @('windows','win-x64')) { Stop-Bootstrap 22 'Unrecognized bundled .NET x64 architecture declaration. Ask a developer to review this engine.' }
    $directory = $directory.Replace('%~dp0', ((Split-Path $path) + '\')).Replace('%UE_DOTNET_VERSION%', $version).Replace('%UE_DOTNET_ARCH%', $architecture)
    if (-not $directory -or $directory.Contains('%')) { Stop-Bootstrap 22 'Unrecognized engine bundled .NET layout. Verify the engine, or ask a developer to review GetDotnetPath.bat.' }
    $dotnet = Join-Path ([IO.Path]::GetFullPath($directory)) 'dotnet.exe'
    if (-not (Test-Path -LiteralPath $dotnet)) { Stop-Bootstrap 22 'The engine bundled .NET SDK is missing. Verify the selected engine in Epic Games Launcher.' }
    $dotnet
}

function Get-BundledDotNet($Engine) {
    $dotnet = Get-BundledDotNetPath $Engine
    $runtime = Read-JsonFile (Join-Path $Engine.Root 'Engine\Binaries\DotNET\UnrealBuildTool\UnrealBuildTool.runtimeconfig.json')
    $required = [version]$runtime.runtimeOptions.framework.version
    $runtimes = & $dotnet --list-runtimes 2>&1
    if ($LASTEXITCODE -ne 0 -or -not ($runtimes -match "^Microsoft.NETCore.App $($required.Major)\.$($required.Minor)\.")) {
        Stop-Bootstrap 22 'The engine bundled .NET runtime required by UBT cannot run. Verify this engine and its Launcher prerequisites.'
    }
    $sdks = & $dotnet --list-sdks 2>&1
    if ($LASTEXITCODE -ne 0 -or -not ($sdks -match "^$($required.Major)\.$($required.Minor)\.")) { Stop-Bootstrap 22 'The engine bundled .NET SDK cannot run. Verify the engine in Epic Games Launcher.' }
    $dotnet
}

function Get-PolicyComponents($Policy) {
    @(@(Get-OptionalProperty $Policy 'VisualStudio2022SuggestedComponents' @()) +
        @(Get-OptionalProperty $Policy 'VisualStudioSuggestedComponents' @())) | Select-Object -Unique
}

function Get-InstallPlan($Prerequisites) {
    $policy = $Prerequisites.Policy
    $components = @()
    $minimumVS = [version](Get-OptionalProperty $policy 'MinimumVisualStudio2022Version' '17.0')
    if (-not $Prerequisites.Tool) {
        $msvc = @(Get-PolicyComponents $policy | Where-Object { $_ -match '^Microsoft\.VisualStudio\.Component\.VC\.14\.\d+\.17\.\d+\.x86\.x64$' } | Where-Object {
            $family = [regex]::Match($_, '\.VC\.(14\.\d+)\.').Groups[1].Value
            @($policy.PreferredVisualCppVersions | Where-Object { $_.StartsWith("$family.") }).Count -gt 0
        }) | Select-Object -First 1
        if (-not $msvc -and @($policy.PreferredVisualCppVersions | Where-Object { $_ -like '14.29.*' }).Count) {
            $msvc = 'Microsoft.VisualStudio.ComponentGroup.VC.Tools.142.x86.x64'
        }
        if (-not $msvc) { Stop-Bootstrap 30 'This engine does not declare an installable VS 2022 MSVC component. Ask a developer to install its preferred toolchain. No unverified component ID was guessed.' }
        $components += $msvc
        if ($msvc -match '\.17\.(\d+)\.x86\.x64$') {
            $componentMinimum = [version]"17.$($Matches[1])"
            if ($componentMinimum -gt $minimumVS) { $minimumVS = $componentMinimum }
        }
    }
    if (-not $Prerequisites.SDK) {
        # The official VS2022 SDK 26100 is within current UE5 SDK policy ranges.
        if ([version]'10.0.26100.0' -lt [version]$policy.MinVersion -or [version]'10.0.26100.0' -gt [version]$policy.MaxVersion) { Stop-Bootstrap 30 'No verified automatic Windows SDK installation matches this engine policy. Ask a developer to install the required SDK.' }
        $components += 'Microsoft.VisualStudio.Component.Windows11SDK.26100'
    }
    $existing = $Prerequisites.Instances | Where-Object { ([version]$_.installationVersion).Major -eq 17 } |
        Sort-Object { [version]$_.installationVersion } -Descending | Select-Object -First 1
    if ($existing) {
        $edition = switch ($existing.productId) {
            'Microsoft.VisualStudio.Product.Community' { 'community' }
            'Microsoft.VisualStudio.Product.Professional' { 'professional' }
            'Microsoft.VisualStudio.Product.Enterprise' { 'enterprise' }
            'Microsoft.VisualStudio.Product.BuildTools' { 'buildtools' }
            default { Stop-Bootstrap 30 'Unrecognized Visual Studio edition. Use Visual Studio Installer to add the engine-required components.' }
        }
        return [pscustomobject]@{ Edition = $edition; Path = $existing.installationPath; Existing = $true;
            Update = ([version]$existing.installationVersion -lt $minimumVS); Components = $components }
    }
    [pscustomobject]@{ Edition = 'buildtools'; Path = ''; Existing = $false; Update = $false;
        Components = @('Microsoft.VisualStudio.Workload.VCTools') + $components }
}

function Get-Prerequisites($Engine) {
    $policy = Get-EnginePolicy $Engine
    $instances = @(Get-VSInstances)
    $toolchains = @(
        foreach ($instance in $instances) {
            $vsVersion = [version]$instance.installationVersion
            $vsMinimum = [version](Get-OptionalProperty $policy 'MinimumVisualStudio2022Version' '17.0')
            $compiler = '-2022'
            if ($vsVersion.Major -eq 18) {
                $minimum2026 = Get-OptionalProperty $policy 'MinimumVisualStudio2026Version' ''
                if (-not $minimum2026) { continue }
                $vsMinimum = [version]$minimum2026
                $compiler = '-2026'
            }
            if ($vsVersion -lt $vsMinimum) { continue }
            foreach ($folder in @(Get-ChildItem -LiteralPath (Join-Path $instance.installationPath 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue)) {
                if ($folder.Name -notmatch '^14\.\d+\.\d+$') { continue }
                $complete = $true
                foreach ($file in @('bin\Hostx64\x64\cl.exe', 'bin\Hostx64\x64\link.exe', 'bin\Hostx64\x64\lib.exe',
                    'bin\Hostx64\x64\c1xx.dll', 'bin\Hostx64\x64\c2.dll', 'include\vector', 'lib\x64\libcmt.lib', 'lib\x64\msvcprt.lib')) {
                    if (-not (Test-Path -LiteralPath (Join-Path $folder.FullName $file))) { $complete = $false }
                }
                if (-not $complete) { continue }
                $info = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $folder.FullName 'bin\Hostx64\x64\cl.exe'))
                $version = [version]::new(14, $info.FileMinorPart, $info.FileBuildPart)
                $family = [version]$folder.Name
                # A side-by-side toolset cannot make an older VS installation
                # support a newer VS release. v143 14.30..14.44 map to 17.0..17.14.
                if ($vsVersion.Major -eq 17 -and $family.Minor -ge 30) {
                    if ($family.Minor -gt 44 -or $vsVersion -lt [version]"17.$($family.Minor - 30)") { continue }
                }
                if (-not (Test-CompilerPolicy $version $family $policy)) { continue }
                $rank = 0
                foreach ($range in $policy.PreferredVisualCppVersions) {
                    if (Test-VersionRange $family $range) { break }
                    $rank++
                }
                [pscustomobject]@{ Instance = $instance; Version = $version.ToString(); Root = $folder.FullName; Compiler = $compiler; Rank = $rank }
            }
        }
    )
    $tool = $toolchains | Sort-Object Rank, @{Expression = { [version]$_.Version }; Descending = $true} | Select-Object -First 1
    $sdk = Get-WindowsSDK | Where-Object {
        [version]$_.Version -ge [version]$policy.MinVersion -and [version]$_.Version -le [version]$policy.MaxVersion
    } | Sort-Object @{Expression = { $_.Version -eq $policy.MainVersion }; Descending = $true}, @{Expression = { [version]$_.Version }; Descending = $true} | Select-Object -First 1
    $dotnet = Get-BundledDotNet $Engine
    [pscustomobject]@{ Tool = $tool; SDK = $sdk; Instances = $instances; DotNet = $dotnet; Policy = $policy; Ready = [bool]($tool -and $sdk) }
}

function Invoke-BootstrapEntry([string]$ScriptDirectory, [string]$ProjectPath, [string]$EditorTarget,
    [bool]$Diagnostic, [bool]$SkipLaunch, [bool]$Unattended, [string]$EnginePath) {
    try {
        # An explicit relative argument is relative to the launcher, never CWD.
        $location = $ScriptDirectory
        if ($ProjectPath) {
            $location = $ProjectPath
            if (-not [IO.Path]::IsPathRooted($location)) {
                $location = Join-Path (Split-Path $ScriptDirectory -Parent) $location
            }
        }
        $project = Get-ProjectInfo $location $EditorTarget
        return Invoke-Bootstrap $project $Diagnostic $SkipLaunch $Unattended $EnginePath
    } catch {
        # Project discovery can fail before there is a project-local Saved folder.
        Write-Host "STOPPED: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Data.Contains('BootstrapCode')) { return [int]$_.Exception.Data['BootstrapCode'] }
        return 1
    }
}
