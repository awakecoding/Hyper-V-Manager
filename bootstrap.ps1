
$HVSourcePath = "$Env:ProgramFiles\Hyper-V"
$HVAssemblyPath = "Assemblies"
$HVDecompiledPath = "Decompiled"
$HVOverlayPath = "Overlay"
$HVAssemblyLang = "en-US"
$HVAssemblyNames = @(
    'Microsoft.Virtualization.Client.Common.Types',
    'Microsoft.Virtualization.Client.Common',
    'Microsoft.Virtualization.Client',
    'Microsoft.Virtualization.Client.Management',
    'Microsoft.Virtualization.Client.Settings',
    'Microsoft.Virtualization.Client.VMBrowser',
    'Microsoft.Virtualization.Client.Wizards')

# Copy assemblies of interest

New-Item -Path $HVAssemblyPath -ItemType Directory -Force
New-Item -Path "$HVAssemblyPath\$HVAssemblyLang" -ItemType Directory -Force
$HVAssemblyNames | ForEach-Object {
    $HVResourceAssembly = "$HVAssemblyLang\$_.resources.dll"
    Copy-Item "$HVSourcePath\$_.dll" "$HVAssemblyPath\$_.dll" -Force
    Copy-Item "$HVSourcePath\$HVResourceAssembly" "$HVAssemblyPath\$HVResourceAssembly" -Force
}

$HVResourceAssembly = "$HVAssemblyLang\vmconnect.resources.dll"
Copy-Item "$Env:WinDir\vmconnect.exe" "$HVAssemblyPath\vmconnect.exe" -Force
Copy-Item "$Env:WinDir\$HVResourceAssembly" "$HVAssemblyPath\$HVResourceAssembly" -Force

$VirtMgmtRegPath = "HKLM\SOFTWARE\Microsoft\MMC\SnapIns\FX:{922180d7-b74e-45f6-8c74-4b560cc100a5}"
& reg export $VirtMgmtRegPath "$HVAssemblyPath\virtmgmt.reg" /y /reg:64

Copy-Item "$Env:WinDir\virtmgmt.msc" "$HVAssemblyPath\virtmgmt.msc" -Force

# Decompile assemblies of interest

Remove-Item -Path $HVDecompiledPath -Recurse -Force
New-Item -Path $HVDecompiledPath -ItemType Directory -Force
$ILSpyCmdArgs = @('-lv', 'CSharp10_0')
Get-ChildItem $HVAssemblyPath "*.dll" | ForEach-Object {
    $HVAssemblyName = $_.BaseName
    $HVResourceAssembly = "$HVAssemblyLang\$HVAssemblyName.resources.dll"
    ilspycmd -p -o "$HVDecompiledPath\$HVAssemblyName" @ILSpyCmdArgs $_
    ilspycmd -p -o "$HVDecompiledPath\$HVAssemblyName\$HVAssemblyLang" @ILSpyCmdArgs "$HVAssemblyPath\$HVResourceAssembly"
}

# Remove AssemblyInfo.cs files
Get-ChildItem $HVDecompiledPath AssemblyInfo.cs -Recurse | Remove-Item -Force

# Fix resource namespacing
Get-ChildItem $HVDecompiledPath "Microsoft.Virtualization.Client*.resx" -Recurse -File | ForEach-Object {
    $AssemblyName = $_.Directory.BaseName
    $NewBaseName = $_.BaseName -Replace "${AssemblyName}.", ""
    $Destination = Join-Path $_.Directory "${NewBaseName}.resx"
    Move-Item $_ $Destination
}

# Remove invalid accessors

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

# Patch RunPowershellScript in CommonUtilities.cs
$projectName = "Microsoft.Virtualization.Client"
$filePath = Join-Path $HVDecompiledPath "$ProjectName\$ProjectName\CommonUtilities.cs"
$fileContent = Get-Content $filePath -Raw

$pattern = '\s*Pipeline pipeline = runspace.CreatePipeline\(\);\s*pipeline.Commands.AddScript\(script\);\s*return pipeline.Invoke\(\);'

$replacement = @"
            System.Management.Automation.PowerShell powerShell = System.Management.Automation.PowerShell.Create();
            powerShell.Runspace = runspace;
            powerShell.AddScript(script);
            return powerShell.Invoke();
"@

$newContent = $fileContent -replace $pattern, $replacement
Set-Content -Path $filePath -Value $newContent

# Apply overlay project files
Get-ChildItem .\Overlay -Recurse -File | ForEach-Object {
    $Destination = $_.FullName.Replace($HVOverlayPath, $HVDecompiledPath)
    Copy-Item -Path $_.FullName -Destination $Destination -Force
}

# Create solution file
Push-Location
Set-Location $HVDecompiledPath
dotnet new sln -n Microsoft.Virtualization.Client
Get-Item *\*.csproj | ForEach-Object { dotnet sln add (Resolve-Path $_ -Relative) }
Pop-Location
