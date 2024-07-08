<#
DESCRIPTION   This script will create a configured Remote Desktop Session Farm.
Author:         Julian Mooren | https://citrixguyblog.com
Contributor:    Sander van Gelderen | https://www.van-gelderen.eu
Creation Date:  12.05.17 
Change Date:    09.02.18
#>

#Requires -version 4.0
#Requires -RunAsAdministrator

#Functions
function Test-PsRemoting {
    param(
        [Parameter(Mandatory = $true)]
        $computername
    )
   
    try {
        $errorActionPreference = "Stop"
        $result = Invoke-Command -ComputerName $computername { 1 }
    }
    catch {
        Write-Verbose $_
        return $false
    }
   
    if ($result -ne 1) {
        Write-Verbose "Remoting to $computerName returned an unexpected result."
        return $false
    }
   
    $true   
} # end Test-PsRemoting

# General Settings
$configpath = "C:\rds\config.json"
$StartDate = Get-Date
$Vendor = "Microsoft"
$Product = "Remote Desktop Farm"
$Version = "2016"
$LogPath = Join-Path -Path "${env:SystemRoot}\Temp" -ChildPath "$Vendor $Product $Version.log"

try {
    Start-Transcript -Path $LogPath
} catch {
    Write-Verbose "Transcription cannot be started: $_"
}

#region "Check Prerequisites"
Write-Verbose "Check Prerequisites" -Verbose

# Check if necessary features are installed
if (Get-WindowsFeature -Name RSAT-AD-Tools, RSAT-DNS-Server) {
   Write-Verbose "Needed PowerShell Modules available." -Verbose
} else {    
    Write-Verbose "Needed PowerShell Modules will be installed." -Verbose
    Install-WindowsFeature RSAT-AD-Tools, RSAT-DNS-Server
    Write-Verbose "Needed PowerShell Modules have been installed." -Verbose
}

# Import Configuration
if (Test-Path -Path $configpath) {
    Write-Verbose "JSON File was found." -Verbose
    $config = Get-Content -Path $configpath -Raw | ConvertFrom-Json
    Write-Verbose "JSON File was imported." -Verbose
} else {
    Write-Error "Failed to find the JSON File."
    break
}

# Import Active Directory Module and Create AD Groups
Import-Module -Name ActiveDirectory
$NameRDSAccessGroup = $config.RDSAccessGroup.Split('@')[0]
if (-not (Get-ADGroup -Filter {Name -eq $NameRDSAccessGroup})) {
    New-ADGroup -Name $NameRDSAccessGroup -DisplayName $NameRDSAccessGroup -GroupCategory Security -GroupScope Global
} else {
    Write-Verbose "AD Group $NameRDSAccessGroup already exists." -Verbose
}

#endregion "Check Prerequisites"

#region TEST

# Check PSRemoting on hosts
$remoteHosts = @($config.RDSHost01, $config.RDSHost02, $config.ConnectionBroker01)
foreach ($remoteHost in $remoteHosts) {
    if (-not (Test-PsRemoting -computername $remoteHost)) {
        Write-Error "PSRemoting is not enabled on $remoteHost."
        break
    }
}

# Verify Profile
