<#
.SYNOPSIS
    Usuwa uprawnienia wskazanej grupy z wszystkich folderów w podanej lokalizacji.
.DESCRIPTION
    Skrypt przeszukuje wszystkie katalogi w wybranej lokalizacji sieciowej (np. \\NAS-QNAP)
    i usuwa wszelkie wpisy ACL powiązane ze wskazaną grupą.
    Działa tylko na folderach, nie plikach.
    Wymagane są odpowiednie uprawnienia administracyjne do zmiany ACL.
#>

# Pobierz dane wejściowe od użytkownika
$groupToRemove = Read-Host "Podaj nazwę grupy, której uprawnienia chcesz usunąć"
$nasPath = Read-Host "Podaj ścieżkę sieciową do folderu nadrzędnego (np. \\NAS-QNAP)"

# Pobierz wszystkie katalogi z lokalizacji
$folders = Get-ChildItem -Path $nasPath -Directory

foreach ($folder in $folders) {
    try {
        # Pobierz obecne uprawnienia
        $acl = Get-Acl $folder.FullName

        # Filtruj wpisy przypisane do danej grupy
        $acesToRemove = $acl.Access | Where-Object { $_.IdentityReference -like "*$groupToRemove" }

        if ($acesToRemove.Count -gt 0) {
            foreach ($ace in $acesToRemove) {
                $acl.RemoveAccessRule($ace) | Out-Null
            }

            # Zastosuj zaktualizowany ACL
            Set-Acl -Path $folder.FullName -AclObject $acl
            Write-Host "Usunięto uprawnienia grupy '$groupToRemove' z folderu: $($folder.FullName)" -ForegroundColor Green
        } else {
            Write-Host "Brak uprawnień grupy '$groupToRemove' w folderze: $($folder.FullName)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Błąd podczas przetwarzania folderu: $($folder.FullName)" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor DarkRed
    }
}

Write-Host "Zakończono usuwanie uprawnień." -ForegroundColor Cyan