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
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
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
        $volume = Get-Volume -Partition $Partition -ErrorAction Stop
        return $volume.FileSystem
    }
    catch {
        return 'Unknown/None'
    }
}

function Get-SafePartitionKind {
    param($Partition)

    $ptype = [string]$Partition.Type
    $gptType = [string]$Partition.GptType
    $mbrType = [string]$Partition.MbrType

    if ($ptype -match 'System' -or $ptype -match 'Reserved' -or $ptype -match 'Recovery') { return 'Protected' }
    if ($gptType -match 'EFI|C12A7328' -or $gptType -match 'E3C9E316' -or $gptType -match 'DE94BBA4') { return 'Protected' }
    if ($mbrType -match 'IFS|FAT32|Extended|Unknown') {
        # MBR type alone is not always reliable, do not mark everything as protected.
    }

    return 'Regular'
}

function Show-Disks {
    Write-Step 'Доступные физические диски'
    $disks = Get-Disk | Sort-Object Number
    $disks | Select-Object \
        @{Name='DiskNumber';Expression={$_.Number}},
        FriendlyName,
        @{Name='Size';Expression={Format-Size $_.Size}},
        PartitionStyle,
        IsBoot,
        IsSystem | Format-Table -AutoSize
    return $disks
}

function Show-Partitions {
    param([int]$DiskNumber)

    Write-Step "Разделы на диске $DiskNumber"
    $partitions = Get-Partition -DiskNumber $DiskNumber | Sort-Object PartitionNumber
    if (-not $partitions) {
        Write-Host 'Разделов не найдено.' -ForegroundColor Yellow
        return @()
    }

    $rows = foreach ($p in $partitions) {
        [pscustomobject]@{
            PartitionNumber = $p.PartitionNumber
            DriveLetter     = if ($p.DriveLetter) { $p.DriveLetter } else { '-' }
            Size            = Format-Size $p.Size
            Type            = [string]$p.Type
            FileSystem      = Get-PartitionFileSystem -Partition $p
            Safety          = Get-SafePartitionKind -Partition $p
        }
    }

    $rows | Format-Table -AutoSize
    return $partitions
}

function Require-ConfirmationPhrase {
    param([int]$DiskNumber)

    $required = "DELETE DISK $DiskNumber"
    Write-Host "Для подтверждения введите точно: $required" -ForegroundColor Yellow
    $inputPhrase = Read-Host 'Подтверждение'
    if ($inputPhrase -ne $required) {
        throw 'Подтверждение не совпало. Операция отменена.'
    }
}

function Invoke-WholeDiskMode {
    param([int]$DiskNumber, [string]$FileSystem, [bool]$DoExecute)

    Write-Step 'Режим WholeDiskMode: полная очистка выбранного НЕсистемного диска'
    $actions = @(
        "Clear-Disk -Number $DiskNumber -RemoveData -Confirm:`$false",
        "Initialize-Disk -Number $DiskNumber -PartitionStyle GPT",
        "New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter",
        "Format-Volume -FileSystem $FileSystem -NewFileSystemLabel Data -Confirm:`$false"
    )

    if (-not $DoExecute) {
        Write-Host 'DRY RUN: Будут выполнены команды:' -ForegroundColor Yellow
        $actions | ForEach-Object { Write-Host "  - $_" }
        return $null
    }

    Clear-Disk -Number $DiskNumber -RemoveData -Confirm:$false
    Initialize-Disk -Number $DiskNumber -PartitionStyle GPT
    $newPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
    $formatted = Format-Volume -Partition $newPartition -FileSystem $FileSystem -NewFileSystemLabel 'Data' -Confirm:$false

    return [pscustomobject]@{
        Mode       = 'WholeDiskMode'
        DiskNumber = $DiskNumber
        FileSystem = $formatted.FileSystem
        DriveLetter = $formatted.DriveLetter
    }
}

function Invoke-PartitionMode {
    param([int]$DiskNumber, [string]$FileSystem, [bool]$DoExecute)

    Write-Step 'Режим PartitionMode: удаление только выбранных разделов'
    $parts = Show-Partitions -DiskNumber $DiskNumber
    if (-not $parts -or $parts.Count -eq 0) {
        throw 'На диске нет разделов для удаления.'
    }

    $selected = Read-Host 'Введите номера разделов для удаления через запятую (например 4,5)'
    $targets = $selected -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Select-Object -Unique
    if (-not $targets -or $targets.Count -eq 0) {
        throw 'Не выбраны корректные номера разделов.'
    }

    $removeList = @()
    foreach ($num in $targets) {
        $partition = $parts | Where-Object PartitionNumber -eq $num
        if (-not $partition) {
            throw "Раздел $num не найден на диске $DiskNumber."
        }

        $safety = Get-SafePartitionKind -Partition $partition
        if ($safety -eq 'Protected') {
            throw "Раздел $num защищён (EFI/System/Recovery/MSR) и не может быть удалён."
        }

        $removeList += $partition
    }

    if (-not $DoExecute) {
        Write-Host 'DRY RUN: Будут удалены разделы:' -ForegroundColor Yellow
        $removeList | ForEach-Object { Write-Host "  - Partition $($_.PartitionNumber) ($(Format-Size $_.Size))" }
        Write-Host "DRY RUN: Затем будет создан новый раздел и форматирован в $FileSystem" -ForegroundColor Yellow
        return $null
    }

    foreach ($partition in $removeList) {
        Remove-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -Confirm:$false
    }

    $newPartition = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter
    $formatted = Format-Volume -Partition $newPartition -FileSystem $FileSystem -NewFileSystemLabel 'Data' -Confirm:$false

    return [pscustomobject]@{
        Mode        = 'PartitionMode'
        DiskNumber  = $DiskNumber
        PartitionsRemoved = ($removeList.PartitionNumber -join ',')
        FileSystem  = $formatted.FileSystem
        DriveLetter = $formatted.DriveLetter
    }
}

try {
    if (-not (Test-Administrator)) {
        throw 'Скрипт должен быть запущен с правами администратора (Run as Administrator).'
    }

    Write-Host 'ВНИМАНИЕ: операция необратимо удаляет данные.' -ForegroundColor Red
    if (-not $Execute) {
        Write-Host 'Сейчас включён DRY RUN (безопасный режим): изменения не будут применены.' -ForegroundColor Yellow
        Write-Host 'Для реального выполнения добавьте параметр -Execute.' -ForegroundColor Yellow
    }

    $disks = Show-Disks
    $diskInput = Read-Host 'Введите DiskNumber целевого диска'
    if ($diskInput -notmatch '^\d+$') {
        throw 'DiskNumber должен быть числом.'
    }
    $diskNumber = [int]$diskInput

    $targetDisk = $disks | Where-Object Number -eq $diskNumber
    if (-not $targetDisk) {
        throw "Диск $diskNumber не найден."
    }

    if ($targetDisk.IsBoot -or $targetDisk.IsSystem) {
        throw "Диск $diskNumber является системным/загрузочным (IsBoot=$($targetDisk.IsBoot), IsSystem=$($targetDisk.IsSystem)). Очистка запрещена."
    }

    Show-Partitions -DiskNumber $diskNumber | Out-Null
    Require-ConfirmationPhrase -DiskNumber $diskNumber

    Write-Host "Выберите режим: [1] WholeDiskMode (полная очистка диска) [2] PartitionMode (удаление только выбранных разделов)" -ForegroundColor Cyan
    $modeChoice = Read-Host 'Введите 1 или 2'

    $result = $null
    switch ($modeChoice) {
        '1' { $result = Invoke-WholeDiskMode -DiskNumber $diskNumber -FileSystem $FileSystem -DoExecute:$Execute }
        '2' { $result = Invoke-PartitionMode -DiskNumber $diskNumber -FileSystem $FileSystem -DoExecute:$Execute }
        default { throw 'Некорректный выбор режима. Нужно ввести 1 или 2.' }
    }

    Write-Step 'Итог'
    if (-not $Execute) {
        Write-Host "DRY RUN завершён. Диск: $diskNumber. Режим: $modeChoice. Планируемая ФС: $FileSystem." -ForegroundColor Green
    }
    else {
        Write-Host "Операция завершена. Диск: $($result.DiskNumber). Режим: $($result.Mode)." -ForegroundColor Green
        if ($result.PartitionsRemoved) {
            Write-Host "Удалены разделы: $($result.PartitionsRemoved)." -ForegroundColor Green
        }
        Write-Host "Создана файловая система: $($result.FileSystem). Буква диска: $($result.DriveLetter)." -ForegroundColor Green
    }
}
catch {
    Write-Error "Ошибка: $($_.Exception.Message)"
    exit 1
}
