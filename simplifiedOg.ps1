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

Start-Transcript -Path $LogPath

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

# Check for SSL Certificate
if (Test-Path -Path $config.CertPath) {
    Write-Verbose "SSL Certificate was found." -Verbose
} else {
    Write-Error "Failed to find the SSL Certificate."
    break
}

# Import Active Directory Module and Create AD Groups
Import-Module -Name ActiveDirectory
$NameRDSAccessGroup = $config.RDSAccessGroup.Split('@')[0]
New-ADGroup -Name $NameRDSAccessGroup -DisplayName $NameRDSAccessGroup -GroupCategory Security -GroupScope Global

#endregion "Check Prerequisites"

#region TEST

# Check PSRemoting on hosts
$hosts = @($config.RDSHost01, $config.RDSHost02, $config.ConnectionBroker01)
foreach ($host in $hosts) {
    if (-not (Test-PsRemoting -computername $host)) {
        Write-Error "PSRemoting is not enabled on $host."
        break
    }
}

# Verify Profile Disk Path
if (-not (Test-Path "$($config.ProfileDiskPath)")) {
    Write-Error "$($config.ProfileDiskPath) might have troubles"
    break
}

if (-not ($NameRDSAccessGroup)) {
    Write-Error "AD group $NameRDSAccessGroup does not exist."
    break
}

Read-Host "All Testing is done. Ready for the real stuff? -> Press enter to continue"

#endregion TEST

Write-Verbose "Starting Installation of $Vendor $Product $Version" -Verbose

# Import the RemoteDesktop Module
Import-Module -Name RemoteDesktop

# Create RDS deployment
New-RDSessionDeployment -ConnectionBroker $config.ConnectionBroker01 -SessionHost @($config.RDSHost01, $config.RDSHost02)
Write-Verbose "Created new RDS deployment" -Verbose

# Create Desktop Collection
New-RDSessionCollection -CollectionName $config.DesktopCollectionName -SessionHost @($config.RDSHost01, $config.RDSHost02) -CollectionDescription $config.DesktopDiscription -ConnectionBroker $config.ConnectionBroker01
Write-Verbose "Created new Desktop Collection" -Verbose

#region Default Configuration Parameters
##### Default Configuration Parameters ##### 

# Set Access Group for RDS Farm
Set-RDSessionCollectionConfiguration -CollectionName $config.DesktopCollectionName -UserGroup $config.RDSAccessGroup -ConnectionBroker $config.ConnectionBroker01
Write-Verbose "Configured Access for $($config.RDSAccessGroup)" -Verbose

# Set Profile Disk 
Set-RDSessionCollectionConfiguration -CollectionName $config.DesktopCollectionName -EnableUserProfileDisk -MaxUserProfileDiskSizeGB "20" -DiskPath $config.ProfileDiskPath -ConnectionBroker $config.ConnectionBroker01
Write-Verbose "Configured ProfileDisk" -Verbose

# RDS Licensing
Add-RDServer -Server $config.LICserver -Role "RDS-LICENSING" -ConnectionBroker $config.ConnectionBroker01
Write-Verbose "Installed RDS License Server: $($config.LICserver)" -Verbose
Set-RDLicenseConfiguration -LicenseServer $config.LICserver -Mode $config.LICmode -ConnectionBroker $config.ConnectionBroker01 -Force
Write-Verbose "Configured RDS Licensing" -Verbose

# Set Certificates
$Password = ConvertTo-SecureString -String $config.CertPassword -AsPlainText -Force 
Set-RDCertificate -Role RDPublishing -ImportPath $config.CertPath -Password $Password -ConnectionBroker $config.ConnectionBroker01 -Force
Set-RDCertificate -Role RDRedirector -ImportPath $config.CertPath -Password $Password -ConnectionBroker $config.ConnectionBroker01 -Force
Set-RDCertificate -Role RDWebAccess -ImportPath $config.CertPath -Password $Password -ConnectionBroker $config.ConnectionBroker01 -Force
Set-RDCertificate -Role RDGateway -ImportPath $config.CertPath -Password $Password -ConnectionBroker $config.ConnectionBroker01 -Force
Write-Verbose "Configured SSL Certificates" -Verbose

# Create RDS Broker DNS-Record
Import-Module -Name DNSServer
$IPBroker01 = [System.Net.Dns]::GetHostAddresses("$($config.ConnectionBroker01)")[0].IPAddressToString
Add-DnsServerResourceRecordA -ComputerName $config.DomainController -Name $config.RDBrokerDNSInternalName -ZoneName $config.RDBrokerDNSInternalZone -AllowUpdateAny -IPv4Address $IPBroker01
Write-Verbose "Configured RDSBroker DNS-Record" -Verbose

# Change RDPublishedName
Invoke-WebRequest -Uri "https://gallery.technet.microsoft.com/Change-published-FQDN-for-2a029b80/file/103829/2/Set-RDPublishedName.ps1" -OutFile "c:\rds\Set-RDPublishedName.ps1"
Copy-Item -Path "c:\rds\Set-RDPublishedName.ps1" -Destination "\\$($config.ConnectionBroker01)\c$"
Invoke-Command -ComputerName $config.ConnectionBroker01 -ArgumentList $config.RDBrokerDNSInternalName, $config.RDBrokerDNSInternalZone -ScriptBlock {
    param ($RDBrokerDNSInternalName, $RDBrokerDNSInternalZone)
    Set-Location -Path "C:\"
    .\Set-RDPublishedName.ps1 -ClientAccessName "$RDBrokerDNSInternalName.$RDBrokerDNSInternalZone"
    Remove-Item -Path "C:\Set-RDPublishedName.ps1"
}
Write-Verbose "Configured RDPublisher Name" -Verbose

#endregion Default Configuration Parameters

Write-Verbose "Stop logging" -Verbose
$EndDate = Get-Date
Write-Verbose "Elapsed Time: $(($EndDate - $StartDate).TotalSeconds) Seconds" -Verbose
Write-Verbose "Elapsed Time: $(($EndDate - $StartDate).TotalMinutes) Minutes" -Verbose
Stop-Transcript
