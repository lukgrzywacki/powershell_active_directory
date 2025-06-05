<#
.SYNOPSIS
    Eksportuje listę członków (lub tylko użytkowników) z wybranej grupy Active Directory do pliku tekstowego.
.DESCRIPTION
    Skrypt umożliwia wyeksportowanie określonego atrybutu (np. SamAccountName) wszystkich członków
    lub tylko członków będących użytkownikami z podanej grupy Active Directory.
    Wyniki zapisywane są do wskazanego pliku tekstowego, po jednym wpisie w linii.
    Skrypt interaktywnie pyta o nazwę grupy oraz ścieżkę pliku docelowego, jeśli nie zostaną
    one podane jako parametry startowe.

    Wersja: 1.0 (Data modyfikacji: 20.05.2025)
    Autor: Łukasz Grzywacki (SysTech Łukasz Grzywacki)
.PARAMETER SourceGroupName
    Nazwa grupy Active Directory (lub jej inny identyfikator, np. DN, SID), z której mają być pobrani członkowie.
    Jeśli nie zostanie podany, skrypt o niego zapyta.
.PARAMETER OutputFilePath
    Pełna ścieżka do pliku tekstowego, w którym zostanie zapisana lista atrybutów członków.
    Jeśli nie zostanie podany, skrypt o niego zapyta, sugerując nazwę opartą o nazwę grupy.
.PARAMETER UserAttributeToExport
    Opcjonalny. Atrybut obiektu członka, który ma zostać wyeksportowany do pliku.
    Domyślnie: "SamAccountName". Inne popularne to np. "UserPrincipalName", "DistinguishedName", "Name".
.PARAMETER ExportOnlyUsers
    Opcjonalny. Przełącznik logiczny ($true/$false). Jeśli ustawiony na $true, skrypt wyeksportuje
    tylko tych członków grupy, którzy są obiektami typu 'user'.
    Domyślnie: $false (eksportuje wszystkich członków: użytkowników, grupy, komputery).
.EXAMPLE
    # Uruchomienie interaktywne - skrypt zapyta o nazwę grupy i ścieżkę pliku
    .\Export-ADGroupMembersToFile.ps1

.EXAMPLE
    # Eksport członków grupy "Wszyscy_Pracownicy" do pliku, używając domyślnych ustawień atrybutu i filtrowania
    .\Export-ADGroupMembersToFile.ps1 -SourceGroupName "Wszyscy_Pracownicy" -OutputFilePath "C:\Temp\Lista_Wszyscy.txt"

.EXAMPLE
    # Eksport tylko nazw głównych użytkownika (UPN) tylko dla użytkowników z grupy "Kadry_Dostep_Email"
    .\Export-ADGroupMembersToFile.ps1 -SourceGroupName "Kadry_Dostep_Email" -OutputFilePath "C:\Temp\Kadry_UPN.txt" -UserAttributeToExport "UserPrincipalName" -ExportOnlyUsers $true
.NOTES
    - Wymagany jest moduł PowerShell 'ActiveDirectory'. Skrypt sprawdzi jego dostępność.
    - Konto uruchamiające skrypt musi mieć uprawnienia do odczytu informacji z Active Directory, w tym członkostwa grup.
    - Jeśli grupa nie będzie miała członków lub nie uda się wyodrębnić żądanego atrybutu od żadnego członka,
      skrypt utworzy pusty plik wyjściowy (lub nadpisze istniejący pustym plikiem).
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Podaj nazwę grupy AD, z której chcesz wyeksportować członków.")]
    [string]$SourceGroupName,

    [Parameter(Mandatory = $false, HelpMessage = "Podaj pełną ścieżkę do pliku wyjściowego (np. C:\Temp\lista_grupy.txt).")]
    [string]$OutputFilePath,

    [Parameter(Mandatory = $false)]
    [string]$UserAttributeToExport = "SamAccountName", # Domyślny atrybut do eksportu

    [Parameter(Mandatory = $false)]
    [bool]$ExportOnlyUsers = $false # Domyślnie eksportuj wszystkich członków
)

# --- [KROK 1: Pobieranie Danych Wejściowych od Użytkownika] ---
Write-Host "--- Rozpoczynanie skryptu eksportu członków grupy AD ---" -ForegroundColor Green

# Pobranie nazwy grupy, jeśli nie podano
if ([string]::IsNullOrWhiteSpace($SourceGroupName)) {
    $SourceGroupName = Read-Host -Prompt "[WEJŚCIE] Podaj nazwę grupy Active Directory, z której pobrać członków"
    if ([string]::IsNullOrWhiteSpace($SourceGroupName)) {
        Write-Error "[BŁĄD KRYTYCZNY] Nazwa grupy jest wymagana. Przerwanie działania skryptu."
        exit 1 # Krytyczny błąd, kończymy
    }
}
Write-Host "[INFO] Grupa źródłowa do przetworzenia: '$SourceGroupName'" -ForegroundColor Cyan

# Pobranie ścieżki pliku wyjściowego, jeśli nie podano
if ([string]::IsNullOrWhiteSpace($OutputFilePath)) {
    # Sugerujemy nazwę pliku na podstawie nazwy grupy, usuwając znaki specjalne
    $CleanedGroupName = $SourceGroupName -replace '[^a-zA-Z0-9_.-]', '_' # Zastąp niebezpieczne znaki podkreśleniem
    if ([string]::IsNullOrWhiteSpace($CleanedGroupName)) { $CleanedGroupName = "eksport_grupy" } # Fallback
    $SuggestedOutputFileName = "$($CleanedGroupName)_czlonkowie_$(Get-Date -Format 'yyyyMMdd').txt"
    $DefaultDir = "C:\AD_Scripts\script_results" # Można dostosować domyślny katalog

    $OutputFilePath = Read-Host -Prompt "[WEJŚCIE] Podaj pełną ścieżkę do pliku wyjściowego (sugerowana: '$DefaultDir\$SuggestedOutputFileName')"
    
    if ([string]::IsNullOrWhiteSpace($OutputFilePath)) {
        # Jeśli użytkownik nic nie wpisze (tylko Enter), użyj sugerowanej ścieżki
        # Upewnij się, że katalog docelowy istnieje
        if (-not (Test-Path $DefaultDir -PathType Container)) {
            Write-Host "[INFO] Domyślny katalog '$DefaultDir' nie istnieje. Próba utworzenia..." -ForegroundColor DarkGray
            try {
                New-Item -Path $DefaultDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Write-Host "[INFO] Utworzono katalog: $DefaultDir" -ForegroundColor Green
            } catch {
                Write-Error "[BŁĄD KRYTYCZNY] Nie udało się utworzyć katalogu '$DefaultDir'. Błąd: $($_.Exception.Message). Podaj pełną, istniejącą ścieżkę."
                exit 1
            }
        }
        $OutputFilePath = Join-Path -Path $DefaultDir -ChildPath $SuggestedOutputFileName
        Write-Host "[INFO] Użyto domyślnej ścieżki zapisu: '$OutputFilePath'" -ForegroundColor DarkGray
    }
}
Write-Host "[INFO] Plik wyjściowy: '$OutputFilePath'" -ForegroundColor Cyan
Write-Host "[INFO] Eksportowany atrybut: '$UserAttributeToExport'" -ForegroundColor Cyan
Write-Host "[INFO] Eksportuj tylko użytkowników: $($ExportOnlyUsers.ToString())" -ForegroundColor Cyan


# --- [KROK 2: Sprawdzenie Modułu AD i Grupy Źródłowej] ---
Write-Host "`n[INFO] Sprawdzanie dostępności modułu ActiveDirectory..."
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "[BŁĄD KRYTYCZNY] Moduł 'ActiveDirectory' nie jest dostępny. Zainstaluj RSAT dla AD DS (Funkcje systemu Windows). Przerywam."
    exit 1
}
try {
    Import-Module ActiveDirectory -ErrorAction Stop # Upewnij się, że jest załadowany
    Write-Host "[INFO] Moduł ActiveDirectory gotowy." -ForegroundColor Green
} catch {
    Write-Error "[BŁĄD KRYTYCZNY] Nie udało się zaimportować modułu ActiveDirectory. Szczegóły: $($_.Exception.Message). Przerywam."
    exit 1
}

Write-Host "[INFO] Weryfikacja istnienia grupy źródłowej '$SourceGroupName' w AD..."
$ADGroup = $null # Używamy innej nazwy zmiennej niż parametr, dla jasności
try {
    $ADGroup = Get-ADGroup -Identity $SourceGroupName -ErrorAction Stop
    Write-Host "[INFO] Znaleziono grupę źródłową: '$($ADGroup.Name)' (DN: $($ADGroup.DistinguishedName))." -ForegroundColor Green
}
catch {
    Write-Error "[BŁĄD KRYTYCZNY] Nie można znaleźć grupy '$SourceGroupName' w AD. Sprawdź nazwę grupy i posiadane uprawnienia. Szczegóły błędu: $($_.Exception.Message). Przerywam."
    exit 1
}

# --- [KROK 3: Pobieranie i Przetwarzanie Członków Grupy] ---
Write-Host "`n[INFO] Pobieranie członków z grupy '$($ADGroup.Name)'..."
try {
    $Members = Get-ADGroupMember -Identity $ADGroup -ErrorAction Stop # Pobierz wszystkich członków

    if ($ExportOnlyUsers) { # Jeśli użytkownik zażyczył sobie filtrowanie
        $OriginalMemberCount = $Members.Count
        $Members = $Members | Where-Object {$_.objectClass -eq 'user'} # Filtrujemy tylko obiekty typu 'user'
        Write-Host "[INFO] Odfiltrowano członków: pozostawiono tylko użytkowników ($($Members.Count) z $OriginalMemberCount)." -ForegroundColor DarkGray
    }

    if (-not $Members) { # Sprawdzenie, czy po ewentualnym filtrowaniu coś zostało
        Write-Warning "[OSTRZEŻENIE] Grupa '$($ADGroup.Name)' nie ma żadnych członków (lub żadnych użytkowników, jeśli włączono filtrowanie) do wyeksportowania."
        # Zgodnie z oryginalną logiką skryptu, tworzymy pusty plik w tej sytuacji.
        # Jeśli chcemy informację w pliku, trzeba by tu dodać logikę podobną do tej z poprzedniego skryptu (dla CSV).
        Write-Host "[INFO] Tworzenie pustego pliku wyjściowego: '$OutputFilePath'..."
        Set-Content -Path $OutputFilePath -Value $null -Encoding UTF8 -ErrorAction SilentlyContinue # Tworzy pusty plik lub czyści istniejący
        Write-Host "[INFO] Pusty plik został utworzony/nadpisany." -ForegroundColor Yellow
        Write-Host "`n--- Skrypt zakończył działanie (brak danych do eksportu) ---" -ForegroundColor Yellow
        exit 0 # Kończymy, bo nie ma co dalej robić
    }

    Write-Host "[INFO] Znaleziono $($Members.Count) członków do przetworzenia."

    # Wyodrębnianie wybranego atrybutu z każdego członka
    # Używamy ForEach-Object, aby iterować i próbować pobrać atrybut.
    # Następnie filtrujemy puste wyniki (jeśli atrybut nie istnieje lub jest pusty u niektórych członków)
    Write-Host "[INFO] Wyodrębnianie atrybutu '$UserAttributeToExport' od członków..."
    $MemberAttributes = $Members | ForEach-Object {
        # Używamy $_.PSObject.Properties aby bezpiecznie sprawdzić, czy właściwość istnieje, zanim ją odczytamy
        # Jeśli właściwość nie istnieje, nie będzie błędu, a wynikiem będzie $null (odfiltrowane później)
        if ($_.PSObject.Properties.Name -contains $UserAttributeToExport) {
            $_.$UserAttributeToExport
        } else {
            # Można tu dodać ostrzeżenie, jeśli atrybut nie istnieje dla konkretnego członka
            # Write-Warning "Atrybut '$UserAttributeToExport' nie istnieje dla członka '$($_.Name)' (typ: $($_.ObjectClass))"
            $null # Zwracamy null, aby można było odfiltrować
        }
    } | Where-Object { -not ([string]::IsNullOrWhiteSpace($_)) } # Usuwamy puste wartości i $null

    if (-not $MemberAttributes) { # Jeśli po wyodrębnieniu nie ma żadnych wartości atrybutów
        Write-Warning "[OSTRZEŻENIE] Nie udało się wyodrębnić wartości atrybutu '$UserAttributeToExport' od żadnego członka, lub wszyscy członkowie mieli pustą wartość tego atrybutu."
        Write-Host "[INFO] Tworzenie pustego pliku wyjściowego: '$OutputFilePath'..."
        Set-Content -Path $OutputFilePath -Value $null -Encoding UTF8 -ErrorAction SilentlyContinue
        Write-Host "[INFO] Pusty plik został utworzony/nadpisany." -ForegroundColor Yellow
        Write-Host "`n--- Skrypt zakończył działanie (brak wartości atrybutów do eksportu) ---" -ForegroundColor Yellow
        exit 0
    }

    # --- [KROK 4: Zapisywanie Danych do Pliku] ---
    Write-Host "`n[INFO] Rozpoczynam eksportowanie $($MemberAttributes.Count) wartości atrybutu '$UserAttributeToExport' do pliku '$OutputFilePath'..."
    try {
        # Sprawdzenie i utworzenie katalogu docelowego, jeśli nie istnieje
        $OutputDirectory = Split-Path -Path $OutputFilePath -Parent
        if (-not (Test-Path -Path $OutputDirectory -PathType Container)) {
            Write-Host "[INFO] Katalog docelowy '$OutputDirectory' dla pliku wyjściowego nie istnieje. Próba utworzenia..." -ForegroundColor DarkGray
            New-Item -Path $OutputDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Host "[INFO] Utworzono katalog: $OutputDirectory" -ForegroundColor Green
        }

        $MemberAttributes | Out-File -FilePath $OutputFilePath -Encoding UTF8 -Force -ErrorAction Stop # -Force nadpisze plik, jeśli istnieje
        Write-Host "[INFO] Eksport danych do pliku '$OutputFilePath' zakończony pomyślnie." -ForegroundColor Green
    } catch {
        Write-Error "[BŁĄD KRYTYCZNY] Wystąpił błąd podczas zapisywania danych do pliku '$OutputFilePath'. Szczegóły: $($_.Exception.Message). Przerywam."
        exit 1
    }
}
catch { # Ogólny blok catch dla wcześniejszych operacji (np. Get-ADGroupMember)
    Write-Error "[BŁĄD KRYTYCZNY] Wystąpił nieoczekiwany błąd podczas pobierania lub przetwarzania członków grupy. Szczegóły: $($_.Exception.Message). Przerywam."
    exit 1
}

Write-Host "`n--- Skrypt eksportu członków grupy AD zakończył działanie pomyślnie ---" -ForegroundColor Green