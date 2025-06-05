<#
.SYNOPSIS
    Tworzy raport CSV zawierający informacje o ostatnim logowaniu użytkowników AD.
.DESCRIPTION
    Skrypt pobiera wszystkich użytkowników domeny Active Directory i analizuje ich atrybuty logowania.
    Zbierane dane:
    - SamAccountName
    - Nazwa użytkownika (Name)
    - Czy konto jest włączone
    - Data ostatniego logowania (LastLogonTimestamp)
    - Członkostwo w grupach (opcjonalnie)
    
    Wynikowy plik CSV może być używany do audytów, analiz bezpieczeństwa lub czyszczenia martwych kont.

    Wymaga modułu ActiveDirectory.

    Wersja: 1.1
    Autor: Łukasz Grzywacki (SysTech)
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [int]$InactiveDaysThreshold = 90,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeGroups
)

# -- [KROK 1: Wczytanie modułu AD] --
Write-Host "[INFO] Importuję moduł ActiveDirectory..." -ForegroundColor Cyan
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Error "[BŁĄD] Nie udało się załadować modułu ActiveDirectory. Upewnij się, że RSAT jest zainstalowany."
    exit 1
}

# -- [KROK 2: Pobranie użytkowników] --
Write-Host "[INFO] Pobieram użytkowników AD..." -ForegroundColor Cyan
$users = Get-ADUser -Filter * -Properties LastLogonTimestamp, Enabled, MemberOf

# -- [KROK 3: Przetwarzanie danych] --
$report = foreach ($user in $users) {
    $lastLogon = if ($user.LastLogonTimestamp) {
        [DateTime]::FromFileTime($user.LastLogonTimestamp)
    } else {
        $null
    }

    $inactiveDays = if ($lastLogon) {
        (New-TimeSpan -Start $lastLogon -End (Get-Date)).Days
    } else {
        $null
    }

    $groupList = if ($IncludeGroups) {
        try {
            (Get-ADUser $user.SamAccountName -Properties MemberOf).MemberOf |
                ForEach-Object { (Get-ADGroup $_).Name } -join ', '
        } catch {
            "Błąd pobierania grup"
        }
    }

    [PSCustomObject]@{
        SamAccountName     = $user.SamAccountName
        Name               = $user.Name
        Enabled            = $user.Enabled
        LastLogon          = if ($lastLogon) { $lastLogon } else { "Brak danych" }
        InactiveDays       = if ($inactiveDays) { $inactiveDays } else { "N/D" }
        Groups             = if ($IncludeGroups) { $groupList } else { $null }
    }
}

# -- [KROK 4: Zapytaj użytkownika o ścieżkę zapisu] --
$customPath = Read-Host "`nPodaj pełną ścieżkę do pliku CSV (ENTER = zapisz na pulpicie)"
if ([string]::IsNullOrWhiteSpace($customPath)) {
    $customPath = "$env:USERPROFILE\Desktop\AD_LastLogonReport.csv"
    Write-Host "[INFO] Nie podano ścieżki – zapisuję raport na pulpicie: $customPath" -ForegroundColor Yellow
} else {
    Write-Host "[INFO] Użytkownik wybrał: $customPath" -ForegroundColor Cyan
}

# -- [KROK 5: Eksport do CSV] --
try {
    $report | Sort-Object InactiveDays -Descending | Export-Csv -Path $customPath -NoTypeInformation -Encoding UTF8
    Write-Host "`n[INFO] Raport zapisano do: $customPath" -ForegroundColor Green
} catch {
    Write-Error "[BŁĄD] Nie udało się zapisać pliku CSV. Szczegóły: $($_.Exception.Message)"
}

Write-Host "`n[ZAKOŃCZONO] Raport użytkowników AD z ostatnim logowaniem został wygenerowany." -ForegroundColor Cyan
