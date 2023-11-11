# Hyper-V Manager: Unofficial Patching

Install the [ILSpy](https://github.com/icsharpcode/ILSpy) command-line tool:

```powershell
dotnet tool install ilspycmd -g
```

```powershell
$HVSourcePath = "$Env:ProgramFiles\Hyper-V"
$HVAssemblyPath = "Assemblies"
$HVAssemblyLang = "en-US"
$HVAssemblyNames = @(
    'Microsoft.Virtualization.Client.Common.Types',
    'Microsoft.Virtualization.Client.Common',
    'Microsoft.Virtualization.Client',
    'Microsoft.Virtualization.Client.Management',
    'Microsoft.Virtualization.Client.Settings',
    'Microsoft.Virtualization.Client.VMBrowser',
    'Microsoft.Virtualization.Client.Wizards')

New-Item -Path $HVAssemblyPath -ItemType Directory -Force
New-Item -Path "$HVAssemblyPath\$HVAssemblyLang" -ItemType Directory -Force
$HVAssemblyNames | ForEach-Object {
    $HVResourceAssembly = "$HVAssemblyLang\$_.resources.dll"
    Copy-Item "$HVSourcePath\$_.dll" "$HVAssemblyPath\$_.dll" -Force
    Copy-Item "$HVSourcePath\$HVResourceAssembly" "$HVAssemblyPath\$HVResourceAssembly" -Force
}
```

```powershell
$HVAssemblyPath = "Assemblies"
$HVDecompiledPath = "Decompiled"
Remove-Item -Path $HVDecompiledPath -Recurse -Force
New-Item -Path $HVDecompiledPath -ItemType Directory -Force
$ILSpyCmdArgs = @('-lv', 'CSharp10_0')
Get-ChildItem $HVAssemblyPath "*.dll" | ForEach-Object {
    $HVAssemblyName = $_.BaseName
    $HVResourceAssembly = "$HVAssemblyLang\$HVAssemblyName.resources.dll"
    ilspycmd -p -o "$HVDecompiledPath\$HVAssemblyName" @ILSpyCmdArgs $_
    ilspycmd -p -o "$HVDecompiledPath\$HVAssemblyName\$HVAssemblyLang" @ILSpyCmdArgs "$HVAssemblyPath\$HVResourceAssembly"
}
Get-ChildItem $HVDecompiledPath AssemblyInfo.cs -Recurse | Remove-Item -Force
```

```powershell
$HVOverlayPath = "Overlay"
Get-ChildItem .\Overlay -Recurse -File | ForEach-Object {
    $Destination = $_.FullName.Replace($HVOverlayPath, $HVDecompiledPath)
    Copy-Item -Path $_.FullName -Destination $Destination -Force
}
Push-Location
Set-Location $HVDecompiledPath
dotnet new sln -n Microsoft.Virtualization.Client
Get-Item *\*.csproj | ForEach-Object { dotnet sln add (Resolve-Path $_ -Relative) }
Pop-Location
```

In Decompiled\Microsoft.Virtualization.Client\Microsoft.Virtualization.Client\CommonUtilities.cs, add `using System.Collections.ObjectModel;
` at the beginning then replace the RunPowershellScript function definition with this one:

```csharp
public static ICollection<PSObject> RunPowershellScript(string script)
{
    using (Runspace runspace = RunspaceFactory.CreateRunspace())
    {
        runspace.Open();
        using (System.Management.Automation.PowerShell powerShell = System.Management.Automation.PowerShell.Create())
        {
            powerShell.Runspace = runspace;
            powerShell.AddScript(script);
            Collection<PSObject> results = powerShell.Invoke();
            return results;
        }
    }
}
```

Remove default accessors defined as special functions:

```powershell
$csFiles = Get-ChildItem -Path $HVDecompiledPath -Filter *.cs -Recurse

foreach ($file in $csFiles) {
    $lines = Get-Content $file.FullName
    $newContents = @()
    $removeBlock = $false

    foreach ($line in $lines) {
        if ($removeBlock -and $line.Trim() -eq "") {
            $removeBlock = $false
        }

        if (-not $removeBlock) {
            $newContents += $line
        }

        if ($line -match "\[SpecialName\]") {
            $removeBlock = $true
            $newContents = $newContents[0..($newContents.Count-2)]
        }
    }

    Set-Content -Path $file.FullName -Value $newContents
}
```

Do a search and replace for 'Before You Begin' with 'A New Beginning' in all .resx files, then save.

Create a full backup copy of "C:\Program Files\Hyper-V", and zip it for later. Save a copy of C:\Windows\System32\virtmgmt.msc as well. In regedit.exe, export the contents of `Computer\HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\MMC\SnapIns\FX:{922180d7-b74e-45f6-8c74-4b560cc100a5}` to virtmgmt.reg, and save it alongside virtmgmt.msc. We'll use those files to "reinstall" the original Hyper-V Manager after uninstalling it.

In "Turn Windows feature on or off", uninstall "Hyper-V GUI Management Tools" under "Hyper-V\Hyper-V Management Tools". Once this is done, manually restore the contents of "C:\Program Files\Hyper-V", import virtmgmt.reg, then copy virtmgmt.msc back to C:\Windows\System32. You should now be able to launch Hyper-V Manager again.

From an elevated PowerShell terminal, flush the native image cache for the Microsoft.Virtualization.Client assemblies:

```powershell
$HVAssemblyNames = @(
    'Microsoft.Virtualization.Client.Common.Types',
    'Microsoft.Virtualization.Client.Common',
    'Microsoft.Virtualization.Client',
    'Microsoft.Virtualization.Client.Management',
    'Microsoft.Virtualization.Client.Settings',
    'Microsoft.Virtualization.Client.VMBrowser',
    'Microsoft.Virtualization.Client.Wizards')
$NgenExe = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\ngen.exe"
$GacUtilExe = "C:\Program Files (x86)\Microsoft SDKs\Windows\v10.0A\bin\NETFX 4.8 Tools\gacutil.exe"
$HVAssemblyNames | ForEach-Object {
    & $NgenExe uninstall $_
    & $GacUtilExe /u $_ /f
}
& $NgenExe executequeueditems
```

Create the "C:\Hyper-V\Manager" directory and copy the original contents of "C:\Program Files\Hyper-V" into it.

Import hvmanager.reg from this repository, then copy hvmanager.msc to "C:\Hyper-V\Manager", then try launching it with mmc.exe from an elevated PowerShell terminal:

```powershell
mmc.exe "C:\Hyper-V\Manager\hvmanager.msc"
```

Normally, this should work the same way as the original Hyper-V Manager, except we've used different GUIDs internally. The real fun begins when we try overwriting the original assembly files with those we've rebuilt from source.
