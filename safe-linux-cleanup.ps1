[CmdletBinding()]
param(
    [switch]$Execute,
    [ValidateSet('NTFS', 'exFAT')]
    [string]$FileSystem = 'NTFS'
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Size {
    param([UInt64]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    return ('{0} B' -f $Bytes)
}

function Get-PartitionFileSystem {
    param($Partition)
    try {
        (Get-Volume -Partition $Partition -ErrorAction Stop).FileSystem
    }
    catch {
        'Unknown/None'
    }
}

function Get-SafePartitionKind {
    param($Partition)
    $ptype = [string]$Partition.Type
    $gpt = [string]$Partition.GptType

    if ($ptype -match 'System|Reserved|Recovery') { return 'Protected' }
    if ($gpt -match 'EFI|C12A7328|E3C9E316|DE94BBA4') { return 'Protected' }
    return 'Regular'
}

function Show-Disks {
    Write-Step 'Available physical disks'

    try {
        $disks = Get-Disk -ErrorAction Stop | Sort-Object Number
    }
    catch {
        throw "Get-Disk failed: $($_.Exception.Message)"
    }

    if (-not $disks -or $disks.Count -eq 0) {
        Write-Host 'No disks returned by Get-Disk.' -ForegroundColor Yellow
        return @()
    }

    $rows = $disks | ForEach-Object {
        [pscustomobject]@{
            DiskNumber     = $_.Number
            FriendlyName   = $_.FriendlyName
            Size           = Format-Size $_.Size
            PartitionStyle = $_.PartitionStyle
            IsBoot         = $_.IsBoot
            IsSystem       = $_.IsSystem
        }
    }

    $rows | Format-Table -AutoSize | Out-Host
    return $disks
}

function Show-Partitions {
    param([int]$DiskNumber)
    Write-Step "Partitions on disk $DiskNumber"
    $parts = Get-Partition -DiskNumber $DiskNumber | Sort-Object PartitionNumber
    if (-not $parts) {
        Write-Host 'No partitions found.' -ForegroundColor Yellow
        return @()
    }

    $parts | ForEach-Object {
        [pscustomobject]@{
            PartitionNumber = $_.PartitionNumber
            DriveLetter     = if ($_.DriveLetter) { $_.DriveLetter } else { '-' }
            Size            = Format-Size $_.Size
            Type            = [string]$_.Type
            FileSystem      = Get-PartitionFileSystem -Partition $_
            Safety          = Get-SafePartitionKind -Partition $_
        }
    } | Format-Table -AutoSize

    return $parts
}

function Require-ConfirmationPhrase {
    param([int]$DiskNumber)
    $required = "DELETE DISK $DiskNumber"
    Write-Host "Type exactly: $required" -ForegroundColor Yellow
    if ((Read-Host 'Confirmation') -ne $required) {
        throw 'Confirmation phrase mismatch. Operation cancelled.'
    }
}

function Invoke-WholeDiskMode {
    param([int]$DiskNumber, [string]$FileSystem, [bool]$DoExecute)
    Write-Step 'WholeDiskMode: wipe selected non-system disk'

    $plan = @(
        "Clear-Disk -Number $DiskNumber -RemoveData -Confirm:`$false",
        "Initialize-Disk -Number $DiskNumber -PartitionStyle GPT",
        "New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter",
        "Format-Volume -FileSystem $FileSystem -NewFileSystemLabel Data -Confirm:`$false"
    )

    if (-not $DoExecute) {
        Write-Host 'DRY RUN plan:' -ForegroundColor Yellow
        $plan | ForEach-Object { Write-Host "  - $_" }
        return $null
    }

    Clear-Disk -Number $DiskNumber -RemoveData -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT
    $part = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
    $vol = Format-Volume -Partition $part -FileSystem $FileSystem -NewFileSystemLabel 'Data' -Confirm:$false

    [pscustomobject]@{ Mode='WholeDiskMode'; DiskNumber=$DiskNumber; FileSystem=$vol.FileSystem; DriveLetter=$vol.DriveLetter }
}

function Invoke-PartitionMode {
    param([int]$DiskNumber, [string]$FileSystem, [bool]$DoExecute)
    Write-Step 'PartitionMode: delete selected partitions only'

    $parts = Show-Partitions -DiskNumber $DiskNumber
    if (-not $parts -or $parts.Count -eq 0) { throw 'No partitions available to remove.' }

    $selected = Read-Host 'Enter partition numbers to remove (comma-separated, e.g. 4,5)'
    $targets = $selected -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Select-Object -Unique
    if (-not $targets -or $targets.Count -eq 0) { throw 'No valid partition numbers selected.' }

    $removeList = foreach ($n in $targets) {
        $p = $parts | Where-Object PartitionNumber -eq $n
        if (-not $p) { throw "Partition $n not found on disk $DiskNumber." }
        if ((Get-SafePartitionKind -Partition $p) -eq 'Protected') { throw "Partition $n is protected (EFI/System/Recovery/MSR)." }
        $p
    }

    if (-not $DoExecute) {
        Write-Host 'DRY RUN: partitions to remove:' -ForegroundColor Yellow
        $removeList | ForEach-Object { Write-Host "  - Partition $($_.PartitionNumber) ($(Format-Size $_.Size))" }
        Write-Host "DRY RUN: create and format a new $FileSystem partition." -ForegroundColor Yellow
        return $null
    }

    $removeList | ForEach-Object {
        Remove-Partition -DiskNumber $DiskNumber -PartitionNumber $_.PartitionNumber -Confirm:$false
    }

    $newPart = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
    $newVol = Format-Volume -Partition $newPart -FileSystem $FileSystem -NewFileSystemLabel 'Data' -Confirm:$false

    [pscustomobject]@{ Mode='PartitionMode'; DiskNumber=$DiskNumber; PartitionsRemoved=($removeList.PartitionNumber -join ','); FileSystem=$newVol.FileSystem; DriveLetter=$newVol.DriveLetter }
}

try {
    if (-not (Test-Administrator)) { throw 'Run this script as Administrator.' }

    Write-Host 'WARNING: this operation permanently deletes data.' -ForegroundColor Red
    if (-not $Execute) {
        Write-Host 'DRY RUN mode is active. No destructive changes will be applied.' -ForegroundColor Yellow
        Write-Host 'Use -Execute to perform actual changes.' -ForegroundColor Yellow
    }

    $disks = Show-Disks
    if (-not $disks -or $disks.Count -eq 0) { throw 'No available disks to process.' }
    $diskInput = Read-Host 'Enter target DiskNumber'
    if ($diskInput -notmatch '^\d+$') { throw 'DiskNumber must be numeric.' }
    $diskNumber = [int]$diskInput

    $targetDisk = $disks | Where-Object Number -eq $diskNumber
    if (-not $targetDisk) { throw "Disk $diskNumber not found." }
    if ($targetDisk.IsBoot -or $targetDisk.IsSystem) {
        throw "Disk $diskNumber is Boot/System (IsBoot=$($targetDisk.IsBoot), IsSystem=$($targetDisk.IsSystem)); operation blocked."
    }

    Show-Partitions -DiskNumber $diskNumber | Out-Null
    Require-ConfirmationPhrase -DiskNumber $diskNumber

    Write-Host 'Select mode: [1] WholeDiskMode, [2] PartitionMode' -ForegroundColor Cyan
    $modeChoice = Read-Host 'Enter 1 or 2'

    $result = switch ($modeChoice) {
        '1' { Invoke-WholeDiskMode -DiskNumber $diskNumber -FileSystem $FileSystem -DoExecute:$Execute }
        '2' { Invoke-PartitionMode -DiskNumber $diskNumber -FileSystem $FileSystem -DoExecute:$Execute }
        default { throw 'Invalid mode selection. Enter 1 or 2.' }
    }

    Write-Step 'Summary'
    if (-not $Execute) {
        Write-Host "DRY RUN complete. Disk: $diskNumber. Requested FS: $FileSystem." -ForegroundColor Green
    }
    else {
        Write-Host "Done. Disk: $($result.DiskNumber). Mode: $($result.Mode)." -ForegroundColor Green
        if ($result.PartitionsRemoved) { Write-Host "Removed partitions: $($result.PartitionsRemoved)." -ForegroundColor Green }
        Write-Host "Created FS: $($result.FileSystem). Drive letter: $($result.DriveLetter)." -ForegroundColor Green
    }
}
catch {
    Write-Error "Error: $($_.Exception.Message)"
    exit 1
}
