
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
New-Item -Path $HVAssemblyPath -ItemType Directory -Force | Out-Null
New-Item -Path "$HVAssemblyPath\$HVAssemblyLang" -ItemType Directory -Force | Out-Null
$HVAssemblyNames | ForEach-Object {
    $HVResourceAssembly = "$HVAssemblyLang\$_.resources.dll"
    Copy-Item "$HVSourcePath\$_.dll" "$HVAssemblyPath\$_.dll" -Force
    Copy-Item "$HVSourcePath\$HVResourceAssembly" "$HVAssemblyPath\$HVResourceAssembly" -Force
}

$HVResourceAssembly = "$HVAssemblyLang\vmconnect.resources.dll"
Copy-Item "$Env:WinDir\System32\vmconnect.exe" "$HVAssemblyPath\vmconnect.exe" -Force
Copy-Item "$Env:WinDir\System32\$HVResourceAssembly" "$HVAssemblyPath\$HVResourceAssembly" -Force

$VirtMgmtRegPath = "HKLM\SOFTWARE\Microsoft\MMC\SnapIns\FX:{922180d7-b74e-45f6-8c74-4b560cc100a5}"
& reg export $VirtMgmtRegPath "$HVAssemblyPath\virtmgmt.reg" /y /reg:64

Copy-Item "$Env:WinDir\System32\virtmgmt.msc" "$HVAssemblyPath\virtmgmt.msc" -Force

# Decompile assemblies of interest
Remove-Item -Path $HVDecompiledPath -Recurse -Force
New-Item -Path $HVDecompiledPath -ItemType Directory -Force | Out-Null
$ILSpyCmdArgs = @('-lv', 'CSharp10_0')
Get-ChildItem $HVAssemblyPath "Microsoft.Virtualization.Client*.dll" | ForEach-Object {
    $HVAssemblyName = $_.BaseName
    $HVResourceAssembly = "$HVAssemblyLang\$HVAssemblyName.resources.dll"
    ilspycmd -p -o "$HVDecompiledPath\$HVAssemblyName" @ILSpyCmdArgs $_
    ilspycmd -p -o "$HVDecompiledPath\$HVAssemblyName\$HVAssemblyLang" @ILSpyCmdArgs "$HVAssemblyPath\$HVResourceAssembly"
}
Get-ChildItem $HVAssemblyPath "vmconnect.exe" | ForEach-Object {
    $HVAssemblyName = $_.BaseName
    $HVResourceAssembly = "$HVAssemblyLang\vmconnect.resources.dll"
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

# Apply overlay project files
$ExcludeFilter = @("*.cache","*.config","*.editorconfig","*AssemblyInfo.cs")
Get-ChildItem $HVOverlayPath -Recurse -File -Exclude $ExcludeFilter | ForEach-Object {
    $Destination = $_.FullName.Replace($HVOverlayPath, $HVDecompiledPath)
    Copy-Item -Path $_.FullName -Destination $Destination -Force
}

# Create solution file
Push-Location
Set-Location $HVDecompiledPath
dotnet new sln -n Microsoft.Virtualization.Client
Get-Item *\*.csproj | ForEach-Object { dotnet sln add (Resolve-Path $_ -Relative) }
Pop-Location

# Make sure there is no junk in the directory
Get-ChildItem "bin" -Recurse -Directory | Remove-Item -Recurse -Force
Get-ChildItem "obj" -Recurse -Directory | Remove-Item -Recurse -Force

# start tracking post-decompilation modifications
git init $HVDecompiledPath

git -C $HVDecompiledPath add -A
git --git-dir="$HVDecompiledPath/.git" commit -m "hvmanager: initial decompilation"

$Message = "Fix invalid generated accessors with special names"
Write-Host $Message

$csFiles = Get-ChildItem -Path $HVDecompiledPath -Filter "*.cs" -Include @("*Wizard*","*Dialog*","*Form*") -Recurse

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

git -C $HVDecompiledPath add -A
git --git-dir="$HVDecompiledPath/.git" commit -m "hvmanager: $Message"

$Message = "Fix RunPowershellScript runspace.CreatePipeline call"
Write-Host $Message

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

$newContent = $fileContent -Replace $pattern, $replacement
Set-Content -Path $filePath -Value $newContent

git -C $HVDecompiledPath add -A
git --git-dir="$HVDecompiledPath/.git" commit -m "hvmanager: $Message"

$Message = "Fix RDP ActiveX interop namespace"
Write-Host $Message

$Pattern = "Microsoft.Virtualization.Client.Interop"
$Replacement = "MSTSCLib"
rg $Pattern $HVDecompiledPath -l -t cs | % { $_ -Split "\r?\n" | % {
    $NewContent = rg $Pattern $_ -r $Replacement -N --passthru
    Set-Content -Path $_ -Value $NewContent
} }

git -C $HVDecompiledPath add -A
git --git-dir="$HVDecompiledPath/.git" commit -m "hvmanager: $Message"

$Message = "Fix System.Windows.Forms DpiChanged conflict"
Write-Host $Message

$Pattern = "DpiChanged"
$Replacement = "MyDpiChanged"
rg $Pattern $HVDecompiledPath -l -t cs | % { $_ -Split "\r?\n" | % {
    if (-Not $_.EndsWith("NoConnectionDialog.cs")) {
        Write-Host $_
        $NewContent = rg $Pattern $_ -r $Replacement -N --passthru
        Set-Content -Path $_ -Value $NewContent
    }
} }
$Pattern = "IDpiForm"
$Replacement = "IMyDpiForm"
rg $Pattern $HVDecompiledPath -l -t cs | % { $_ -Split "\r?\n" | % {
    Write-Host $_
    $NewContent = rg $Pattern $_ -r $Replacement -N --passthru
    Set-Content -Path $_ -Value $NewContent
} }

git -C $HVDecompiledPath add -A
git --git-dir="$HVDecompiledPath/.git" commit -m "hvmanager: $Message"
