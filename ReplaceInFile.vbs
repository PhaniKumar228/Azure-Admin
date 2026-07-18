Dim args
Set args = WScript.Arguments

If args.Count <> 2 Then
    WScript.Quit 1
End If

FileName = args(0)
LogFile = args(1)

Set FSO = CreateObject("Scripting.FileSystemObject")

If Not FSO.FileExists(FileName) Then
    WScript.Quit 2
End If

Set F = FSO.OpenTextFile(FileName, 1)
Content = F.ReadAll
F.Close

OldContent = Content

Content = Replace(Content, "\\infkc1p01\", "\\aws-infkc1p01\")
Content = Replace(Content, "\\pamuit\", "\\az-pamuit\")
Content = Replace(Content, "\\PAMstorage\", "\\aws-PAMstorage\")

If Content <> OldContent Then

    Set F = FSO.OpenTextFile(FileName, 2, True)
    F.Write Content
    F.Close

    Set L = FSO.OpenTextFile(LogFile, 8, True)
    L.WriteLine Now & " | MODIFIED | " & FileName
    L.Close
Else
    Set L = FSO.OpenTextFile(LogFile, 8, True)
    L.WriteLine Now & " | NO CHANGE | " & FileName
    L.Close
End If
