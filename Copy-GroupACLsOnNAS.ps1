# Skrypt PowerShell do kopiowania uprawnień folderów udostępnionych na NAS QNAP

# Poproś użytkownika o nazwę grupy źródłowej i docelowej
$sourceGroup = Read-Host "Podaj nazwę grupy źródłowej (z której pobierzemy uprawnienia)"
$destinationGroup = Read-Host "Podaj nazwę grupy docelowej (której przypiszemy uprawnienia)"

# Podaj ścieżkę sieciową do NAS QNAP
$nasPath = Read-Host "Podaj ścieżkę sieciową do folderu NAS QNAP (np. \\NAS-QNAP)"

# Pobierz wszystkie foldery udostępnione z lokalizacji NAS
$sharedFolders = Get-ChildItem -Path $nasPath -Directory

foreach ($folder in $sharedFolders) {
    # Pobierz ACL folderu
    $acl = Get-Acl $folder.FullName

    # Znajdź wpisy ACL dla grupy źródłowej
    $sourceAces = $acl.Access | Where-Object { $_.IdentityReference -like "*$sourceGroup" }

    if ($sourceAces) {
        foreach ($ace in $sourceAces) {
            # Skopiuj wpis ACL i przypisz do grupy docelowej
            $newAce = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $destinationGroup,
                $ace.FileSystemRights,
                $ace.InheritanceFlags,
                $ace.PropagationFlags,
                $ace.AccessControlType
            )

            # Dodaj nowy wpis ACL
            $acl.AddAccessRule($newAce)
        }

        # Zastosuj zmieniony ACL do folderu
        Set-Acl -Path $folder.FullName -AclObject $acl

        Write-Host "Przypisano uprawnienia dla grupy '$destinationGroup' do folderu: $($folder.FullName)" -ForegroundColor Green
    } else {
        Write-Host "Brak uprawnień dla grupy '$sourceGroup' w folderze: $($folder.FullName)" -ForegroundColor Yellow
    }
}

Write-Host "Zakończono kopiowanie uprawnień." -ForegroundColor Cyan