$Folder = "D:\Data"

Get-Acl $Folder | Select-Object -ExpandProperty Access |
Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited


Get-ChildItem "D:\Data" -Directory -Recurse | ForEach-Object {
    $Folder = $_.FullName
    Get-Acl $Folder | Select-Object -ExpandProperty Access |
    Select-Object @{N='Folder';E={$Folder}},
                  IdentityReference,
                  FileSystemRights,
                  AccessControlType,
                  IsInherited
}


$Server = "ServerName"
$Folder = "D:\Data"

Invoke-Command -ComputerName $Server -ScriptBlock {
    param($Folder)

    Get-Acl $Folder | Select-Object -ExpandProperty Access |
    Select-Object IdentityReference,
                  FileSystemRights,
                  AccessControlType,
                  IsInherited
} -ArgumentList $Folder

$Servers = @("Server01","Server02","Server03")
$Folder = "D:\Data"

Invoke-Command -ComputerName $Servers -ScriptBlock {
    param($Folder)

    Get-Acl $Folder | Select-Object `
        @{N='Server';E={$env:COMPUTERNAME}},
        IdentityReference,
        FileSystemRights,
        AccessControlType,
        IsInherited
} -ArgumentList $Folder
