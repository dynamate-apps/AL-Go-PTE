Param(
    [Parameter(Mandatory = $true)]
    [Hashtable] $parameters
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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
        if ($InputObject.ContainsKey($name) -and $null -ne $InputObject.$name -and "$($InputObject.$name)" -ne '') {
            return $InputObject.$name
        }
    }

    return $DefaultValue
}

function Get-NAVServiceDLL  {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $ServerInstance
    )  
    Remove-Module Microsoft.Dynamics.Nav.Management -Force -ErrorAction SilentlyContinue    
 
    $path = ([string](Get-WmiObject win32_service | ?{$_.Name.ToString().ToUpper() -like "*NavServer*$ServerInstance*"} | select PathName).PathName).ToUpper()
    $shortPath = $path.Substring(0,$path.IndexOf("EXE") + 3)
    if ($shortPath.StartsWith('"'))
    {
        $shortPath = $shortPath.Remove(0,1)
    }
 
    $PowerShellDLL = (Get-ChildItem -recurse -Path ((Get-ChildItem $ShortPath).Directory.FullName) "Microsoft.Dynamics.Nav.Management.DLL" | Sort-Object { ($_.FullName -split '\\').Count } | Select-Object -Last 1).FullName
            
    return $PowerShellDLL  
}

function Get-NAVAppMgtDLL {
    param([string] $ServerInstance)
    
    Remove-Module Microsoft.Dynamics.Nav.Management -Force -ErrorAction SilentlyContinue    
 
    $path = ([string](Get-WmiObject win32_service | ?{$_.Name.ToString().ToUpper() -like "*NavServer*$ServerInstance*"} | select PathName).PathName).ToUpper()
    $shortPath = $path.Substring(0,$path.IndexOf("EXE") + 3)
    if ($shortPath.StartsWith('"'))
    {
        $shortPath = $shortPath.Remove(0,1)
    }
 
    $PowerShellDLL = (Get-ChildItem -recurse -Path ((Get-ChildItem $ShortPath).Directory.FullName) "Microsoft.Dynamics.Nav.Apps.Management.DLL" | Sort-Object { ($_.FullName -split '\\').Count } | Select-Object -Last 1).FullName
            
    return $PowerShellDLL    
}

function Resolve-AppList {
    Param(
        [Parameter(Mandatory = $false)]
        [Object[]] $Apps,
        [Parameter(Mandatory = $false)]
        [Object[]] $Dependencies
    )

    $tempPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([Guid]::NewGuid().ToString())
    New-Item -Path $tempPath -ItemType Directory | Out-Null

    try {
        if ($Dependencies) {
            Copy-AppFilesToFolder -appFiles $Dependencies -folder $tempPath | Out-Null
        }
        if ($Apps) {
            Copy-AppFilesToFolder -appFiles $Apps -folder $tempPath | Out-Null
        }

        $appFiles = @(Get-ChildItem -Path $tempPath -Filter '*.app' -File | Sort-Object -Property Name | ForEach-Object { $_.FullName })
        if (-not $appFiles -or $appFiles.Count -eq 0) {
            throw 'No .app files were found for deployment.'
        }

        return $tempPath, $appFiles
    }
    catch {
        if (Test-Path -Path $tempPath) {
            Remove-Item -Path $tempPath -Recurse -Force
        }
        throw
    }
}

function Deploy-NavAppFile {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $AppPath,
        [Parameter(Mandatory = $true)]
        [string] $ServerInstance,
        [Parameter(Mandatory = $true)]
        [string] $Tenant
    )

    $appInfo = Get-NAVAppInfo -Path $AppPath
    if (-not $appInfo) {
        throw "Unable to read app metadata from '$AppPath'."
    }

    $appName = $appInfo.Name
    $appPublisher = $appInfo.Publisher
    $appVersion = $appInfo.Version

    $previousInstalledVersions = @(
        Get-NAVAppInfo -ServerInstance $ServerInstance -Name $appName -Publisher $appPublisher -ErrorAction SilentlyContinue
    )
    $hasPreviousInstalledVersion = ($previousInstalledVersions.Count -gt 0)

    Write-Host "Publishing $appName ($appVersion)"
    Publish-NAVApp -ServerInstance $ServerInstance -Path $AppPath -SkipVerification

    Write-Host "Syncing $appName ($appVersion)"
    Sync-NAVApp -ServerInstance $ServerInstance -Tenant $Tenant -Name $appName -Publisher $appPublisher -Version $appVersion

    if ($hasPreviousInstalledVersion) {
        Write-Host "Starting data upgrade for $appName ($appVersion)"
        Start-NAVAppDataUpgrade -ServerInstance $ServerInstance -Tenant $Tenant -Name $appName -Publisher $appPublisher -Version $appVersion
    }
    else {
        Write-Host "Installing $appName ($appVersion)"
        Install-NAVApp -ServerInstance $ServerInstance -Tenant $Tenant -Name $appName -Publisher $appPublisher -Version $appVersion
    }
}

$serverInstance = Get-ParameterValue -InputObject $parameters -Names @('ServerInstance', 'BCServerInstance', 'InstanceName', 'EnvironmentName')
if (-not $serverInstance) {
    throw 'Missing ServerInstance. Add ServerInstance to DeployTo<EnvironmentName> settings or set EnvironmentName to the BC service instance name.'
}

$tenant = Get-ParameterValue -InputObject $parameters -Names @('Tenant', 'tenant') -DefaultValue 'default'

Write-Host "Deployment Type (CD or Publish): $($parameters.type)"
Write-Host "Environment Type: $($parameters.EnvironmentType)"
Write-Host "Server Instance: $serverInstance"
Write-Host "Tenant: $tenant"

$managementDLL = Get-NAVServiceDLL -ServerInstance $serverInstance
Write-Host "Importing management dll from '$managementDLL'"
Import-Module $managementDLL

$appManagementDLL = Get-NAVAppMgtDLL -ServerInstance $serverInstance
Write-Host "Importing app dll from '$appManagementDLL'"
Import-Module $appManagementDLL

$tempPath = $null
try {
    $tempPath, $appFiles = Resolve-AppList -Apps $parameters.Apps -Dependencies $parameters.Dependencies

    Write-Host "Apps to deploy:"
    $appFiles | ForEach-Object { Write-Host "- $([System.IO.Path]::GetFileName($_))" }

    foreach ($appFile in $appFiles) {
        Deploy-NavAppFile -AppPath $appFile -ServerInstance $serverInstance -Tenant $tenant
    }
}
finally {
    if ($tempPath -and (Test-Path -Path $tempPath)) {
        Remove-Item -Path $tempPath -Recurse -Force
    }
}
