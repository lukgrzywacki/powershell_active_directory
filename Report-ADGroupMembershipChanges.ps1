<#
.SYNOPSIS
    Wykrywa zmiany w członkostwie grupy AD na przestrzeni czasu.
.DESCRIPTION
    Skrypt zapisuje aktualnych członków wskazanej grupy Active Directory do pliku referencyjnego
    i porównuje ich z wcześniej zapisanym stanem. Jeśli plik referencyjny istnieje, raportuje
    dodanych i usuniętych członków od ostatniego uruchomienia.

    Użytkownik wybiera lokalizację pliku porównawczego.
    Wymagany moduł ActiveDirectory.

    Wersja: 1.0
    Autor: Łukasz Grzywacki (SysTech)
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Podaj nazwę grupy AD do monitorowania.")]
    [string]$GroupName,

    [Parameter(Mandatory = $false, HelpMessage = "Ścieżka do pliku referencyjnego (z poprzednim stanem członkostwa).")]
    [string]$ReferenceFile = $(Read-Host "Podaj ścieżkę pliku referencyjnego (np. C:\Temp\GroupSnapshot.txt)")
)

# --- [Import modułu ActiveDirectory] ---
Write-Host "[INFO] Importuję moduł ActiveDirectory..." -ForegroundColor Cyan
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Error "[BŁĄD] Nie udało się załadować modułu ActiveDirectory. Zainstaluj RSAT i spróbuj ponownie."
    exit 1
}

# --- [Pobranie aktualnych członków grupy] ---
Write-Host "[INFO] Pobieram aktualnych członków grupy '$GroupName'..." -ForegroundColor Cyan
try {
    $currentMembers = Get-ADGroupMember -Identity $GroupName | Select-Object -ExpandProperty SamAccountName
} catch {
    Write-Error "[BŁĄD] Nie udało się pobrać członków grupy '$GroupName'. Upewnij się, że grupa istnieje."
    exit 1
}

if (-not (Test-Path $ReferenceFile)) {
    # Zapis pierwszego stanu
    $currentMembers | Sort-Object | Out-File -FilePath $ReferenceFile -Encoding UTF8
    Write-Host "[INFO] Nie znaleziono pliku referencyjnego. Zapisano aktualnych członków jako punkt odniesienia." -ForegroundColor Yellow
    exit 0
}

# --- [Porównanie z poprzednim stanem] ---
Write-Host "[INFO] Porównuję aktualny stan z plikiem referencyjnym '$ReferenceFile'..." -ForegroundColor Cyan
$previousMembers = Get-Content $ReferenceFile

$added = $currentMembers | Where-Object { $_ -notin $previousMembers }
$removed = $previousMembers | Where-Object { $_ -notin $currentMembers }

if ($added.Count -eq 0 -and $removed.Count -eq 0) {
    Write-Host "[INFO] Brak zmian w członkostwie grupy '$GroupName' od czasu ostatniego zapisu." -ForegroundColor Green
} else {
    Write-Host "`n--- Zmiany wykryte w grupie '$GroupName' ---" -ForegroundColor Yellow
    if ($added.Count -gt 0) {
        Write-Host "`nDodani użytkownicy:" -ForegroundColor Green
        $added | ForEach-Object { Write-Host " + $_" }
    }
    if ($removed.Count -gt 0) {
        Write-Host "`nUsunięci użytkownicy:" -ForegroundColor Red
        $removed | ForEach-Object { Write-Host " - $_" }
    }
}

# --- [Aktualizacja pliku referencyjnego] ---
Write-Host "`n[INFO] Aktualizuję plik referencyjny '$ReferenceFile'..." -ForegroundColor Cyan
$currentMembers | Sort-Object | Out-File -FilePath $ReferenceFile -Encoding UTF8

Write-Host "`n[ZAKOŃCZONO] Skrypt wykrywania zmian w grupie AD zakończył działanie." -ForegroundColor Cyan
