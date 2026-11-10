Param(
    [Parameter(Mandatory = $true)]
    [Hashtable] $parameters
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'


function Get-ParameterValue {
    Param(
        [Parameter(Mandatory = $true)]
        [Hashtable] $InputObject,

        [Parameter(Mandatory = $true)]
        [string[]] $Names,

        [Parameter(Mandatory = $false)]
        $DefaultValue = $null
    )

    foreach ($name in $Names) {
        if (
            $InputObject.ContainsKey($name) -and
            $null -ne $InputObject[$name] -and
            -not [string]::IsNullOrWhiteSpace([string]$InputObject[$name])
        ) {
            return $InputObject[$name]
        }
    }

    return $DefaultValue
}


function Get-BCServicePath {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $ServerInstance
    )

    $expectedServiceName = "MicrosoftDynamicsNavServer`$$ServerInstance"

    Write-Host "Looking for Business Central service '$expectedServiceName'"

    $service = Get-CimInstance -ClassName Win32_Service |
        Where-Object {
            $_.Name -ieq $expectedServiceName
        } |
        Select-Object -First 1

    if (-not $service) {
        Write-Host 'Exact service name was not found. Trying fallback matching.'

        $service = Get-CimInstance -ClassName Win32_Service |
            Where-Object {
                $_.Name -like "*NavServer*$ServerInstance*"
            } |
            Select-Object -First 1
    }

    if (-not $service) {
        throw "Could not find a Business Central service for server instance '$ServerInstance'."
    }

    Write-Host "Found Business Central service '$($service.Name)'"
    Write-Host "Service PathName: '$($service.PathName)'"

    $pathName = [string]$service.PathName

    if ([string]::IsNullOrWhiteSpace($pathName)) {
        throw "The PathName of service '$($service.Name)' is empty."
    }

    # Do not split on whitespace because the executable path can contain spaces
    # and isn't necessarily enclosed in quotes.
    $exeIndex = $pathName.IndexOf(
        '.exe',
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if ($exeIndex -lt 0) {
        throw "Could not find the executable in service PathName '$pathName'."
    }

    $serviceExe = $pathName.Substring(0, $exeIndex + 4).Trim()
    $serviceExe = $serviceExe.Trim('"')

    Write-Host "Business Central service executable: '$serviceExe'"

    if (-not (Test-Path -LiteralPath $serviceExe -PathType Leaf)) {
        throw "Business Central service executable '$serviceExe' does not exist."
    }

    $servicePath = Split-Path -Path $serviceExe -Parent

    if (-not (Test-Path -LiteralPath $servicePath -PathType Container)) {
        throw "Business Central service directory '$servicePath' does not exist."
    }

    Write-Host "Business Central service path: '$servicePath'"

    return $servicePath
}


function Get-BCAppManagementModule {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $ServicePath
    )

    #
    # BC28 and older
    #
    # The compatibility DLL combines the required management and app
    # management cmdlets and works with Windows PowerShell 5.1.
    #
    $legacyManagementDLL = Get-ChildItem `
        -Path $ServicePath `
        -Filter 'Microsoft.Dynamics.Nav.Management.dll' `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '[\\/]LegacyDlls[\\/]'
        } |
        Sort-Object {
            ($_.FullName -split '[\\/]').Count
        } |
        Select-Object -Last 1

    if ($legacyManagementDLL) {
        Write-Host 'Found BC28 or older management DLL:'
        Write-Host "  $($legacyManagementDLL.FullName)"

        return [PSCustomObject]@{
            Generation     = 'BC28 or older'
            ModulePath     = $legacyManagementDLL.FullName
            RequiresPwsh7  = $false
        }
    }

    #
    # BC29+
    #
    # Only the Apps Management DLL is required by this deployment script.
    #
    $bcAppsManagementDLL = Join-Path `
        -Path $ServicePath `
        -ChildPath 'Admin\Microsoft.BusinessCentral.Apps.Management.dll'

    if (Test-Path -LiteralPath $bcAppsManagementDLL -PathType Leaf) {
        Write-Host 'Found BC29+ app management DLL:'
        Write-Host "  $bcAppsManagementDLL"

        return [PSCustomObject]@{
            Generation     = 'BC29+'
            ModulePath     = $bcAppsManagementDLL
            RequiresPwsh7  = $true
        }
    }

    throw "Could not locate a supported Business Central app-management DLL under '$ServicePath'."
}


function Import-BCAppManagementModule {
    Param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $ModuleInformation
    )

    if (
        $ModuleInformation.RequiresPwsh7 -and
        (
            $PSVersionTable.PSEdition -ne 'Core' -or
            $PSVersionTable.PSVersion.Major -lt 7
        )
    ) {
        throw @"
BC29 or newer was detected, but this script is running under Windows PowerShell $($PSVersionTable.PSVersion).

BC29 app-management DLLs must be loaded using PowerShell 7.

Configure the AL-Go deployment environment with:

    "shell": "pwsh"

Detected DLL:
$($ModuleInformation.ModulePath)
"@
    }

    $modulesToRemove = @(
        'Microsoft.Dynamics.Nav.Management',
        'Microsoft.Dynamics.Nav.Apps.Management',
        'Microsoft.BusinessCentral.Management',
        'Microsoft.BusinessCentral.Apps.Management'
    )

    foreach ($moduleName in $modulesToRemove) {
        Remove-Module `
            -Name $moduleName `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Host 'Importing Business Central app-management DLL:'
    Write-Host "  $($ModuleInformation.ModulePath)"

    Import-Module `
        -Name $ModuleInformation.ModulePath `
        -Force `
        -ErrorAction Stop

    $requiredCommands = @(
        'Get-NAVAppInfo',
        'Publish-NAVApp',
        'Sync-NAVApp',
        'Install-NAVApp',
        'Start-NAVAppDataUpgrade'
    )

    foreach ($commandName in $requiredCommands) {
        $command = Get-Command `
            -Name $commandName `
            -ErrorAction SilentlyContinue

        if (-not $command) {
            throw "Required Business Central cmdlet '$commandName' is unavailable after importing '$($ModuleInformation.ModulePath)'."
        }
    }

    Write-Host 'Required Business Central app-management cmdlets are available.'
}


function Copy-StandaloneAppFiles {
    Param(
        [Parameter(Mandatory = $false)]
        [Object[]] $AppFiles,

        [Parameter(Mandatory = $true)]
        [string] $Destination
    )

    foreach ($appFile in @($AppFiles)) {
        if ($null -eq $appFile) {
            continue
        }

        $sourcePath = [string]$appFile

        if ([string]::IsNullOrWhiteSpace($sourcePath)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "App file '$sourcePath' does not exist."
        }

        if ([System.IO.Path]::GetExtension($sourcePath) -ine '.app') {
            throw "File '$sourcePath' is not a Business Central .app file."
        }

        Copy-Item `
            -LiteralPath $sourcePath `
            -Destination $Destination `
            -Force `
            -ErrorAction Stop
    }
}


function Resolve-AppList {
    Param(
        [Parameter(Mandatory = $false)]
        [Object[]] $Apps,

        [Parameter(Mandatory = $false)]
        [Object[]] $Dependencies
    )

    $tempPath = Join-Path `
        -Path ([System.IO.Path]::GetTempPath()) `
        -ChildPath ([Guid]::NewGuid().ToString())

    New-Item `
        -Path $tempPath `
        -ItemType Directory `
        -Force `
        -ErrorAction Stop |
        Out-Null

    try {
        $copyAppFilesCommand = Get-Command `
            -Name 'Copy-AppFilesToFolder' `
            -ErrorAction SilentlyContinue

        if ($copyAppFilesCommand) {
            #
            # AL-Go / BcContainerHelper execution context.
            #
            Write-Host 'Using AL-Go Copy-AppFilesToFolder helper.'

            if ($Dependencies -and $Dependencies.Count -gt 0) {
                Copy-AppFilesToFolder `
                    -appFiles $Dependencies `
                    -folder $tempPath |
                    Out-Null
            }

            if ($Apps -and $Apps.Count -gt 0) {
                Copy-AppFilesToFolder `
                    -appFiles $Apps `
                    -folder $tempPath |
                    Out-Null
            }
        }
        else {
            #
            # Standalone PowerShell execution context.
            #
            Write-Host 'Copy-AppFilesToFolder is unavailable. Using standalone file copying.'

            Copy-StandaloneAppFiles `
                -AppFiles $Dependencies `
                -Destination $tempPath

            Copy-StandaloneAppFiles `
                -AppFiles $Apps `
                -Destination $tempPath
        }

        $appFiles = @(
            Get-ChildItem `
                -LiteralPath $tempPath `
                -Filter '*.app' `
                -File `
                -ErrorAction Stop |
            Sort-Object -Property Name |
            ForEach-Object {
                $_.FullName
            }
        )

        if ($appFiles.Count -eq 0) {
            throw 'No .app files were found for deployment.'
        }

        return [PSCustomObject]@{
            TempPath = $tempPath
            AppFiles = $appFiles
        }
    }
    catch {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item `
                -LiteralPath $tempPath `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

        throw
    }
}


function Get-InstalledNAVApp {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $ServerInstance,

        [Parameter(Mandatory = $true)]
        [string] $Tenant,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Publisher
    )

    $getNAVAppInfoCommand = Get-Command `
        -Name 'Get-NAVAppInfo' `
        -ErrorAction Stop

    $getAppInfoParameters = @{
        ServerInstance = $ServerInstance
        Name           = $Name
        Publisher      = $Publisher
        ErrorAction    = 'SilentlyContinue'
    }

    if ($getNAVAppInfoCommand.Parameters.ContainsKey('Tenant')) {
        $getAppInfoParameters['Tenant'] = $Tenant
    }

    if ($getNAVAppInfoCommand.Parameters.ContainsKey('TenantSpecificProperties')) {
        $getAppInfoParameters['TenantSpecificProperties'] = $true
    }

    $appVersions = @(
        Get-NAVAppInfo @getAppInfoParameters
    )

    if ($appVersions.Count -eq 0) {
        return $null
    }

    $appsWithInstalledState = @(
        $appVersions |
            Where-Object {
                $_.PSObject.Properties.Name -contains 'IsInstalled'
            }
    )

    if ($appsWithInstalledState.Count -gt 0) {
        $installedApps = @(
            $appsWithInstalledState |
                Where-Object {
                    $_.IsInstalled -eq $true
                }
        )

        if ($installedApps.Count -eq 0) {
            return $null
        }

        return $installedApps |
            Sort-Object -Property Version -Descending |
            Select-Object -First 1
    }

    #
    # Older cmdlets don't always expose the tenant-specific IsInstalled
    # property. Preserve the previous behavior in that situation.
    #
    return $appVersions |
        Sort-Object -Property Version -Descending |
        Select-Object -First 1
}


function Deploy-NavAppFile {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $AppPath,

        [Parameter(Mandatory = $true)]
        [string] $ServerInstance,

        [Parameter(Mandatory = $true)]
        [string] $Tenant,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Add', 'Clean', 'Development', 'ForceSync')]
        [string] $SyncMode = 'Add'
    )

    if (-not (Test-Path -LiteralPath $AppPath -PathType Leaf)) {
        throw "App file '$AppPath' does not exist."
    }

    $appInfo = Get-NAVAppInfo `
        -Path $AppPath `
        -ErrorAction Stop

    if (-not $appInfo) {
        throw "Unable to read app metadata from '$AppPath'."
    }

    $appName = [string]$appInfo.Name
    $appPublisher = [string]$appInfo.Publisher
    $appVersion = [string]$appInfo.Version

    if ([string]::IsNullOrWhiteSpace($appName)) {
        throw "App name is missing from '$AppPath'."
    }

    if ([string]::IsNullOrWhiteSpace($appPublisher)) {
        throw "App publisher is missing from '$AppPath'."
    }

    if ([string]::IsNullOrWhiteSpace($appVersion)) {
        throw "App version is missing from '$AppPath'."
    }

    $installedApp = Get-InstalledNAVApp `
        -ServerInstance $ServerInstance `
        -Tenant $Tenant `
        -Name $appName `
        -Publisher $appPublisher

    $previousConfirmPreference = $ConfirmPreference
    $ConfirmPreference = 'None'

    try {
        Write-Host ''
        Write-Host '============================================================'
        Write-Host 'Deploying app'
        Write-Host "  Name              : $appName"
        Write-Host "  Publisher         : $appPublisher"
        Write-Host "  Target version    : $appVersion"
        Write-Host "  Server instance   : $ServerInstance"
        Write-Host "  Tenant            : $Tenant"
        Write-Host "  Sync mode         : $SyncMode"

        if ($installedApp) {
            Write-Host "  Installed version : $($installedApp.Version)"
        }
        else {
            Write-Host '  Installed version : Not installed'
        }

        Write-Host '============================================================'

        Write-Host "Publishing $appName ($appVersion)"

        Publish-NAVApp `
            -ServerInstance $ServerInstance `
            -Path $AppPath `
            -SkipVerification `
            -ErrorAction Stop

        Write-Host "Syncing $appName ($appVersion) with mode '$SyncMode'"

        Sync-NAVApp `
            -ServerInstance $ServerInstance `
            -Tenant $Tenant `
            -Name $appName `
            -Publisher $appPublisher `
            -Version $appVersion `
            -Mode $SyncMode `
            -Force `
            -ErrorAction Stop

        if ($installedApp) {
            Write-Host "Starting data upgrade for $appName ($appVersion)"

            Start-NAVAppDataUpgrade `
                -ServerInstance $ServerInstance `
                -Tenant $Tenant `
                -Name $appName `
                -Publisher $appPublisher `
                -Version $appVersion `
                -Force `
                -ErrorAction Stop
        }
        else {
            Write-Host "Installing $appName ($appVersion)"

            Install-NAVApp `
                -ServerInstance $ServerInstance `
                -Tenant $Tenant `
                -Name $appName `
                -Publisher $appPublisher `
                -Version $appVersion `
                -Force `
                -ErrorAction Stop
        }

        Write-Host "Successfully deployed $appName ($appVersion)"
    }
    finally {
        $ConfirmPreference = $previousConfirmPreference
    }
}


#
# Resolve deployment parameters
#

$serverInstance = Get-ParameterValue `
    -InputObject $parameters `
    -Names @(
        'ServerInstance',
        'BCServerInstance',
        'InstanceName',
        'EnvironmentName'
    )

if (-not $serverInstance) {
    throw 'Missing ServerInstance. Add ServerInstance to the deployment settings or set EnvironmentName to the Business Central service instance name.'
}

$serverInstance = [string]$serverInstance

$tenant = [string](
    Get-ParameterValue `
        -InputObject $parameters `
        -Names @(
            'Tenant',
            'tenant'
        ) `
        -DefaultValue 'default'
)

$syncMode = [string](
    Get-ParameterValue `
        -InputObject $parameters `
        -Names @('SyncMode') `
        -DefaultValue 'Add'
)

$deploymentType = [string](
    Get-ParameterValue `
        -InputObject $parameters `
        -Names @(
            'type',
            'Type'
        ) `
        -DefaultValue ''
)

$environmentType = [string](
    Get-ParameterValue `
        -InputObject $parameters `
        -Names @('EnvironmentType') `
        -DefaultValue ''
)

if ($syncMode -notin @('Add', 'Clean', 'Development', 'ForceSync')) {
    throw "Unsupported SyncMode '$syncMode'. Supported values are Add, Clean, Development and ForceSync."
}


Write-Host ''
Write-Host '============================================================'
Write-Host 'Business Central Deployment'
Write-Host '============================================================'
Write-Host "Deployment Type : $deploymentType"
Write-Host "Environment Type: $environmentType"
Write-Host "Server Instance : $serverInstance"
Write-Host "Tenant          : $tenant"
Write-Host "Sync Mode      .PSEdition)"
Write-Host '============================================================'
Write-Host ''


#
# Find and import the correct app-management DLL.
#

$servicePath = Get-BCServicePath `
    -ServerInstance $serverInstance

$moduleInformation = Get-BCAppManagementModule `
    -ServicePath $servicePath

Write-Host "Detected Business Central generation: $($moduleInformation.Generation)"

Import-BCAppManagementModule `
    -ModuleInformation $moduleInformation


#
# Resolve and deploy app files.
#

$tempPath = $null

try {
    $apps = if ($parameters.ContainsKey('Apps')) {
        @($parameters['Apps'])
    }
    else {
        @()
    }

    $dependencies = if ($parameters.ContainsKey('Dependencies')) {
        @($parameters['Dependencies'])
    }
    else {
        @()
    }

    $resolvedApps = Resolve-AppList `
        -Apps $apps `
        -Dependencies $dependencies

    $tempPath = $resolvedApps.TempPath
    $appFiles = @($resolvedApps.AppFiles)

    Write-Host ''
    Write-Host 'Apps to deploy:'

    foreach ($appFile in $appFiles) {
        Write-Host "- $([System.IO.Path]::GetFileName($appFile))"
    }

    foreach ($appFile in $appFiles) {
        Deploy-NavAppFile `
            -AppPath $appFile `
            -ServerInstance $serverInstance `
            -Tenant $tenant `
            -SyncMode $syncMode
    }
}
finally {
    if (
        $tempPath -and
        (Test-Path -LiteralPath $tempPath)
    ) {
        Write-Host "Cleaning temporary deployment folder '$tempPath'"

        Remove-Item `
            -LiteralPath $tempPath `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}


Write-Host ''
Write-Host '============================================================'
Write-Host 'Deployment completed successfully.'
Write-Host '============================================================'
