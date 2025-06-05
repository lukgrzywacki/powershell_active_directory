<#
.SYNOPSIS
    Usuwa uprawnienia wyłączonych użytkowników AD z folderów sieciowych.
.DESCRIPTION
    Skrypt przeszukuje wszystkie foldery w zadanej lokalizacji (np. \\NAS\Shares),
    identyfikuje wpisy ACL należące do użytkowników AD, których konta są wyłączone,
    i usuwa je. Działa tylko na folderach (nie plikach).
    
    Wymagane są odpowiednie uprawnienia do modyfikacji ACL oraz moduł ActiveDirectory.

    Wersja: 1.0
    Autor: Łukasz Grzywacki (SysTech)
#>

param (
    [Parameter(Mandatory = $false, HelpMessage = "Ścieżka do udziałów sieciowych (np. \\NAS\Shares)")]
    [string]$SharesRoot = $(Read-Host "Podaj ścieżkę do udziałów sieciowych (np. \\NAS\Shares)")
)

# --- [Import modułu ActiveDirectory] ---
Write-Host "[INFO] Importuję moduł ActiveDirectory..." -ForegroundColor Cyan
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Error "[BŁĄD] Nie udało się załadować modułu ActiveDirectory. Zainstaluj RSAT i spróbuj ponownie."
    exit 1
}

# --- [Pobieranie listy wyłączonych kont] ---
Write-Host "[INFO] Pobieram listę wyłączonych kont użytkowników..." -ForegroundColor Cyan
try {
    $disabledUsers = Get-ADUser -Filter 'Enabled -eq $false' | Select-Object -ExpandProperty SID
} catch {
    Write-Error "[BŁĄD] Nie udało się pobrać wyłączonych kont: $($_.Exception.Message)"
    exit 1
}

if (-not (Test-Path $SharesRoot)) {
    Write-Error "[BŁĄD] Ścieżka '$SharesRoot' nie istnieje."
    exit 1
}

$folders = Get-ChildItem -Path $SharesRoot -Directory
$total = $folders.Count
$current = 0

foreach ($folder in $folders) {
    $current++
    Write-Progress -Activity "Skanowanie udziałów" -Status "Przetwarzanie $current z $total" -PercentComplete (($current / $total) * 100)

    try {
        $acl = Get-Acl $folder.FullName
        $removed = $false

        foreach ($ace in $acl.Access) {
            $sid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])
            if ($disabledUsers -contains $sid) {
                $acl.RemoveAccessRule($ace) | Out-Null
                $removed = $true
                Write-Host "Usunięto wpis ACL z folderu $($folder.FullName): $($ace.IdentityReference)" -ForegroundColor DarkYellow
            }
        }

        if ($removed) {
            Set-Acl -Path $folder.FullName -AclObject $acl
            Write-Host "Zastosowano zmiany ACL dla folderu: $($folder.FullName)" -ForegroundColor Green
        } else {
            Write-Host "Brak wpisów do usunięcia w: $($folder.FullName)" -ForegroundColor Gray
        }

    } catch {
        Write-Host "[BŁĄD] W folderze $($folder.FullName): $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n[ZAKOŃCZONO] Skrypt usuwania wyłączonych użytkowników zakończył działanie." -ForegroundColor Cyan
