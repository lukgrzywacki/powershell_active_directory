<#
.SYNOPSIS
    Porównuje członkostwo dwóch grup bezpieczeństwa Active Directory i listuje różnice.
.DESCRIPTION
    Skrypt prosi użytkownika o podanie nazw dwóch grup AD (grupy referencyjnej i grupy do porównania).
    Następnie pobiera listy członków obu grup i porównuje je.
    Wynikiem jest wyświetlenie dwóch list w konsoli:
    1. Użytkownicy, którzy są członkami drugiej grupy, ale nie należą do pierwszej.
    2. Użytkownicy, którzy są członkami pierwszej grupy, ale nie należą do drugiej.
    Skrypt działa w pętli, umożliwiając wielokrotne porównania bez ponownego uruchamiania.
.PARAMETER ReferenceGroupName
    Opcjonalny. Nazwa pierwszej grupy (traktowanej jako punkt odniesienia).
    Jeśli nie podano, skrypt zapyta interaktywnie.
.PARAMETER DifferenceGroupName
    Opcjonalny. Nazwa drugiej grupy (porównywanej z pierwszą).
    Jeśli nie podano, skrypt zapyta interaktywnie.
.EXAMPLE
    .\Compare-ADGroupMembers.ps1 -ReferenceGroupName "Marketing_Read" -DifferenceGroupName "Marketing_Write"
    Skrypt porówna członkostwo grup 'Marketing_Read' i 'Marketing_Write' i wyświetli różnice, a następnie pokaże menu.

.EXAMPLE
    .\Compare-ADGroupMembers.ps1
    Skrypt uruchomi się w trybie w pełni interaktywnym, prosząc o nazwy obu grup.
.NOTES
    Wersja: 1.0
    Autor: Gemini (na podstawie standardu SysTech)
    Wymagania:
    - Moduł PowerShell 'ActiveDirectory'.
    - Konto uruchamiające skrypt musi posiadać uprawnienia do odczytu członków grup w AD.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Nazwa pierwszej grupy (referencyjnej) do porównania.")]
    [string]$ReferenceGroupName,

    [Parameter(Mandatory = $false, HelpMessage = "Nazwa drugiej grupy do porównania.")]
    [string]$DifferenceGroupName
)

# --- [BLOK FUNKCJI POMOCNICZYCH] ---

function Get-ValidGroupName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$PromptMessage
    )
    do {
        $inputGroupName = Read-Host -Prompt $PromptMessage
        if ([string]::IsNullOrWhiteSpace($inputGroupName)) {
            Write-Warning "Nazwa grupy nie może być pusta. Spróbuj ponownie."
        } else {
            return $inputGroupName
        }
    } while ($true)
}

# --- [GŁÓWNA PĘTLA SKRYPTU] ---

$ScriptRunning = $true
do {
    Write-Host "`n--- Rozpoczynanie nowej sesji porównywania członkostwa grup AD ---" -ForegroundColor Magenta

    # --- [KROK 1: Inicjalizacja i Walidacja Parametrów] ---
    if ([string]::IsNullOrWhiteSpace($ReferenceGroupName)) {
        $ReferenceGroupName = Get-ValidGroupName -PromptMessage "Podaj nazwę pierwszej grupy (referencyjnej)"
    }
    if ([string]::IsNullOrWhiteSpace($DifferenceGroupName)) {
        $DifferenceGroupName = Get-ValidGroupName -PromptMessage "Podaj nazwę drugiej grupy (do porównania)"
    }
    Write-Host "[INFO] Grupa referencyjna: '$ReferenceGroupName'" -ForegroundColor Cyan
    Write-Host "[INFO] Grupa do porównania:  '$DifferenceGroupName'" -ForegroundColor Cyan

    # --- [KROK 2: Sprawdzenie Wymagań i Pobranie Danych] ---
    Write-Host "[INFO] Sprawdzanie dostępności modułu ActiveDirectory..."
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Error "[BŁĄD KRYTYCZNY] Moduł 'ActiveDirectory' nie jest dostępny. Zainstaluj RSAT dla AD DS. Przerywam."
        # W przypadku braku modułu, nie ma sensu kontynuować pętli.
        $ScriptRunning = $false
        continue
    }
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        Write-Host "[INFO] Moduł ActiveDirectory załadowany." -ForegroundColor Green
    } catch {
        Write-Error "[BŁĄD KRYTYCZNY] Nie udało się zaimportować modułu ActiveDirectory. Szczegóły: $($_.Exception.Message). Przerywam."
        $ScriptRunning = $false
        continue
    }

    $Group1 = $null
    $Group2 = $null
    $ErrorOccurred = $false

    try {
        $Group1 = Get-ADGroup -Identity $ReferenceGroupName -ErrorAction Stop
        Write-Host "[INFO] Pomyślnie znaleziono grupę '$($Group1.Name)'." -ForegroundColor Green
    } catch {
        Write-Error "[BŁĄD] Nie udało się znaleźć grupy '$ReferenceGroupName' w Active Directory. Sprawdź nazwę i spróbuj ponownie."
        $ErrorOccurred = $true
    }

    try {
        $Group2 = Get-ADGroup -Identity $DifferenceGroupName -ErrorAction Stop
        Write-Host "[INFO] Pomyślnie znaleziono grupę '$($Group2.Name)'." -ForegroundColor Green
    } catch {
        Write-Error "[BŁĄD] Nie udało się znaleźć grupy '$DifferenceGroupName' w Active Directory. Sprawdź nazwę i spróbuj ponownie."
        $ErrorOccurred = $true
    }

    # --- [KROK 3: Porównanie Członkostwa i Wyświetlenie Wyników] ---
    if (-not $ErrorOccurred) {
        try {
            Write-Host "`n[INFO] Pobieranie członków obu grup..." -ForegroundColor Yellow
            $Members1 = Get-ADGroupMember -Identity $Group1 | Select-Object -ExpandProperty SamAccountName
            $Members2 = Get-ADGroupMember -Identity $Group2 | Select-Object -ExpandProperty SamAccountName
            Write-Host "[INFO] Pomyślnie pobrano członków." -ForegroundColor Green

            # Użycie Compare-Object do znalezienia różnic
            $Differences = Compare-Object -ReferenceObject $Members1 -DifferenceObject $Members2

            # Użytkownicy, którzy są w drugiej grupie, ale nie w pierwszej
            $OnlyInGroup2 = $Differences | Where-Object { $_.SideIndicator -eq '=>' } | Select-Object -ExpandProperty InputObject
            
            # Użytkownicy, którzy są w pierwszej grupie, ale nie w drugiej
            $OnlyInGroup1 = $Differences | Where-Object { $_.SideIndicator -eq '<=' } | Select-Object -ExpandProperty InputObject

            Write-Host "`n--- WYNIKI PORÓWNANIA ---" -ForegroundColor Yellow

            # Wyświetlanie pierwszej listy
            Write-Host "`n[+] Użytkownicy w grupie '$($Group2.Name)', których NIE MA w grupie '$($Group1.Name)':" -ForegroundColor Cyan
            if ($OnlyInGroup2) {
                $OnlyInGroup2 | ForEach-Object { Write-Host "  - $_" -ForegroundColor Green }
            } else {
                Write-Host "  (Brak takich użytkowników)"
            }

            # Wyświetlanie drugiej listy
            Write-Host "`n[-] Użytkownicy w grupie '$($Group1.Name)', których NIE MA w grupie '$($Group2.Name)':" -ForegroundColor Cyan
            if ($OnlyInGroup1) {
                $OnlyInGroup1 | ForEach-Object { Write-Host "  - $_" -ForegroundColor Blue }
            } else {
                Write-Host "  (Brak takich użytkowników)"
            }

        } catch {
            Write-Error "[BŁĄD] Wystąpił błąd podczas pobierania członków grupy. Szczegóły: $($_.Exception.Message)"
        }
    } else {
        Write-Warning "`nPorównanie nie mogło zostać przeprowadzone z powodu wcześniejszych błędów."
    }

    # --- [KROK 4: Menu Dalszych Działań] ---
    Write-Host "`n--- Opcje Dalszego Działania ---" -ForegroundColor Yellow
    Write-Host "1. Porównaj inne grupy"
    Write-Host "2. Zakończ działanie skryptu"

    $choice = Read-Host -Prompt "Wybierz opcję (1-2)"

    switch ($choice) {
        "1" {
            # Resetuj nazwy grup, aby skrypt zapytał o nie w następnej pętli
            $ReferenceGroupName = $null
            $DifferenceGroupName = $null
        }
        "2" {
            Write-Host "Kończenie działania skryptu..."
            $ScriptRunning = $false
        }
        default {
            Write-Warning "Nieprawidłowy wybór. Aby kontynuować, naciśnij Enter i wybierz ponownie z menu."
            Read-Host
        }
    }

} while ($ScriptRunning)

Write-Host "`n--- Skrypt porównujący grupy zakończył pracę ---" -ForegroundColor Green
