# Hyper-V Manager

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
