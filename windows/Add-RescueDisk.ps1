#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Copies and attaches a rescue VHD to a VM.

.DESCRIPTION
    Copies a rescue VHD into the boot diagnostics storage account.
    For managed disk VMs it creates a managed disk from the copied VHD, then attaches the managed disk to the VM
    For unmanaged disk VMs it attaches the VHD from the boot diagnostics storage account.

.EXAMPLE
    add-rescuedisk.ps1 -resourceGroupName $resourceGroupName -vmName $vmName

.PARAMETER resourceGroupName
    Resource group name of the VM where you  want to attach the rescue VHD

.PARAMETER vmName
    Name of VM to attach the rescue VHD

.PARAMETER url
    URL to zip file
#>
param(
    [Parameter(mandatory=$true)]
    [String]$ResourceGroupName,
    [Parameter(mandatory=$true)]
    [String]$vmName,
    [string]$zipUrl = 'https://github.com/craiglandis/rescue/archive/master.zip',
    [switch]$skipShellHWDetectionServiceCheck = $true,
    [string]$vhdSizeMB = '20'
)

function expand-zipfile($zipFile, $destination)
{
    $shell = new-object -com shell.application
    $zip = $shell.NameSpace($zipFile)
    foreach($item in $zip.items())
    {
        $shell.Namespace($destination).copyhere($item)
    }
}

function show-progress
{
    param(
        [string]$text,    
        [string]$color = 'White',
        [switch]$logOnly,
        [switch]$noTimeStamp
    )    

    $timestamp = ('[' + (get-date (get-date).ToUniversalTime() -format "yyyy-MM-dd HH:mm:ssZ") + '] ')

    if ($logOnly -eq $false)
    {
        if ($noTimeStamp)
        {
            write-host $text -foregroundColor $color
        }
        else
        {
            write-host $timestamp -NoNewline
            write-host $text -foregroundColor $color
        }
    }

    if ($noTimeStamp)
    {
        ($text | out-string).Trim() | out-file $logFile -Append
    }
    else
    {
        (($timestamp + $text) | out-string).Trim() | out-file $logFile -Append   
    }        
}

set-strictmode -version Latest
$PSDefaultParameterValues['*:ErrorAction'] = 'Stop'
$PSDefaultParameterValues['*:WarningAction'] = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$startTime = (get-date).ToUniversalTime()
$timestamp = get-date $startTime -format yyyyMMddhhmmssff
$scriptPath = split-path -path $MyInvocation.MyCommand.Path -parent
$scriptName = (split-path -path $MyInvocation.MyCommand.Path -leaf).Split('.')[0]
$logFile = "$scriptPath\$($scriptName)_$($vmName)_$($timestamp).log"
show-progress "Log file: $logFile"

show-progress "[Running] Finding free drive letter"
$usedDriveLetters = (get-psdrive -PSProvider filesystem).Name
foreach ($letter in 'DEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray()) {
    if ($usedDriveLetters -notcontains $letter) {
        $driveLetter = "$($letter):"
        show-progress "[Success] Using drive $driveLetter to mount VHD" -color green
        break
    }
}

if(!$driveLetter)
{
    show-progress "[Error] No free drive letter found. Unable to mount VHD." -color red
}

if ((get-service -Name ShellHwDetection).Status -eq 'Running' -and -not $skipShellHWDetectionServiceCheck)
{
    $shellHWDetectionWasRunning = $true
    show-progress "[Running] Temporarily stopping ShellHWDetection service to avoid Explorer prompt when mounting VHD"
    stop-service -Name ShellHWDetection
    if ((get-service -Name ShellHWDetection).Status -eq 'Stopped')
    {
        show-progress "[Success] Temporarily stopped ShellHWDetection service to avoid Explorer prompt when mounting VHD" -color green
    }
    else
    {
        show-progress "[Error] Unable to stop ShellHWDetection service to avoid Explorer prompt when mounting VHD" -color red
        exit
    }
}

$vhdFile = "$scriptPath\rescue$timestamp.vhd"
$createVhdScript = "$scriptPath\createVhd$timestamp.txt"
$null = new-item $createVhdScript -itemtype File -force
add-content -path $createVhdScript "create vdisk file=$vhdFile type=fixed maximum=$vhdSizeMB"
add-content -path $createVhdScript "select vdisk file=$vhdFile"
add-content -path $createVhdScript "attach vdisk"
add-content -path $createVhdScript "create partition primary"
add-content -path $createVhdScript "select partition 1"
add-content -path $createVhdScript "format fs=FAT label=RESCUE quick"
add-content -path $createVhdScript "assign letter=$driveLetter"
add-content -path $createVhdScript "exit"
show-progress "[Running] Using Diskpart to create $vhdSizeMB MB VHD"
show-progress '' -noTimeStamp
get-content $createVhdScript | foreach {show-progress $_ -noTimeStamp}
show-progress '' -noTimeStamp
$null = diskpart /s $createVhdScript
remove-item $createVhdScript
if (test-path $vhdFile)
{
    show-progress "[Success] Created $vhdSizeMB MB VHD" -color green
}
else
{
    show-progress "[Error] Failed to create $vhdFile" -color red
    exit
}

$zipFile = "$scriptPath\rescue$timestamp.zip"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$webClient = new-object System.Net.WebClient
show-progress "[Running] Downloading $zipUrl"
$webClient.DownloadFile($zipUrl, $zipFile)
if (test-path $zipFile)
{
    show-progress "[Success] Downloaded $zipUrl" -color green
}
else
{
    show-progress "[Error] Download failed." -color red
}

$folderName = "$($zipUrl.Replace('.zip','').Split('/')[-3])-$($zipUrl.Replace('.zip','').Split('/')[-1])"
show-progress "[Running] Extracting $zipFile"
expand-zipfile -zipFile $zipFile -destination $driveLetter
if (test-path $driveLetter\$folderName)
{
    show-progress "[Success] Extracted to $driveLetter\$folderName" -color green
}
else
{
    show-progress "[Error] Failed to extract $zipFile to $driveLetter\$folderName" -color red
}

# If it's a github repo zip, the extracted folder will be <repo>-<branch>
# So get that from the URL and move that folder contents to the root of the VHD.
if($zipUrl -match 'github.com' -and $zipUrl -match 'archive')
{
    $command = "robocopy $driveLetter\$folderName $driveLetter\ /R:0 /W:0 /E /NP /NC /NS /NDL /NFL /NJH /NJS /MT:128"
    invoke-expression -command $command
    remove-item "$driveLetter\$folderName" -recurse -force
}

show-progress "VHD contents:"
$command = "$env:windir\system32\tree.com $driveLetter /a /f"
show-progress " " -noTimeStamp
invoke-expression $command
show-progress " " -noTimeStamp

$detachVhdScript = "$scriptPath\detachVhd$timestamp.txt"
$null = new-item $detachVhdScript -itemtype File -force
add-content -path $detachVhdScript "select vdisk file=$vhdFile"
add-content -path $detachVhdScript "detach vdisk"
show-progress "[Running] Using Diskpart to detach VHD"
show-progress '' -noTimeStamp
get-content $detachVhdScript | foreach {show-progress $_ -noTimeStamp}
show-progress '' -noTimeStamp
$null = diskpart /s $detachVhdScript
remove-item $detachVhdScript
show-progress "[Success] Detached VHD" -color green

if (!$skipShellHWDetectionServiceCheck)
{
    if($shellHWDetectionWasRunning)
    {
        show-progress "[Running] Starting ShellHWDetection again"
        start-service -name ShellHWDetection
        if ((get-service -Name ShellHWDetection).Status -eq 'Running')
        {
            show-progress "[Success] Started ShellHWDetection service again" -color green
        }
        else
        {
            show-progress "[Error] Unable to start ShellHWDetection service" -color red
            exit
        }
    }    
}

show-progress "[Running] Finding VM $vmName in resource group $resourceGroupName"
$vm = get-azurermvm -ResourceGroupName $resourceGroupName -Name $vmName
if ($vm)
{
    show-progress "[Success] Found VM $vmName in resource group $resourceGroupName" -color green
}
else
{
    show-progress "[Error] Unable to find VM $vmName in resource group $resourceGroupName" -color red
    exit
}

$vmstatus = get-azurermvm -ResourceGroupName $resourceGroupName -Name $vmName -Status
$managedDisk = $vm.StorageProfile.OsDisk.ManagedDisk
$serialLogUri = $vmstatus.BootDiagnostics.SerialConsoleLogBlobUri
$vmSize = $vm.hardwareprofile.vmsize
$vmSizes = Get-AzureRmVMSize -Location $vm.Location
$maxDataDiskCount = ($vmsizes | where name -eq $vmsize).MaxDataDiskCount
$dataDisks = $vm.storageprofile.datadisks
show-progress "[Running] Finding free LUN on VM $vmName"
if ($dataDisks)
{
    $luns = @(0..($MaxDataDiskCount-1))
    $availableLuns = Compare-Object $dataDisks.lun $luns | foreach {$_.InputObject}
    if($availableLuns)
    {
        $lun = $availableLuns[0]        
    }
    else 
    {
        show-progress "[Error] No LUN available. VM is size $vmSize and already has the maximum data disks attached ($maxDatadiskCount)" -color red
        exit
    }
}
else 
{
    $lun = 0
}
show-progress "[Success] LUN $lun is free" -color green

show-progress "[Running] Verifying boot diagnostics is enabled"
if ($serialLogUri)
{
    show-progress "[Success] Boot diagnostics is enabled" -color green
}
else
{
    # Serial console requires boot diagnostics be enabled
    show-progress "[Error] SerialConsoleLogBlobUri not populated. Please enable boot diagnostics for this VM and run the script again" -color red
    exit
}

# The boot diagnostics storage account is present for both managed and unmanaged, so copy the rescue VHD there
# Possible corner case where the boot diagnostics storage account is in a different resource group than the VM.
# Another approach would be to just always create a new storage account for the rescue disk but simpler to use an existing one (boot diagnostics) unless we find blockers with that approach.
# Creating a managed disk for the rescue disk would require keeping a copy of the rescue VHD in every region, because you can only create a managed disk from a VHD that resides in the same region.
$destStorageAccountName = $serialLogUri.Split('/')[2].Split('.')[0]        
$destStorageContainer = $serialLogUri.Split('/')[-2]
show-progress "[Running] Finding boot diagnostics storage account"
$destStorageAccount = get-azurermstorageaccount -ResourceGroupName $resourceGroupName -Name $destStorageAccountName
if ($destStorageAccount)
{
    show-progress "[Success] Found boot diagnostics storage account $destStorageAccountName" -color green
}
else
{
    show-progress "[Error] Unable to find boot diagnostics storage account $destStorageAccountName" -color red
    exit
}
$destStorageAccountKey = ($destStorageAccount | Get-AzureRmStorageAccountKey)[0].Value
show-progress "[Running] Getting storage context for $destStorageAccountName"
$destStorageContext = New-AzureStorageContext -StorageAccountName $destStorageAccountName -StorageAccountKey $destStorageAccountKey
if ($destStorageContext)
{
    show-progress "[Success] Got storage context for $destStorageAccountName" -color green
}
else
{
    show-progress "[Error] Failed to get storage context for $destStorageAccountName" -color red
}

$rescueDiskBlobName = split-path $vhdFile -leaf
$rescueDiskCopyDiskName = $rescueDiskBlobName.Split('.')[0]
$rescueDiskBlobCopyUri = "$($deststoragecontext.BlobEndPoint)$destStorageContainer/$(split-path $vhdFile -leaf)"
show-progress "[Running] Uploading VHD to storage account $destStorageAccountName"
show-progress '' -noTimeStamp
$result = add-azurermvhd -resourceGroupName $resourceGroupName -destination $rescueDiskBlobCopyUri -LocalFilePath $vhdFile
show-progress '' -noTimeStamp
if ($result.DestinationUri)
{
    show-progress "[Success] Uploaded VHD to storage account $destStorageAccountName" -color green
}
else
{
    show-progress "[Error] Failed to upload VHD to storage account $destStorageAccountName" -color red
}

if($managedDisk)
{
    show-progress "[Running] Creating managed disk from uploaded VHD"
    $diskConfig = New-AzureRmDiskConfig -AccountType $accountType -Location $vm.Location -CreateOption Import -StorageAccountId $destStorageAccount.Id -SourceUri $rescueDiskBlobCopyUri
    if (!$diskConfig)
    {
        show-progress "[Error] Failed to create disk config object." -color red
        exit
    }    
    $disk = New-AzureRmDisk -Disk $diskConfig -ResourceGroupName $resourceGroupName -DiskName $rescueDiskCopyDiskName
    if ($disk)
    {
        show-progress "[Success] Created disk $rescueDiskCopyDiskName" -color green
    }
    else
    {
        show-progress "[Error] Failed to create disk $rescueDiskCopyDiskName" -color red
    }
    show-progress "[Running] Attaching disk $rescueDiskCopyDiskName to VM $vmName"    
    $vm = Add-AzureRmVMDataDisk -VM $vm -Name $rescueDiskCopyDiskName -ManagedDiskId $disk.Id -Lun $lun -CreateOption Attach -StorageAccountType $accountType
    $vm = Update-AzureRmVM -VM $vm -ResourceGroupName $resourceGroupName
}
else 
{
    show-progress "[Running] Attaching disk $rescueDiskCopyDiskName to VM $vmName"
    $vm = Add-AzureRmVMDataDisk -VM $vm -Name $rescueDiskCopyDiskName -VhdUri $rescueDiskBlobCopyUri -Lun $lun -CreateOption Attach
    $vm = Update-AzureRmVM -VM $vm -ResourceGroupName $resourceGroupName
}

$vm = get-azurermvm -ResourceGroupName $resourceGroupName -Name $vmName
$rescueDataDisk = $vm.storageprofile.datadisks | where LUN -eq $lun 
if ($rescueDataDisk)
{
    show-progress "[Success] Attached disk $rescueDiskCopyDiskName to VM $vmName" -color green
}
else 
{
    show-progress "[Error] Failed to attach disk $rescueDiskCopyDiskName" -color red
}

$endTime = (get-date).ToUniversalTime()
$duration = new-timespan -Start $startTime -End $endTime
show-progress "Script duration: $('{0:hh}:{0:mm}:{0:ss}.{0:ff}' -f $duration)"
show-progress "Log file: $logFile"