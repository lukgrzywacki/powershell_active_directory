<#
.SYNOPSIS
    Wykrywa osierocone foldery domowe – czyli katalogi bez przypisanego użytkownika AD.
.DESCRIPTION
    Skrypt skanuje wskazaną lokalizację (np. \\NAS\Users) i porównuje nazwy folderów
    z listą aktywnych kont użytkowników w Active Directory. Foldery, które nie mają
    odpowiadającego konta w AD, zostaną oznaczone jako osierocone.

    Może być przydatny podczas porządków, migracji lub audytów środowiska.

    Wymaga modułu ActiveDirectory.

    Wersja: 1.0
    Autor: Łukasz Grzywacki (SysTech)
#>

# --- [Parametry wejściowe] ---
param (
    [Parameter(Mandatory = $false, HelpMessage = "Ścieżka sieciowa do katalogu z folderami domowymi użytkowników (np. \\NAS\Users)")]
    [string]$HomeRoot = $(Read-Host "Podaj ścieżkę do katalogu domowego (np. \\NAS\Users)")
)

# --- [Import modułu ActiveDirectory] ---
Write-Host "[INFO] Importuję moduł ActiveDirectory..." -ForegroundColor Cyan
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Error "[BŁĄD] Nie udało się załadować modułu ActiveDirectory. Upewnij się, że RSAT jest zainstalowany."
    exit 1
}

# --- [Pobieranie listy użytkowników] ---
Write-Host "[INFO] Pobieram listę aktywnych kont użytkowników z AD..." -ForegroundColor Cyan
try {
    $adUsers = Get-ADUser -Filter 'Enabled -eq $true' -Properties SamAccountName | Select-Object -ExpandProperty SamAccountName
} catch {
    Write-Error "[BŁĄD] Nie udało się pobrać użytkowników z AD: $($_.Exception.Message)"
    exit 1
}

# --- [Pobieranie listy folderów] ---
if (-not (Test-Path $HomeRoot)) {
    Write-Error "[BŁĄD] Podana ścieżka '$HomeRoot' nie istnieje. Sprawdź ścieżkę i spróbuj ponownie."
    exit 1
}

Write-Host "[INFO] Pobieram listę folderów domowych..." -ForegroundColor Cyan
$folders = Get-ChildItem -Path $HomeRoot -Directory

# --- [Porównanie i wyszukiwanie osieroconych folderów] ---
$orphanedFolders = @()
foreach ($folder in $folders) {
    if (-not ($adUsers -contains $folder.Name)) {
        $orphanedFolders += $folder.FullName
    }
}

# --- [Wyświetlenie wyniku] ---
if ($orphanedFolders.Count -eq 0) {
    Write-Host "[INFO] Nie znaleziono żadnych osieroconych folderów." -ForegroundColor Green
} else {
    Write-Host "`n[WYNIK] Znalezione osierocone foldery domowe:" -ForegroundColor Yellow
    $orphanedFolders | ForEach-Object { Write-Host $_ -ForegroundColor DarkYellow }

    # Opcja zapisania wyniku do pliku
    $savePath = Read-Host "`nPodaj ścieżkę, gdzie zapisać listę osieroconych folderów (ENTER = zapisz na pulpicie)"
    if ([string]::IsNullOrWhiteSpace($savePath)) {
        $savePath = "$env:USERPROFILE\Desktop\Orphaned_HomeFolders.txt"
        Write-Host "[INFO] Nie podano ścieżki – zapisuję na pulpicie: $savePath" -ForegroundColor Yellow
    }

    try {
        $orphanedFolders | Out-File -FilePath $savePath -Encoding UTF8
        Write-Host "[INFO] Zapisano listę do: $savePath" -ForegroundColor Green
    } catch {
        Write-Error "[BŁĄD] Nie udało się zapisać pliku: $($_.Exception.Message)"
    }
}

Write-Host "`n[ZAKOŃCZONO] Skrypt zakończył działanie." -ForegroundColor Cyan
