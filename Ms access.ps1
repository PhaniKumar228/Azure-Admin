$MdbFile = "C:\Data\MyDatabase.mdb"

$conn = New-Object System.Data.OleDb.OleDbConnection
$conn.ConnectionString = "Provider=Microsoft.Jet.OLEDB.4.0;Data Source=$MdbFile"

$conn.Open()

$query = "SELECT TOP 10 * FROM Employee"

$adapter = New-Object System.Data.OleDb.OleDbDataAdapter($query, $conn)
$table = New-Object System.Data.DataTable

$adapter.Fill($table) | Out-Null

$table

$conn.Close()




$MdbFile = "C:\Data\MyDatabase.mdb"

$conn = New-Object System.Data.OleDb.OleDbConnection
$conn.ConnectionString = "Provider=Microsoft.Jet.OLEDB.4.0;Data Source=$MdbFile"

$conn.Open()

$cmd = $conn.CreateCommand()
$cmd.CommandText = "
UPDATE Employee
SET Department = 'DBA'
WHERE EmployeeID = 100
"

$RowsAffected = $cmd.ExecuteNonQuery()

Write-Host "$RowsAffected row(s) updated."

$conn.Close()


########################

$dbPath = "C:\Data\sample.mdb"

$connString = "Driver={Microsoft Access Driver (*.mdb, *.accdb)};Dbq=$dbPath;"

$conn = New-Object System.Data.Odbc.OdbcConnection $connString
$conn.Open()

$query = "SELECT * FROM YourTable"

$cmd = $conn.CreateCommand()
$cmd.CommandText = $query

$adapter = New-Object System.Data.Odbc.OdbcDataAdapter $cmd
$table = New-Object System.Data.DataTable
$adapter.Fill($table) | Out-Null

$table

$conn.Close()

$dbPath = "C:\Data\sample.mdb"

$access = New-Object -ComObject Access.Application
$db = $access.DBEngine.OpenDatabase($dbPath)

$recordset = $db.OpenRecordset("SELECT * FROM YourTable")

while (-not $recordset.EOF) {
    $row = @{}
    foreach ($field in $recordset.Fields) {
        $row[$field.Name] = $field.Value
    }
    [PSCustomObject]$row
    $recordset.MoveNext()
}

$recordset.Close()
$db.Close()
$access.Quit()
``
