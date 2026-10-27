# UnrealProjectBootstrap

A lightweight Windows launcher for Unreal Engine C++ projects. It discovers the
project and matching installed engine, checks build prerequisites, incrementally
builds the Editor target, and opens Unreal Editor after a successful build.

Use it when opening a C++ project for the first time or rebuilding after a
source-control update, without opening Visual Studio or maintaining project-specific
engine paths.

## Features

- Discovers the nearest project and its explicit C++ Editor target.
- Resolves the installed engine from `EngineAssociation` and local registrations.
- Checks MSVC, Windows SDK, and the engine's bundled .NET against engine policy.
- Offers missing Microsoft build components for installation with explicit consent
  and digital signature verification.
- Delegates incremental builds to Unreal's `Build.bat` and UnrealBuildTool (UBT).
- Records setup and compiler logs, and stops before launch when a build fails.

## Supported environment

Windows x64, 64-bit Windows PowerShell 5.1, and an already installed Unreal Engine 5
with its build tooling. PowerShell 7 and a full Visual Studio IDE are not required.
The primary real-world tested configuration is **UE 5.8.4 on Windows x64**.

Projects need a `Source/*.Target.cs` file that explicitly assigns
`Type = TargetType.Editor;`. Project, folder, and target names may differ. Other UE5
versions depend on the policy and layouts already recognized by the implementation;
there is no claim of complete UE5 compatibility.

## Quick start

Copy only these three runtime files into your Unreal project, preserving the layout:

```text
YourProject/
  YourProject.uproject
  OpenProject.bat
  Scripts/
    ProjectBootstrap.ps1
    BootstrapDiscovery.ps1
```

`Tests/`, the README, and this repository's `.gitignore` are not runtime dependencies.
The launcher uses its own location to discover the nearest ancestor containing a
project; it does not depend on the shell's working directory.

Close the project's Editor and double-click **OpenProject.bat** as your normal
Windows user. Keep the project folder writable for build output and logs. Spaces
and non-ASCII characters in paths are supported; `!` in project or engine paths is
rejected because of Epic's batch expansion rules.

### First run and permissions

Suitable existing tools are reused. If tools are missing, the launcher lists the
proposed components and asks you to type **YES**. It downloads the official
Microsoft Visual Studio 2022 bootstrapper over HTTPS and requires a valid Microsoft
Authenticode signature before execution. Only the installer requests administrator
approval through UAC; run the launcher itself without elevation.

A new setup uses standalone Visual Studio 2022 Build Tools. An existing VS 2022
edition may have components added and may need a servicing update; the consent
prompt explains that update. Internet access, administrator credentials, and several
GB of free disk space may be needed. The installer reports its actual requirements.
If a restart is required, save your work, restart Windows, and rerun the launcher.
The script requests no automatic restart and verifies prerequisites after installation.

Unreal Engine must be installed separately. The launcher does not change project
settings, Windows file associations, or source-control configuration. It writes
normal generated build files and logs; it does not delete generated folders.

### After a source-control update

Finish syncing the project, close its Editor, and run **OpenProject.bat** again.
Every normal run invokes UBT for a Win64 Development Editor build. UBT determines
what needs recompiling; an up-to-date target needs no full rebuild. The launcher
does not sync source control or run a clean build.

## Command-line options

Use the package in place by selecting a project explicitly, or pass options to the
copy installed in a project. From Command Prompt:

```bat
OpenProject.bat -ProjectPath "D:\Projects\MyGame\MyGame.uproject" -Diagnose
OpenProject.bat -ProjectPath "D:\Projects\MyGame" -NoLaunch -NonInteractive
```

| Option | Behavior |
| --- | --- |
| `-ProjectPath "path"` | Select a project folder or exact `.uproject`. Relative paths use the folder containing `OpenProject.bat`. |
| `-EnginePath "path"` | Select an existing engine root containing `Engine`. Numeric project associations must still match. |
| `-EditorTarget MyGameEditor` | Select among multiple explicit Editor targets; omit `.Target.cs`. |
| `-Diagnose` | Check discovery and prerequisites, including whether the project Editor is closed. Write a diagnostic log; never download, install, build, or launch. |
| `-NoLaunch` | Build successfully without opening the Editor. |
| `-NonInteractive` | Fail instead of prompting for engine selection or installing prerequisites. Does not suppress the batch wrapper's pause on failure. |

Multiple `.uproject` files require an exact `-ProjectPath`; multiple Editor targets
require `-EditorTarget`. Numeric engine associations match the same major/minor
version, and an explicit patch must also match. Custom/GUID associations use local
registration or an explicit `-EnginePath`. Ambiguous or missing selections require
an engine path; a newer minor version is never substituted automatically.

For automation without the batch wrapper's failure pause, invoke PowerShell directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Scripts\ProjectBootstrap.ps1 -ProjectPath "D:\Projects\MyGame" -NoLaunch -NonInteractive
```

## Troubleshooting

Setup logs are in the selected project's `Saved\Logs\ProjectBootstrap\<timestamp>-<pid>.log`.
The matching `.build.log` holds compiler output; build failures also show its last
messages in the console. Discovery failures before a project is selected appear
only in the console. Logs include local paths; review them before sharing publicly.

- **Project or target not found:** check the runtime layout and use explicit
  `-ProjectPath` / `-EditorTarget` arguments to resolve ambiguity.
- **Engine or bundled .NET missing:** select the matching engine or use Epic Games
  Launcher's **Verify**. Installing an unrelated system .NET SDK is not the remedy.
- **Missing compiler or SDK:** run interactively to review installation, or ask a
  developer to install the engine's preferred components when no supported plan exists.
- **Installer failure:** check internet access, disk space, certificates, and UAC
  permissions. Microsoft installer `dd_*` logs are in the approving account's `%TEMP%`.
- **Editor running or build locked:** close the project's Editor normally and wait
  for other builds to finish. No process is force-terminated.
- **Compilation failure:** confirm the sync completed and inspect the `.build.log`.
- **PowerShell blocked by organizational policy:** ask your administrator; do not
  change machine-wide policy as a troubleshooting step.

Exit codes:

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Unexpected error |
| `10` | Project, target, platform, or unsupported build path |
| `20`, `21`, `22` | Engine selection failed, selection canceled, or engine policy / bundled .NET problem |
| `30`, `31` | Missing prerequisites / unsupported installation plan, or restart required |
| `32`, `33` | Installer / verification failure, or installation declined / canceled |
| `40`, `41` | Project Editor may be open, or concurrent launcher / log lock problem |
| `50`, `51` | Build failed (original UBT code is logged), or Editor exited during startup |

## Tests and limitations

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-ProjectBootstrap.ps1
```

Add `-CompatibilityProject "D:\Projects\MyGame\MyGame.uproject"` for read-only
inspection of a real project's engine and installed prerequisites. Tests need no
external test framework. They never install software or launch the Editor. Generated
fixtures and logs remain in the ignored `Saved\BootstrapTests` directory.

The suite covers project/engine discovery, policy selection, mocked installer and
process failures, real synthetic build subprocesses, and the batch wrapper from an
unrelated working directory. Synthetic commands test process and log handling,
not native C++ compilation. Installer signature, consent, UAC, and reboot scenarios
are mocked; clean-machine installation has not been verified.

Release preparation passed **74 assertions** in Windows PowerShell 5.1: 73 isolated
assertions plus one read-only real-project compatibility check. The source
implementation had already passed a real UE 5.8.4 incremental Editor build on
Windows x64. No native build or visual Editor test was rerun during repository
preparation. Real-project verification evidence is kept outside this repository.

Blueprint-only projects, inherited/computed Editor target rules, UE4, and ARM64 are
outside the supported scope. Other engine versions, VS 2026, first-time installation,
reboot continuation, and rebuilding after a real source-control sync have not all
been validated end to end. Unknown engine policy or .NET layouts stop with an
explanation instead of guessing tool versions.

## License

Licensed under the [MIT License](LICENSE). Copyright (c) 2026 PullsarDev.
