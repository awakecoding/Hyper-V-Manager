
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
Get-ChildItem $HVDecompiledPath *.en.resx -Recurse | ForEach-Object { Move-Item $_ $_.Directory.Parent }

# Fix missing empty Microsoft.Virtualization.Client.InteractiveSessionForm.resx file
$InteractiveSessionPrefix = "Microsoft.Virtualization.Client.InteractiveSession"
$InputResxFile = Join-Path $HVDecompiledPath "vmconnect" "${InteractiveSessionPrefix}.ConnectionDialog.resx"
$OutputResxFile = Join-Path $HVDecompiledPath "vmconnect" "${InteractiveSessionPrefix}.InteractiveSessionForm.resx"
$NewContent = rg "<data name=.*</data>" $InputResxFile -r "" -N --passthru
Set-Content -Path $OutputResxFile -Value $NewContent -Force

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

$Message = "Fix noconnectiondialog.xaml resource embedding"

$NoConnectionDialogBaml = Join-Path $HVDecompiledPath "vmconnect\noconnectiondialog.baml"
Remove-Item $NoConnectionDialogBaml -ErrorAction SilentlyContinue | Out-Null

$InteractiveSessionPrefix = "Microsoft.Virtualization.Client.InteractiveSession"
$NoConnectionDialog = Join-Path $HVDecompiledPath "vmconnect\${InteractiveSessionPrefix}\NoConnectionDialog.cs"

$Pattern = "if\s\(!_contentLoaded\)\s+\{([^}]+)\}"
$Replacement = @"
    if (!_contentLoaded)
    {
        _contentLoaded = true;
        this.Width = 300;
        this.Height = 200;
        Grid grid = new Grid();
        grid.Background = new SolidColorBrush(Color.FromRgb(0x27, 0x27, 0x27));
        StackPanel stackPanel = new StackPanel();
        stackPanel.Width = Double.NaN; // Auto width
        stackPanel.VerticalAlignment = VerticalAlignment.Center;
        txtOne = new TextBlock();
        txtOne.HorizontalAlignment = HorizontalAlignment.Center;
        txtOne.Foreground = new SolidColorBrush(Colors.White);
        txtOne.TextWrapping = TextWrapping.Wrap;
        txtOne.FontSize = 14;
        txtOne.Text = "";
        txtTwo = new TextBlock();
        txtTwo.HorizontalAlignment = HorizontalAlignment.Center;
        txtTwo.Foreground = new SolidColorBrush(Colors.White);
        txtTwo.TextWrapping = TextWrapping.Wrap;
        txtTwo.Margin = new Thickness(0, 20, 0, 30);
        txtTwo.Text = "";
        btnTurnOn = new Button();
        btnTurnOn.HorizontalAlignment = HorizontalAlignment.Center;
        btnTurnOn.Foreground = new SolidColorBrush(Colors.White);
        btnTurnOn.Padding = new Thickness(15, 5, 15, 5);
        btnTurnOn.Background = new SolidColorBrush(Color.FromRgb(0x4C, 0x4B, 0x4B));
        btnTurnOn.BorderBrush = new SolidColorBrush(Color.FromRgb(0x3B, 0x3B, 0x3B));
        btnTurnOn.Content = "";
        btnResume = new Button();
        btnResume.HorizontalAlignment = HorizontalAlignment.Center;
        btnResume.Foreground = new SolidColorBrush(Colors.White);
        btnResume.Padding = new Thickness(15, 5, 15, 5);
        btnResume.Background = new SolidColorBrush(Color.FromRgb(0x4C, 0x4B, 0x4B));
        btnResume.BorderBrush = new SolidColorBrush(Color.FromRgb(0x3B, 0x3B, 0x3B));
        btnResume.Content = "";
        stackPanel.Children.Add(txtOne);
        stackPanel.Children.Add(txtTwo);
        stackPanel.Children.Add(btnTurnOn);
        stackPanel.Children.Add(btnResume);
        grid.Children.Add(stackPanel);
        this.Content = grid;
    }
"@

$FileContent = Get-Content $NoConnectionDialog -Raw
$NewContent = $FileContent -Replace $Pattern, $Replacement
Set-Content -Path $NoConnectionDialog -Value $NewContent

git -C $HVDecompiledPath add -A
git --git-dir="$HVDecompiledPath/.git" commit -m "hvmanager: $Message"

$Message = "Fix AssemblyLoader.cs to load files in custom paths"

$ClientCommonPrefix = "Microsoft.Virtualization.Client.Common"
$AssemblyLoaderFile = Join-Path $HVDecompiledPath "${ClientCommonPrefix}\${ClientCommonPrefix}\AssemblyLoader.cs"

$AssemblyLoaderData = @"
using System;
using System.Globalization;
using System.IO;
using System.Reflection;
using Microsoft.Win32;

namespace Microsoft.Virtualization.Client.Common;

internal class AssemblyLoader
{
	private const string gm_AssemblyNamePrefix = "Microsoft.Virtualization.Client";

	private static string gm_ApplicationBase;

	internal static string ApplicationBase
	{
		get
		{
			if (string.IsNullOrEmpty(gm_ApplicationBase))
			{
				try
				{
					using RegistryKey registryKey = Registry.LocalMachine.OpenSubKey("SOFTWARE\\Microsoft\\MMC\\SnapIns\\FX:{2c61a4aa-809e-11ee-b962-0242ac120002}");
					if (registryKey != null)
					{
						gm_ApplicationBase = (string)registryKey.GetValue("ApplicationBase");
					}
				}
				catch (Exception)
				{
					gm_ApplicationBase = string.Empty;
				}
			}
			return gm_ApplicationBase;
		}
	}

	static AssemblyLoader()
	{

	}

	internal static Assembly Load(HyperVAssemblyVersion assemblyVersion, HyperVComponent component)
	{
		return Assembly.Load(ConstructAssemblyName(assemblyVersion, component));
	}

	internal static string GetVmConnectFilePath(HyperVAssemblyVersion assemblyVersion)
	{
		string assemblyDirectory = GetAssemblyDirectory(HyperVComponent.VmConnect, assemblyVersion);
		string path = GetAssemblyFileName(HyperVComponent.VmConnect, assemblyVersion) + ".exe";
		return Path.Combine(assemblyDirectory, path);
	}

	internal static string GetInspectVhdDialogFilePath(HyperVAssemblyVersion assemblyVersion)
	{
		string assemblyDirectory = GetAssemblyDirectory(HyperVComponent.InspectVhdDialog, assemblyVersion);
		string path = GetAssemblyFileName(HyperVComponent.InspectVhdDialog, assemblyVersion) + ".exe";
		return Path.Combine(assemblyDirectory, path);
	}

	internal static string GetAssemblyDirectory(HyperVComponent component, HyperVAssemblyVersion assemblyVersion)
	{
		return ApplicationBase;
	}

	internal static string GetAssemblyFileName(HyperVComponent component, HyperVAssemblyVersion assemblyVersion)
	{
		return component.ToString();
	}

	private static AssemblyName ConstructAssemblyName(HyperVAssemblyVersion assemblyVersion, HyperVComponent component)
	{
		AssemblyName name = Assembly.GetExecutingAssembly().GetName();
		AssemblyName assemblyName = new AssemblyName(string.Format(CultureInfo.InvariantCulture, "{0}.{1}", gm_AssemblyNamePrefix, component.ToString()));
		assemblyName.Version = name.Version;
		assemblyName.SetPublicKeyToken(name.GetPublicKeyToken());
		assemblyName.CultureInfo = name.CultureInfo;
		return assemblyName;
	}
}
"@

Set-Content -Path $AssemblyLoaderFile -Value $AssemblyLoaderData -Force

git -C $HVDecompiledPath add -A
git --git-dir="$HVDecompiledPath/.git" commit -m "hvmanager: $Message"

$Message = "Fix CompliantTextBox.cs base.OnKeyUp(e)"

$CompliantTextBoxCs = Join-Path $HVDecompiledPath "Microsoft.Virtualization.Client\Microsoft.Virtualization.Client.Controls\CompliantTextBox.cs"

$Pattern = "\(\(Control\)this\)\.OnKeyUp\(e\);"
$Replacement = "base.OnKeyUp(e);"

$FileContent = Get-Content $CompliantTextBoxCs -Raw
$NewContent = $FileContent -Replace $Pattern, $Replacement
Set-Content -Path $CompliantTextBoxCs -Value $NewContent

git -C $HVDecompiledPath add -A
git --git-dir="$HVDecompiledPath/.git" commit -m "hvmanager: $Message"

$Message = "Fix ConfirmationPage.cs ambiguous Resources"

$ConfirmationPageCs = Join-Path $HVDecompiledPath "Microsoft.Virtualization.Client.Wizards\Microsoft.Virtualization.Client.Wizards.Framework\ConfirmationPage.cs"

$Pattern = "using Microsoft.Virtualization.Client.Wizards.Framework.Properties;"
$Replacement = @"
using Microsoft.Virtualization.Client.Wizards.Framework.Properties;
using Resources = Microsoft.Virtualization.Client.Wizards.Framework.Properties.Resources;
"@

$FileContent = Get-Content $ConfirmationPageCs -Raw
$NewContent = $FileContent -Replace $Pattern, $Replacement
Set-Content -Path $ConfirmationPageCs -Value $NewContent

git -C $HVDecompiledPath add -A
git --git-dir="$HVDecompiledPath/.git" commit -m "hvmanager: $Message"

$Message = "Change 'Before You Begin' by 'A New Beginning' in string resources"
Write-Host $Message

$Pattern = "Before You Begin"
$Replacement = "A New Beginning"
rg $Pattern $HVDecompiledPath -l -t cs | % { $_ -Split "\r?\n" | % {
    $NewContent = rg $Pattern $_ -r $Replacement -N --passthru
    Set-Content -Path $_ -Value $NewContent
} }

git -C $HVDecompiledPath add -A
git --git-dir="$HVDecompiledPath/.git" commit -m "hvmanager: $Message"
