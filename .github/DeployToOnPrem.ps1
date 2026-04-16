[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true)]
    [hashtable]$parameters
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-TemporaryFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath
    )

    $tempPath = Join-Path -Path $BasePath -ChildPath '_temp'
    New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
    return $tempPath
}

function Get-Script {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptUrl,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    if (-not (Test-Path -Path $OutputPath)) {
        throw "Output path '$OutputPath' does not exist."
    }

    Write-Host "Downloading $ScriptUrl..."
    Write-Host "::debug::Downloading $ScriptUrl"

    $fileName = [System.IO.Path]::GetFileName($ScriptUrl)
    $scriptPath = Join-Path -Path $OutputPath -ChildPath $fileName
    Invoke-WebRequest -Uri $ScriptUrl -OutFile $scriptPath

    Write-Host "Downloaded $ScriptUrl to $scriptPath"
    return $scriptPath
}

function Resolve-ServiceInstance {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$DeploymentParameters
    )

    if (-not [string]::IsNullOrWhiteSpace($DeploymentParameters.EnvironmentName)) {
        return $DeploymentParameters.EnvironmentName
    }

    throw 'Unable to resolve service instance. Set DeployTo...ServerInstance in AL-Go settings.'
}

function Test-ServiceInstanceExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceInstance
    )

    $services = @(Get-CimInstance -ClassName Win32_Service | Where-Object {
        $_.Name.ToUpper().Contains('NAVSERVER')
    })

    $match = @($services | Where-Object {
        $_.Name.ToUpper().Contains($ServiceInstance.ToUpper())
    })

    if ($match.Count -gt 0) {
        return
    }

    Write-Host "::error::No Business Central/NAV service found for service instance '$ServiceInstance'."
    Write-Host '::group::Available NAV/BC services'
    $services | Select-Object -ExpandProperty Name | ForEach-Object { Write-Host $_ }
    Write-Host '::endgroup::'

    throw "Invalid service instance '$ServiceInstance'."
}

function Get-AppFilesToDeploy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TempPath,
        [Parameter(Mandatory = $true)]
        [string]$WorkspacePath,
        [Parameter(Mandatory = $false)]
        [object]$InputAppFiles
    )

    if ($InputAppFiles) {
        Copy-AppFilesToFolder -appFiles $InputAppFiles -folder $TempPath | Out-Null
    }

    $apps = @(Get-ChildItem -Path $TempPath -Filter '*.app' -Recurse -File)
    if ($apps.Count -gt 0) {
        return $apps
    }

    $artifactsFolder = Join-Path -Path $WorkspacePath -ChildPath '.artifacts'
    if (Test-Path -Path $artifactsFolder) {
        Write-Host "No apps found via parameters.apps; searching '$artifactsFolder' recursively..."
        $apps = @(Get-ChildItem -Path $artifactsFolder -Filter '*.app' -Recurse -File)
    }

    if ($apps.Count -gt 0) {
        return $apps
    }

    Write-Host "::error::No apps to publish found under '$TempPath'."
    Write-Host '::group::Files in temp folder'
    Get-ChildItem -Path $TempPath -Recurse | Select-Object -ExpandProperty FullName | ForEach-Object { Write-Host $_ }
    Write-Host '::endgroup::'

    if (Test-Path -Path $artifactsFolder) {
        Write-Host '::group::Files in artifacts folder'
        Get-ChildItem -Path $artifactsFolder -Recurse | Select-Object -ExpandProperty FullName | ForEach-Object { Write-Host $_ }
        Write-Host '::endgroup::'
    }

    throw 'No apps to publish found.'
}

$workspacePath = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) { $env:GITHUB_WORKSPACE } else { $PWD.Path }
$serviceInstance = Resolve-ServiceInstance -DeploymentParameters $parameters
$scriptUrl = 'https://raw.githubusercontent.com/Harmonize-it/ALGO/refs/heads/main/Update-NavAPP.ps1'

Write-Host "Deployment Type (CD or Release): $($parameters.type)"
Write-Host "Environment Type: $($parameters.EnvironmentType)"
Write-Host "Environment Name: $($parameters.EnvironmentName)"
Write-Host "BC Service Instance: $serviceInstance"

$currentLocation = Get-Location
$tempPath = New-TemporaryFolder -BasePath $workspacePath

try {
    Set-Location -Path $tempPath
    Get-Script -ScriptUrl $scriptUrl -OutputPath $tempPath | Out-Null

    Test-ServiceInstanceExists -ServiceInstance $serviceInstance
    $appsList = Get-AppFilesToDeploy -TempPath $tempPath -WorkspacePath $workspacePath -InputAppFiles $parameters.apps

    Write-Host 'Apps:'
    foreach ($app in $appsList) {
        $appPath = $app.FullName
        Write-Host "Processing app file: $appPath"
        .\Update-NAVApp.ps1 -appPath $appPath -srvInst $serviceInstance
    }
}
finally {
    Set-Location -Path $currentLocation
}