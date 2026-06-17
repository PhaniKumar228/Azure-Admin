# Input Base Path
$BasePath = "D:\Your\Base\Folder"

# Output file
$OutputFile = "D:\FileReport.txt"

# Get all files recursively
$files = Get-ChildItem -Path $BasePath -Recurse -File

# Process and group data
$result = $files | ForEach-Object {
    $relativePath = $_.FullName.Replace($BasePath, "").TrimStart('\')
    $pathParts = $relativePath -split '\\'

    # Extract Folder and Subfolder
    $folder = if ($pathParts.Count -ge 2) { $pathParts[0] } else { "Root" }
    $subfolder = if ($pathParts.Count -ge 3) { $pathParts[1] } else { "NA" }

    [PSCustomObject]@{
        FilePath        = $_.DirectoryName
        FolderName      = $folder
        SubFolderName   = $subfolder
        Extension       = $_.Extension.TrimStart('.')
    }
} | Group-Object FolderName, SubFolderName, Extension

# Prepare output
$output = $result | ForEach-Object {
    $groupKeys = $_.Name -split ', '

    [PSCustomObject]@{
        FolderName     = $groupKeys[0]
        SubFolderName  = $groupKeys[1]
        Extension      = $groupKeys[2]
        TotalCount     = $_.Count
    }
}

# Export to TXT
$output | Sort-Object FolderName, SubFolderName, Extension |
ForEach-Object {
    "$($_.FolderName) - $($_.SubFolderName) - $($_.Extension) - $($_.TotalCount)"
} | Out-File -FilePath $OutputFile -Encoding UTF8

Write-Host "✅ Report generated: $OutputFile"
