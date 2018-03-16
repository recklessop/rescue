﻿<#
.SYNOPSIS
    Short description
.DESCRIPTION
    Long description
.PARAMETER parameter1
    parameter1 description
.EXAMPLE
    PS C:\> <example usage>
    Explanation of what the example does
.NOTES
    General notes
#>

Write-Host "Break RDP";
#Disable-NetFirewallRule -DisplayGroup "Remote Desktop";
#Get-NetFirewallRule -DisplayGroup "Remote Desktop";
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\control\Terminal Server\Winstations\RDP-Tcp' -name 'PortNumber' 3390 -Type Dword;
Restart-Service -Name TermService -Force;
Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\control\Terminal Server\Winstations\RDP-Tcp' -name 'PortNumber';
Stop-Service -Name TermService -Force;
Get-Service -Name TermService;
Restart-Service -Name RdAgent;
Get-Service -Name RdAgent;