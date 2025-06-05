<#
.SYNOPSIS
    Generuje raport z pustych grup AD utworzonych przez użytkowników (pomija systemowe).
.DESCRIPTION
    Skrypt skanuje wszystkie grupy w Active Directory i sprawdza, które z nich są puste.
    Pomija grupy znajdujące się w kontenerach systemowych, takich jak CN=Users, CN=Builtin.
    Zapisuje raport do pliku tekstowego – użytkownik może wskazać własną lokalizację lub zostanie użyta domyślna.
.AUTHOR
    Łukasz Grzywacki (SysTech)
.VERSION
    1.2 (2025-06-05)
#>

[CmdletBinding()]
param()

# Import modułu AD
Import-Module ActiveDirectory

# Pobranie ścieżki zapisu raportu
$reportPath = Read-Host "Podaj pełną ścieżkę do zapisu pliku (np. C:\Raporty\puste_grupy.txt). ENTER = domyślna na Pulpicie"
if ([string]::IsNullOrWhiteSpace($reportPath)) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $reportPath = "$env:USERPROFILE\Desktop\PusteGrupy_$timestamp.txt"
    Write-Host "Użyto domyślnej ścieżki: $reportPath" -ForegroundColor Yellow
}

# Kontenery systemowe – grupy z nich będą pomijane
$systemContainers = @('CN=Users', 'CN=Builtin', 'CN=ForeignSecurityPrincipals', 'CN=Managed Service Accounts')

# Pobierz wszystkie grupy
Write-Host "Pobieranie listy wszystkich grup AD..." -ForegroundColor Cyan
$allGroups = Get-ADGroup -Filter * -Properties Members, DistinguishedName

$emptyGroupNames = @()

$total = $allGroups.Count
$count = 0

foreach ($group in $allGroups) {
    $count++
    Write-Progress -Activity "Skanowanie grup AD" -Status "Przetwarzanie: $($group.Name)" -PercentComplete (($count / $total) * 100)

    # Pomijamy grupy znajdujące się w kontenerach systemowych
    if ($systemContainers | Where-Object { $group.DistinguishedName -like "*$_*" }) {
        continue
    }

    # Jeżeli grupa nie ma członków – dodaj do listy
    if (-not $group.Members) {
        $emptyGroupNames += $group.Name
    }
}

# Eksport do pliku tekstowego
if ($emptyGroupNames.Count -gt 0) {
    $emptyGroupNames | Out-File -FilePath $reportPath -Encoding UTF8 -Force
    Write-Host "Znaleziono $($emptyGroupNames.Count) pustych grup (spoza systemowych kontenerów)." -ForegroundColor Green
    Write-Host "Raport zapisano do: $reportPath" -ForegroundColor Cyan
} else {
    Write-Host "Nie znaleziono pustych grup (spoza systemowych kontenerów)." -ForegroundColor Yellow
}
