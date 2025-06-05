<#
.SYNOPSIS
    Masowe dodawanie członków do grupy Active Directory na podstawie listy z pliku tekstowego.
.DESCRIPTION
    Skrypt odczytuje identyfikatory obiektów (domyślnie oczekiwane są identyfikatory użytkowników,
    np. SamAccountName) z podanego pliku tekstowego, gdzie każdy identyfikator znajduje się
    w nowej linii. Następnie próbuje dodać każdego zidentyfikowanego i istniejącego w AD użytkownika
    do wskazanej grupy Active Directory.
    Skrypt pomija obiekty, które już są członkami grupy, oraz te, których nie uda się znaleźć w AD.
    Na koniec wyświetlane jest szczegółowe podsumowanie operacji.

    Wersja: 1.0 (Data modyfikacji: 20.05.2025)
    Autor: Łukasz Grzywacki (SysTech Łukasz Grzywacki)
.PARAMETER TargetGroupName
    Nazwa grupy Active Directory (lub jej inny identyfikator), do której mają być dodani członkowie.
    Jeśli nie zostanie podany, skrypt o niego zapyta.
.PARAMETER InputFilePath
    Pełna ścieżka do pliku tekstowego (.txt) zawierającego listę identyfikatorów użytkowników
    (np. SamAccountName), po jednym w każdej linii. Jeśli nie zostanie podany, skrypt o nią zapyta.
.EXAMPLE
    # Uruchomienie w pełni interaktywne - skrypt zapyta o nazwę grupy i ścieżkę pliku
    .\Import-ADGroupMembersFromFile.ps1

.EXAMPLE
    # Dodanie użytkowników z pliku do konkretnej grupy
    .\Import-ADGroupMembersFromFile.ps1 -TargetGroupName "GrupaProjektuX" -InputFilePath "C:\Temp\lista_uzytkownikow_projekt_X.txt"
    # Przykładowa zawartość pliku C:\Temp\lista_uzytkownikow_projekt_X.txt:
    # jkowalski
    # anowak
    # pwrona
.NOTES
    - Wymagany jest moduł PowerShell 'ActiveDirectory'.
    - Konto uruchamiające skrypt musi posiadać uprawnienia do modyfikacji członkostwa grup w AD
      oraz do odczytu informacji o użytkownikach.
    - Skrypt używa 'Get-ADUser' do weryfikacji istnienia użytkownika przed próbą dodania. Jeśli w pliku
      znajdują się identyfikatory innych typów obiektów (np. komputery), mogą one nie zostać poprawnie
      przetworzone przez ten etap weryfikacji, chociaż 'Add-ADGroupMember' może akceptować różne typy obiektów.
    - Puste linie w pliku wejściowym są ignorowane.
    - Zaleca się przetestowanie na grupie testowej przed operacjami na ważnych grupach produkcyjnych.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Podaj nazwę grupy Active Directory, do której chcesz dodać członków.")]
    [string]$TargetGroupName,

    [Parameter(Mandatory = $false, HelpMessage = "Podaj pełną ścieżkę do pliku .txt z listą identyfikatorów użytkowników (np. SamAccountName), po jednym w linii.")]
    [string]$InputFilePath
)

# --- [KROK 1: Inicjalizacja i Pobieranie Danych Wejściowych] ---
Write-Host "--- Rozpoczynanie skryptu importu członków do grupy AD ---" -ForegroundColor Green

# Pobranie nazwy grupy docelowej, jeśli nie podano
if ([string]::IsNullOrWhiteSpace($TargetGroupName)) {
    $TargetGroupName = Read-Host -Prompt "[WEJŚCIE] Podaj nazwę grupy Active Directory, do której dodać członków"
    if ([string]::IsNullOrWhiteSpace($TargetGroupName)) {
        Write-Error "[BŁĄD KRYTYCZNY] Nazwa grupy docelowej jest wymagana. Przerywam."
        exit 1
    }
}
Write-Host "[INFO] Grupa docelowa: '$TargetGroupName'" -ForegroundColor Cyan

# Pobranie ścieżki pliku wejściowego, jeśli nie podano
if ([string]::IsNullOrWhiteSpace($InputFilePath)) {
    $InputFilePath = Read-Host -Prompt "[WEJŚCIE] Podaj pełną ścieżkę do pliku tekstowego z listą użytkowników (identyfikator per linia)"
    if ([string]::IsNullOrWhiteSpace($InputFilePath)) {
        Write-Error "[BŁĄD KRYTYCZNY] Ścieżka do pliku wejściowego jest wymagana. Przerywam."
        exit 1
    }
}
Write-Host "[INFO] Plik wejściowy z listą użytkowników: '$InputFilePath'" -ForegroundColor Cyan

# --- [KROK 2: Sprawdzenie Wymagań Wstępnych] ---
Write-Host "`n[INFO] Sprawdzanie dostępności modułu ActiveDirectory..."
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "[BŁĄD KRYTYCZNY] Moduł 'ActiveDirectory' nie jest dostępny. Zainstaluj RSAT dla AD DS (Funkcje systemu Windows). Przerywam."
    exit 1
}
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Host "[INFO] Moduł ActiveDirectory gotowy." -ForegroundColor Green
} catch {
    Write-Error "[BŁĄD KRYTYCZNY] Nie udało się zaimportować modułu ActiveDirectory. Szczegóły: $($_.Exception.Message). Przerywam."
    exit 1
}

Write-Host "[INFO] Weryfikacja istnienia pliku wejściowego '$InputFilePath'..."
if (-not (Test-Path -Path $InputFilePath -PathType Leaf)) { # Leaf oznacza, że to musi być plik, a nie katalog
    Write-Error "[BŁĄD KRYTYCZNY] Plik wejściowy '$InputFilePath' nie został znaleziony lub nie jest plikiem. Sprawdź ścieżkę. Przerywam."
    exit 1
}
Write-Host "[INFO] Plik wejściowy '$InputFilePath' znaleziony." -ForegroundColor Green

Write-Host "[INFO] Weryfikacja istnienia grupy docelowej '$TargetGroupName' w AD..."
$ADGroupTarget = $null # Używamy innej nazwy zmiennej, dla jasności
try {
    $ADGroupTarget = Get-ADGroup -Identity $TargetGroupName -ErrorAction Stop
    Write-Host "[INFO] Znaleziono grupę docelową: '$($ADGroupTarget.Name)' (DN: $($ADGroupTarget.DistinguishedName))." -ForegroundColor Green
}
catch {
    Write-Error "[BŁĄD KRYTYCZNY] Nie można znaleźć grupy docelowej '$TargetGroupName' w AD. Sprawdź nazwę grupy i posiadane uprawnienia. Szczegóły: $($_.Exception.Message). Przerywam."
    exit 1
}

# --- [KROK 3: Odczyt i Przetwarzanie Listy Użytkowników] ---
Write-Host "`n[INFO] Odczytywanie identyfikatorów użytkowników z pliku '$InputFilePath'..."
# Odczytaj zawartość pliku, usuń białe znaki z początku/końca każdej linii i odfiltruj puste linie
$UserIdentifiersInFile = Get-Content -Path $InputFilePath | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

if (-not $UserIdentifiersInFile) {
    Write-Warning "[OSTRZEŻENIE] Plik '$InputFilePath' jest pusty lub nie zawiera żadnych prawidłowych identyfikatorów użytkowników (po usunięciu pustych linii i białych znaków)."
    Write-Host "`n--- Skrypt zakończył działanie (brak danych wejściowych) ---" -ForegroundColor Yellow
    exit 0 # Kończymy, bo nie ma kogo dodawać
}
Write-Host "[INFO] Znaleziono $($UserIdentifiersInFile.Count) identyfikatorów użytkowników w pliku do przetworzenia."

Write-Host "`n[INFO] Rozpoczynanie procesu dodawania użytkowników do grupy '$($ADGroupTarget.Name)'..."

# Zmienne do śledzenia statystyk operacji
$AddedCount = 0
$FailedToAddList = [System.Collections.Generic.List[string]]::new()       # Użytkownicy, których nie udało się dodać z powodu błędu
$AlreadyMemberList = [System.Collections.Generic.List[string]]::new()   # Użytkownicy, którzy już byli w grupie
$NotFoundInADList = [System.Collections.Generic.List[string]]::new()    # Użytkownicy nieznalezieni w AD

# Optymalizacja: Pobierz listę aktualnych członków grupy (ich SamAccountNames) raz, aby unikać wielokrotnego sprawdzania w pętli.
# To założenie, że w pliku są głównie SamAccountNames. Jeśli są inne identyfikatory, to porównanie może nie być w 100% skuteczne tutaj.
$CurrentMemberSamAccountNames = @() # Inicjalizuj jako pustą tablicę
try {
    Write-Host "[INFO] Pobieranie aktualnej listy członków grupy '$($ADGroupTarget.Name)' w celu optymalizacji..." -ForegroundColor DarkGray
    # Get-ADGroupMember może zwrócić różne typy obiektów; interesuje nas ich SamAccountName, jeśli istnieje
    $CurrentMemberSamAccountNames = (Get-ADGroupMember -Identity $ADGroupTarget -ErrorAction Stop | ForEach-Object { $_.SamAccountName }) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    Write-Host "[INFO] Pomyślnie pobrano $($CurrentMemberSamAccountNames.Count) aktualnych członków (na podstawie SamAccountName)." -ForegroundColor DarkGray
} catch {
    Write-Warning "[OSTRZEŻENIE] Nie udało się pobrać aktualnej listy członków grupy '$($ADGroupTarget.Name)'. Skrypt będzie kontynuował, ale może próbować dodać użytkowników, którzy już są członkami (co powinno skutkować niekrytycznym błędem dla tych użytkowników)."
}

# Główna pętla przetwarzająca każdego użytkownika z pliku
foreach ($UserIdentifierFromFile in $UserIdentifiersInFile) {
    # $CleanUserIdentifier już jest 'oczyszczony' z białych znaków na etapie wczytywania pliku
    Write-Host "--- Przetwarzanie identyfikatora: '$UserIdentifierFromFile' ---" -ForegroundColor DarkCyan
    
    # Sprawdzenie, czy użytkownik (na podstawie SamAccountName) już jest członkiem
    # To jest uproszczone sprawdzenie, skuteczne głównie jeśli UserIdentifierFromFile to SamAccountName
    if ($CurrentMemberSamAccountNames -contains $UserIdentifierFromFile) {
        Write-Host "[POMINIĘTO] Użytkownik '$UserIdentifierFromFile' jest już członkiem grupy '$($ADGroupTarget.Name)'." -ForegroundColor Cyan
        $AlreadyMemberList.Add($UserIdentifierFromFile)
        continue # Przejdź do następnego użytkownika
    }

    $UserObject = $null
    try {
        # KROK A: Sprawdź, czy użytkownik o danym identyfikatorze istnieje w Active Directory
        Write-Host "  [1/2] Weryfikacja użytkownika '$UserIdentifierFromFile' w AD..." -ForegroundColor DarkGray
        # Get-ADUser jest dość elastyczne i potrafi znaleźć użytkownika po SamAccountName, DN, SID, GUID, UPN
        $UserObject = Get-ADUser -Identity $UserIdentifierFromFile -ErrorAction Stop
        Write-Host "    [OK] Znaleziono użytkownika w AD: '$($UserObject.SamAccountName)' (DN: $($UserObject.DistinguishedName))" -ForegroundColor DarkGreen
        
        # KROK B: Dodaj znalezionego użytkownika do grupy
        Write-Host "  [2/2] Próba dodania użytkownika '$($UserObject.SamAccountName)' do grupy '$($ADGroupTarget.Name)'..." -ForegroundColor DarkGray
        Add-ADGroupMember -Identity $ADGroupTarget -Members $UserObject -ErrorAction Stop # Dodajemy obiekt użytkownika
        Write-Host "    [SUKCES] Pomyślnie dodano użytkownika '$($UserObject.SamAccountName)' do grupy '$($ADGroupTarget.Name)'." -ForegroundColor Green
        $AddedCount++
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        # Ten błąd specyficznie oznacza, że Get-ADUser nie znalazł użytkownika
        Write-Warning "[BŁĄD - NIE ZNALEZIONO] Nie znaleziono użytkownika o identyfikatorze '$UserIdentifierFromFile' w Active Directory."
        $NotFoundInADList.Add($UserIdentifierFromFile)
    }
    catch [Microsoft.ActiveDirectory.Management.ADException] {
        # Ten blok łapie inne błędy specyficzne dla Active Directory, w tym próbę dodania kogoś, kto już jest członkiem
        # (jeśli wcześniejsze sprawdzenie $CurrentMemberSamAccountNames nie było w 100% skuteczne, np. plik zawierał DN, a sprawdzaliśmy SamAccountName)
        if ($_.Exception.Message -like "*is already a member*" -or $_.Exception.Message -like "*jest już członkiem*") {
             Write-Host "[POMINIĘTO] Użytkownik '$UserIdentifierFromFile' jest już członkiem grupy '$($ADGroupTarget.Name)' (wykryto błędem podczas Add-ADGroupMember)." -ForegroundColor Cyan
             $AlreadyMemberList.Add($UserIdentifierFromFile) # Dodaj do listy pominiętych jako "już członek"
        } else {
            # Inny błąd AD podczas próby dodania
            Write-Warning "[BŁĄD - OPERACJA AD] Nie udało się dodać użytkownika '$UserIdentifierFromFile' do grupy. Szczegóły błędu AD: $($_.Exception.Message)"
            $FailedToAddList.Add("$UserIdentifierFromFile (Błąd AD: $($_.Exception.Message.Split([Environment]::NewLine)[0]))") # Bierzemy tylko pierwszą linię błędu
        }
    }
    catch { # Ogólny blok catch dla innych, nieprzewidzianych błędów
        Write-Warning "[BŁĄD - NIEOKREŚLONY] Nie udało się przetworzyć/dodać użytkownika '$UserIdentifierFromFile' do grupy. Wystąpił nieoczekiwany błąd: $($_.Exception.Message)"
        $FailedToAddList.Add("$UserIdentifierFromFile (Nieoczekiwany błąd: $($_.Exception.Message.Split([Environment]::NewLine)[0]))")
    }
} # Koniec pętli foreach

# --- [KROK 4: Podsumowanie Operacji] ---
Write-Host "`n--- [PODSUMOWANIE OPERACJI DODAWANIA CZŁONKÓW] ---" -ForegroundColor Yellow
Write-Host "Próbowano przetworzyć identyfikatorów z pliku: $($UserIdentifiersInFile.Count)"
Write-Host "Pomyślnie dodano nowych użytkowników do grupy '$($ADGroupTarget.Name)': $AddedCount" -ForegroundColor Green

if ($AlreadyMemberList.Count -gt 0) {
    Write-Host "Użytkowników, którzy już byli członkami grupy (pominięto): $($AlreadyMemberList.Count)" -ForegroundColor Cyan
    # Można tu dodać wypisanie listy $AlreadyMemberList, jeśli jest potrzebne
    # $AlreadyMemberList | ForEach-Object { Write-Host "  - $_" -ForegroundColor Cyan }
}
if ($NotFoundInADList.Count -gt 0) {
    Write-Warning "Użytkowników nieznalezionych w Active Directory: $($NotFoundInADList.Count)"
    $NotFoundInADList | ForEach-Object { Write-Warning "  - $_" }
}
if ($FailedToAddList.Count -gt 0) {
    Write-Warning "Użytkowników, których nie udało się dodać z powodu innych błędów: $($FailedToAddList.Count)"
    $FailedToAddList | ForEach-Object { Write-Warning "  - $_" }
}

Write-Host "`n--- Skrypt importu członków do grupy AD zakończył działanie ---" -ForegroundColor Green