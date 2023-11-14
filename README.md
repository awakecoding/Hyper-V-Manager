# Hyper-V Manager: Unofficial Patching

## Recompiling Hyper-V Manager from source

Install the [ILSpy](https://github.com/icsharpcode/ILSpy) command-line tool:

```powershell
dotnet tool install ilspycmd -g
```

Install [ripgrep](https://github.com/BurntSushi/ripgrep#installation):

```powershell
winget install BurntSushi.ripgrep.MSVC
```

Bootstrap the decompiled project:

```powershell
.\bootstrap.ps1
```

Enter a Visual Studio developer environment and build the decompiled project:

```powershell
Install-Module -Name VsDevShell
Enter-VsDevShell
cd Decompiled && dotnet restore && msbuild
start .\Microsoft.Virtualization.Client.sln
```

You should now have a buildable Visual Studio solution:

![Visual Studio Project](./screenshot.png)

Running the recompiled project is still a work in progress partially covered in the next section.

## Running recompiled Hyper-V Manager (WIP)

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

Normally, this should work the same way as the original Hyper-V Manager, except we've used different GUIDs internally.
