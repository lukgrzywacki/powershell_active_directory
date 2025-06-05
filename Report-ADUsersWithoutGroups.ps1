<#
.SYNOPSIS
    Raportuje aktywnych użytkowników AD, którzy nie należą do żadnej grupy oprócz domyślnej.
.DESCRIPTION
    Skrypt wyszukuje tylko aktywne konta użytkowników w domenie Active Directory,
    które nie są członkami żadnej grupy (poza domyślną np. "Domain Users").
    Takie konta mogą wskazywać na błędy w zarządzaniu dostępami.
    Raport zapisywany jest do pliku tekstowego.

    Wymagany moduł: ActiveDirectory

    Wersja: 1.1 (Data modyfikacji: 2025-06-05)
    Autor: Łukasz Grzywacki (SysTech Łukasz Grzywacki)
#>

# --- [KROK 1: Import modułu i przygotowanie danych] ---
Import-Module ActiveDirectory

Write-Host "Pobieranie aktywnych użytkowników i ich członkostwa w grupach..." -ForegroundColor Cyan

$users = Get-ADUser -Filter 'Enabled -eq $true' -Properties MemberOf, SamAccountName, Name
$usersWithoutGroups = @()

foreach ($user in $users) {
    if (-not $user.MemberOf -or $user.MemberOf.Count -eq 0) {
        $usersWithoutGroups += $user
    }
}

# --- [KROK 2: Przygotowanie ścieżki zapisu] ---
$defaultPath = "$env:USERPROFILE\Desktop\AD_UsersWithoutGroups.txt"
$savePath = Read-Host "Podaj pełną ścieżkę zapisu raportu (Enter aby zapisać na Pulpicie)"

if ([string]::IsNullOrWhiteSpace($savePath)) {
    $savePath = $defaultPath
}

# --- [KROK 3: Zapis raportu] ---
if ($usersWithoutGroups.Count -eq 0) {
    "Brak aktywnych użytkowników bez przypisanych grup." | Out-File -FilePath $savePath -Encoding UTF8
    Write-Host "Nie znaleziono aktywnych użytkowników bez grup. Informacja zapisana do: $savePath" -ForegroundColor Green
} else {
    $usersWithoutGroups | Select-Object Name, SamAccountName | Format-Table -AutoSize | Out-String | Out-File -FilePath $savePath -Encoding UTF8
    Write-Host "Znaleziono $($usersWithoutGroups.Count) aktywnych użytkowników bez przypisanych grup (poza domyślną)." -ForegroundColor Yellow
    Write-Host "Raport zapisany do: $savePath" -ForegroundColor Green
}

Write-Host "`n--- Skrypt zakończył działanie ---" -ForegroundColor Cyan
