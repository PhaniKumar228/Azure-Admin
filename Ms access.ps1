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


