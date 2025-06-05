<#
.SYNOPSIS
    Szczegółowy audyt uprawnień wskazanej grupy Active Directory do folderów na udziałach sieciowych (np. QNAP).
.DESCRIPTION
    Skrypt przeprowadza rekursywne skanowanie podanych ścieżek UNC w poszukiwaniu folderów,
    do których określona grupa Active Directory ma jakiekolwiek skonfigurowane uprawnienia ACL (Access Control List).
    Wyniki są prezentowane w konsoli oraz zapisywane do pliku CSV w zdefiniowanym katalogu.
    Podczas skanowania wyświetlany jest tekstowy pasek postępu dla lepszej orientacji.

    Kluczowe funkcje:
    - Rekursywne przeszukiwanie struktury folderów.
    - Odpytywanie Active Directory o szczegóły grupy (w tym SID) dla dokładniejszego dopasowania.
    - Generowanie pliku CSV z wynikami (lub informacją o braku wyników).
    - Niestandardowe monity o podanie nazwy grupy i ścieżek, jeśli nie są one przekazane jako parametry.
    - Tekstowy pasek postępu aktualizowany w jednej linii.

    Ważne: Skrypt działa poprzez analizę standardowych uprawnień Windows ACL dostępnych przez protokół SMB/CIFS.
    Dla pełnej funkcjonalności na urządzeniach NAS (np. QNAP) konieczne jest, aby udziały miały włączoną
    obsługę zaawansowanych uprawnień folderów (Windows ACL mode).

    Wersja: 3.0 (Data modyfikacji: 20.05.2025)
    Autor: Łukasz Grzywacki (SysTech Łukasz Grzywacki)
.PARAMETER GroupName
    Nazwa grupy Active Directory, której uprawnienia będą sprawdzane.
    Jeśli parametr nie zostanie podany przy uruchomieniu, skrypt interaktywnie poprosi o jego wprowadzenie.
    Przykład: "Dział Finansów - Edycja"
.PARAMETER ParentFolderPathsToScan
    Tablica (lista) pełnych ścieżek UNC do folderów głównych, od których rozpocznie się skanowanie.
    Jeśli parametr nie zostanie podany, skrypt interaktywnie poprosi o wprowadzenie ścieżek.
    Przykład: @("\\NAS01\Finanse", "\\SERWERPLIKOW\Projekty\ProjektX")
    Przy monicie interaktywnym, wiele ścieżek należy oddzielić przecinkami.
.EXAMPLE
    # Skanowanie dla grupy, o którą zapyta skrypt, dla jednego folderu głównego
    .\CheckGroupAccessOnNas.ps1 -ParentFolderPathsToScan "\\NAS01\Wspolny"

.EXAMPLE
    # Skanowanie dla konkretnej grupy i wielu folderów głównych
    .\CheckGroupAccessOnNas.ps1 -GroupName "Kadry_Odczyt" -ParentFolderPathsToScan "\\NAS01\Kadry", "\\ARCHIWUM\Kadry_Archiwum"
.NOTES
    - Skrypt powinien być uruchamiany z konta posiadającego uprawnienia do odczytu list ACL na docelowych udziałach.
    - Dla pełnego rozpoznawania grupy (w tym jej SID i alternatywnych nazw) zalecana jest obecność i dostępność modułu PowerShell 'ActiveDirectory'.
    - Skanowanie bardzo dużych struktur folderów może być czasochłonne.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)] 
    [string]$GroupName,

    [Parameter(Mandatory = $false)] 
    [string[]]$ParentFolderPathsToScan
)

# --- [KROK 1: Inicjalizacja i Wprowadzanie Danych] ---
Write-Host "--- Rozpoczynanie skryptu audytu uprawnień ACL ---" -ForegroundColor Green

# Pobranie nazwy grupy od użytkownika, jeśli nie została podana jako parametr
if ([string]::IsNullOrWhiteSpace($GroupName)) {
    $GroupName = Read-Host -Prompt "[WEJŚCIE] Podaj nazwę grupy Active Directory do sprawdzenia"
    if ([string]::IsNullOrWhiteSpace($GroupName)) {
        Write-Error "[BŁĄD KRYTYCZNY] Nazwa grupy jest wymagana. Przerwanie działania skryptu."
        exit 1 
    }
}
Write-Host "[INFO] Grupa docelowa do analizy: '$GroupName'" -ForegroundColor Cyan

# Pobranie ścieżek do skanowania od użytkownika, jeśli nie zostały podane jako parametr
if ($null -eq $ParentFolderPathsToScan -or $ParentFolderPathsToScan.Count -eq 0) {
    Write-Host "[INFO] Nie podano ścieżek startowych jako parametru." -ForegroundColor Yellow
    Write-Host "       Podaj pełne ścieżki UNC do folderów głównych, które mają być przeskanowane." -ForegroundColor Yellow
    Write-Host "       Jeśli podajesz więcej niż jedną ścieżkę, oddziel je przecinkiem." -ForegroundColor Yellow
    Write-Host "       Przykład: '\\\\Serwer\\Udział1\\FolderA', '\\\\Serwer\\InnyUdział\\FolderB'" -ForegroundColor DarkGray
    $PathsInput = Read-Host -Prompt "[WEJŚCIE] Ścieżki startowe"
    
    if ([string]::IsNullOrWhiteSpace($PathsInput)) {
        Write-Error "[BŁĄD KRYTYCZNY] Ścieżki startowe są wymagane. Przerwanie działania skryptu."
        exit 1
    }
    # Przetwarzanie wprowadzonych ścieżek: podział po przecinku, usunięcie białych znaków, odfiltrowanie pustych
    $ParentFolderPathsToScan = $PathsInput.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    
    if ($ParentFolderPathsToScan.Count -eq 0) {
        Write-Error "[BŁĄD KRYTYCZNY] Nie udało się przetworzyć podanych ścieżek. Przerwanie działania skryptu."
        exit 1
    }
}
Write-Host "[INFO] Skanowane będą następujące ścieżki główne i ich podfoldery: $($ParentFolderPathsToScan -join '; ')" -ForegroundColor Cyan


# --- [KROK 2: Konfiguracja Środowiska i Przygotowanie Danych] ---
# Definicja głównego katalogu, gdzie będą lądować nasze raporty CSV
$BaseOutputDir = "C:\AD_Scripts\script_results" 

# Sprawdzenie dostępności modułu ActiveDirectory - kluczowe dla pełnego rozpoznania grupy
$AdModuleAvailable = $false
if (Get-Module -ListAvailable -Name ActiveDirectory) { # Czy moduł jest w ogóle zainstalowany w systemie?
    Write-Host "[INFO] Moduł ActiveDirectory jest wykryty. Próba załadowania..." -ForegroundColor DarkGray
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue # Ładujemy, jeśli jeszcze nie jest załadowany
    if (Get-Module -Name ActiveDirectory){ # Weryfikacja, czy załadowanie się powiodło
        $AdModuleAvailable = $true
        Write-Host "[INFO] Moduł ActiveDirectory załadowany. Pełne rozpoznawanie grupy aktywne." -ForegroundColor DarkGreen
    } else {
         Write-Warning "[OSTRZEŻENIE] Nie udało się załadować modułu ActiveDirectory (mimo że jest dostępny). Funkcjonalność rozpoznawania grupy będzie ograniczona (tylko po nazwie)."
    }
} else {
    Write-Warning "[OSTRZEŻENIE] Moduł ActiveDirectory nie jest zainstalowany w systemie. Funkcjonalność rozpoznawania grupy będzie ograniczona (tylko po nazwie)."
}

# Lista na znalezione uprawnienia (obiekty PSCustomObject)
$PermissionsList = [System.Collections.Generic.List[PSCustomObject]]::new()
# Lista identyfikatorów grupy (nazwa, SAM, SID), po których będziemy szukać w ACL
$GroupIdentityReferences = [System.Collections.Generic.List[string]]::new()
# Nazwa grupy podana przez użytkownika jest zawsze pierwszym identyfikatorem (wielkie litery dla spójności porównań)
$GroupIdentityReferences.Add($GroupName.ToUpper())

$ADGroupObject = $null 
$GroupSIDValue = $null 

if ($AdModuleAvailable) {
    Write-Host "[INFO] Próba pobrania szczegółów grupy '$GroupName' z Active Directory..." -ForegroundColor DarkGray
    try {
        $ADGroupObject = Get-ADGroup -Identity $GroupName -ErrorAction SilentlyContinue # Używamy SilentlyContinue, aby skrypt się nie wysypał, jeśli grupy nie ma
        if ($ADGroupObject) {
            $GroupSIDValue = $ADGroupObject.SID.Value # Pobieramy SID - unikalny identyfikator grupy
            # Dodajemy różne formy identyfikacji grupy do listy, aby zwiększyć szansę na dopasowanie w ACL
            $GroupIdentityReferences.Add($ADGroupObject.SamAccountName.ToUpper()) # np. DOMENA\nazwa_grupy
            $GroupIdentityReferences.Add($GroupSIDValue.ToUpper())                # np. S-1-5-21-...
            if ($env:USERDOMAIN) { # Jeśli skrypt działa na maszynie w domenie
                $DomainName = $env:USERDOMAIN.ToUpper()
                $GroupIdentityReferences.Add("$DomainName\$($ADGroupObject.SamAccountName.ToUpper())") # DOMENA\nazwa_sam
                $GroupIdentityReferences.Add("$DomainName\$($ADGroupObject.Name.ToUpper())")         # DOMENA\nazwa_wyswietlana (rzadziej w ACL, ale warto)
            }
            $GroupIdentityReferences = $GroupIdentityReferences | Select-Object -Unique # Usuwamy ewentualne duplikaty
            Write-Host "[INFO] Grupa '$($ADGroupObject.Name)' (SID: $GroupSIDValue) została znaleziona w AD. Rozszerzono kryteria wyszukiwania o $($GroupIdentityReferences.Count) unikalnych identyfikatorów." -ForegroundColor DarkGreen
        } else {
            Write-Warning "[OSTRZEŻENIE] Nie znaleziono grupy '$GroupName' w Active Directory (mimo że moduł AD jest dostępny). Skanowanie będzie oparte tylko na pierwotnie podanej nazwie."
        }
    }
    catch {
        # Złapanie innych potencjalnych błędów przy odpytywaniu AD
        Write-Warning "[OSTRZEŻENIE] Wystąpił błąd podczas próby pobrania informacji o grupie '$GroupName' z AD: $($_.Exception.Message). Skanowanie będzie oparte tylko na pierwotnie podanej nazwie."
    }
}

# Przygotowanie katalogu na pliki CSV z wynikami
$CanWriteOutputFile = $true # Zakładamy, że możemy pisać, chyba że coś pójdzie nie tak
if (-not (Test-Path -Path $BaseOutputDir -PathType Container)) { # Sprawdzamy, czy katalog istnieje
    Write-Host "[INFO] Katalog na wyniki '$BaseOutputDir' nie istnieje. Próba utworzenia..." -ForegroundColor DarkGray
    try {
        New-Item -ItemType Directory -Path $BaseOutputDir -Force -ErrorAction Stop | Out-Null # Tworzymy, -Force utworzy też ścieżkę nadrzędną jeśli trzeba
        Write-Host "[INFO] Utworzono katalog na wyniki: $BaseOutputDir" -ForegroundColor Green
    } catch {
        Write-Error "[BŁĄD KRYTYCZNY] Nie udało się utworzyć katalogu na wyniki '$BaseOutputDir'. Błąd: $($_.Exception.Message). Skrypt nie będzie mógł zapisać pliku CSV."
        $CanWriteOutputFile = $false
    }
} else {
    Write-Host "[INFO] Katalog na wyniki '$BaseOutputDir' jest gotowy." -ForegroundColor DarkGray
}

$PreviousProgressStringLength = 0 # Używane do poprawnego czyszczenia linii paska postępu

# --- [KROK 3: Główne Skanowanie Folderów] ---
foreach ($RootFolderPath in $ParentFolderPathsToScan) {
    Write-Host "`n--- [SKANOWANIE] Rozpoczynam analizę dla ścieżki głównej: $RootFolderPath ---" -ForegroundColor Yellow

    if (-not (Test-Path -LiteralPath $RootFolderPath)) { # LiteralPath dla bezpieczeństwa, gdyby w ścieżce były znaki specjalne PowerShell
        Write-Warning "[POMINIĘCIE] Ścieżka główna '$RootFolderPath' nie istnieje lub jest niedostępna. Przechodzę do następnej."
        continue # Pomiń tę iterację pętli i przejdź do następnej ścieżki głównej
    }

    $FoldersToProcess = [System.Collections.Generic.List[System.IO.FileSystemInfo]]::new()
    
    try {
        $RootFolderItem = Get-Item -LiteralPath $RootFolderPath -ErrorAction Stop
        if ($RootFolderItem -is [System.IO.DirectoryInfo]) { # Upewniamy się, że to folder
            $FoldersToProcess.Add($RootFolderItem) # Dodajemy sam folder główny do listy
        } else {
            Write-Warning "[POMINIĘCIE] Ścieżka '$RootFolderPath' nie jest folderem. Przechodzę do następnej."
            continue
        }
        # Pobieramy wszystkie podfoldery rekursywnie; -Force obejmuje ukryte/systemowe (wymaga uprawnień)
        Get-ChildItem -LiteralPath $RootFolderPath -Recurse -Directory -ErrorAction SilentlyContinue -Force | ForEach-Object { $FoldersToProcess.Add($_) }
    }
    catch {
        # Złapanie błędów na etapie listowania folderów
        Write-Warning "[BŁĄD IO] Problem z listowaniem zawartości '$RootFolderPath' lub jego podfolderów: $($_.Exception.Message)"
        if ($FoldersToProcess.Count -eq 0) { # Jeśli nawet folderu głównego nie udało się dodać
            Write-Warning "[POMINIĘCIE] Brak dostępu do '$RootFolderPath' lub folder nie zawiera podfolderów. Przechodzę do następnej ścieżki."
            continue
        }
        # Jeśli udało się pobrać przynajmniej folder główny, możemy kontynuować z tym, co mamy
        Write-Warning "[INFO] Kontynuuję skanowanie z częściowo pobraną listą folderów dla '$RootFolderPath'."
    }
    
    if ($FoldersToProcess.Count -eq 0) { # Jeśli lista jest pusta (np. tylko pliki w folderze głównym, brak podfolderów)
        Write-Warning "[INFO] Nie znaleziono żadnych podfolderów do szczegółowego sprawdzenia w '$RootFolderPath' (sprawdzono tylko sam folder główny, jeśli był dostępny)."
        # Jeśli $RootFolderItem był dodany, pętla poniżej go przetworzy. Jeśli nie, nic więcej tu nie zrobimy.
    }
    
    # Bierzemy tylko unikalne pełne ścieżki, na wypadek dziwnych linków symbolicznych itp.
    $UniqueFolderPaths = $FoldersToProcess.FullName | Select-Object -Unique
    $TotalFoldersInCurrentRoot = $UniqueFolderPaths.Count
    $ProcessedFoldersCounter = 0
    Write-Host "[INFO] W ramach '$RootFolderPath' zidentyfikowano $TotalFoldersInCurrentRoot unikalnych folderów (w tym podfoldery) do sprawdzenia ACL."
    $PreviousProgressStringLength = 0 # Reset dla każdej nowej ścieżki głównej

    # Pętla przez każdy folder i podfolder
    foreach ($CurrentFolderPath in $UniqueFolderPaths) {
        $ProcessedFoldersCounter++
        $Percent = if ($TotalFoldersInCurrentRoot -gt 0) { [int](($ProcessedFoldersCounter / $TotalFoldersInCurrentRoot) * 100) } else { 0 } # Procent ukończenia

        # --- Konstrukcja paska postępu ---
        $BarWidth = 30 # Szerokość samego paska graficznego (###---)
        $FilledChars = [int]($Percent / 100 * $BarWidth)
        $FilledChars = [Math]::Min($FilledChars, $BarWidth) # Zabezpieczenie przed przekroczeniem przy 100% i błędach zaokrągleń
        $EmptyChars = $BarWidth - $FilledChars
        $Bar = ('#' * $FilledChars) + ('-' * $EmptyChars)

        # Skracanie długich ścieżek, aby zmieściły się w linii konsoli
        $DisplayPath = $CurrentFolderPath
        $ConsoleWidth = 80 # Domyślna szerokość konsoli, jeśli nie można ustalić rzeczywistej
        try {
            if ($Host.UI -and $Host.UI.RawUI -and ($Host.UI.RawUI.WindowSize.Width -gt 0)) { # $Host.UI.RawUI może nie być dostępne wszędzie
                $ConsoleWidth = $Host.UI.RawUI.WindowSize.Width
            }
        } catch { /* Ignoruj błąd, użyj domyślnej szerokości */ }
        
        # Obliczanie dostępnego miejsca na wyświetlenie ścieżki w pasku postępu
        $FixedTextLengthAroundBarAndPath = 28 # Przybliżona długość stałych tekstów: "Skan: [] XXX% (XXXX/XXXX) - "
        $MaxLengthForDisplayPath = $ConsoleWidth - $BarWidth - $FixedTextLengthAroundBarAndPath - 3 # -3 dla marginesu i "..."

        if ($DisplayPath.Length -gt $MaxLengthForDisplayPath) {
            if ($MaxLengthForDisplayPath -gt 3) { # Wystarczająco miejsca na "..." i fragment ścieżki
                $PathSegmentLength = $MaxLengthForDisplayPath - 3
                if ($PathSegmentLength -lt 0) {$PathSegmentLength = 0} # Dodatkowe zabezpieczenie
                $DisplayPath = "..." + $DisplayPath.Substring($DisplayPath.Length - $PathSegmentLength) # Pokazujemy koniec ścieżki
            } elseif ($MaxLengthForDisplayPath -gt 0) { # Wystarczająco miejsca tylko na początek ścieżki
                $DisplayPath = $DisplayPath.Substring(0, $MaxLengthForDisplayPath)
            } else { # Za mało miejsca na sensowne wyświetlenie
                $DisplayPath = "..." 
            }
        }
        # --- Koniec konstrukcji paska postępu ---

        $ProgressString = "Skan: [$Bar] $Percent% ($ProcessedFoldersCounter/$TotalFoldersInCurrentRoot) - $DisplayPath"
        
        # Nadpisywanie linii postępu w konsoli
        $OutputString = "`r" + $ProgressString # `r = powrót karetki na początek linii
        $LineClearPadding = " " * [Math]::Max(0, $PreviousProgressStringLength - $ProgressString.Length) # Dodaj spacje, jeśli nowa linia jest krótsza
        $OutputString += $LineClearPadding
        
        Write-Host $OutputString -NoNewline # -NoNewline zapobiega przejściu do nowej linii
        $PreviousProgressStringLength = $ProgressString.Length # Zapisz długość obecnej linii do następnej iteracji
        
        # Główna operacja: pobieranie i analiza ACL
        try {
            $Acl = Get-Acl -LiteralPath $CurrentFolderPath -ErrorAction Stop # LiteralPath jest bardziej odporny na znaki specjalne w ścieżkach
            
            foreach ($AccessRule in $Acl.Access) { # Iterujemy przez każdy wpis (ACE) na liście ACL
                $CurrentAceIdentityUpper = $AccessRule.IdentityReference.Value.ToUpper() # Kogo dotyczy ten wpis?
                $IsMatch = $false # Flaga dopasowania
                
                # Sprawdzamy, czy ten wpis dotyczy naszej grupy (porównujemy z listą identyfikatorów)
                foreach ($RefIdUpper in $GroupIdentityReferences) {
                    if ($CurrentAceIdentityUpper -eq $RefIdUpper) {
                        $IsMatch = $true
                        break # Znaleziono dopasowanie, nie trzeba dalej sprawdzać dla tego ACE
                    }
                }

                if ($IsMatch) { # Jeśli wpis dotyczy naszej grupy
                    $PermissionsList.Add([PSCustomObject]@{
                        FolderPath        = $CurrentFolderPath
                        Identity          = $AccessRule.IdentityReference.Value
                        Permissions       = $AccessRule.FileSystemRights # Jakie prawa? Np. FullControl, Read, Write
                        AccessControlType = $AccessRule.AccessControlType # Allow czy Deny?
                        IsInherited       = $AccessRule.IsInherited     # Czy uprawnienie jest dziedziczone?
                    })
                    # Można tu dodać Write-Host, jeśli chcemy logować każde znalezienie, ale zakłóci to pasek postępu.
                    # Lepszym miejscem na podsumowanie jest koniec skryptu lub plik CSV.
                }
            }
        }
        catch {
            # Obsługa błędu pobierania ACL dla *tego konkretnego* folderu - nie przerywamy całego skryptu
            Write-Host ("`r" + (" " * $PreviousProgressStringLength) + "`r") -NoNewline # Wyczyść linię postępu przed wypisaniem błędu
            Write-Warning "[BŁĄD ACL] Nie udało się odczytać ACL dla '$CurrentFolderPath'. Powód: $($_.Exception.Message.Split('.')[0])" # Krótki komunikat błędu
            $PreviousProgressStringLength = 0 # Resetujemy długość, bo linia postępu została "przerwana" komunikatem błędu
        }
    } # Koniec pętli po $CurrentFolderPath

    # Zakończenie paska postępu dla bieżącego $RootFolderPath
    $FinalProgressString = "Analiza ACL dla '$RootFolderPath': Zakończona ($TotalFoldersInCurrentRoot/$TotalFoldersInCurrentRoot zbadanych)."
    $OutputString = "`r" + $FinalProgressString
    $LineClearPadding = " " * [Math]::Max(0, $PreviousProgressStringLength - $FinalProgressString.Length)
    $OutputString += $LineClearPadding
    Write-Host $OutputString # Pozostawiamy ostatni status paska na linii
    Write-Host "" # Dodatkowy Enter dla przejrzystości przed kolejnym RootFolderPath lub podsumowaniem
} # Koniec pętli po $RootFolderPath

# --- [KROK 4: Zapis Wyników do Pliku CSV] ---
if ($CanWriteOutputFile) {
    # Przygotowanie nazwy pliku - usuwamy znaki, które mogłyby być problematyczne w nazwach plików
    $CleanGroupNameForFileName = $GroupName -replace '[^a-zA-Z0-9_.-]', '' 
    if ([string]::IsNullOrWhiteSpace($CleanGroupNameForFileName)) {
        $CleanGroupNameForFileName = "NieznanaGrupa" # Zabezpieczenie, gdyby nazwa grupy była np. samymi znakami specjalnymi
    }
    
    $DateString = Get-Date -Format 'yyyyMMdd' # Data w formacie RRRRMMDD
    $CsvFileName = "CheckGroupAccessToNAS_$($CleanGroupNameForFileName)_$($DateString).csv"
    $CsvFilePath = Join-Path -Path $BaseOutputDir -ChildPath $CsvFileName

    Write-Host "`n--- [ZAPIS DO CSV] Przygotowywanie raportu... ---" -ForegroundColor DarkGray
    try {
        if ($PermissionsList.Count -gt 0) { # Jeśli znaleziono jakiekolwiek uprawnienia
            $PermissionsList | Export-Csv -Path $CsvFilePath -NoTypeInformation -Encoding UTF8 -Delimiter ',' -ErrorAction Stop
            Write-Host "[INFO] Znaleziono $($PermissionsList.Count) wpisów dotyczących uprawnień. Raport został pomyślnie zapisany do pliku CSV:" -ForegroundColor Green
            Write-Host $CsvFilePath -ForegroundColor Green
        } else {
            # Jeśli nic nie znaleziono, tworzymy plik CSV z odpowiednią informacją
            $NoResultsMessage = "Nie znaleziono żadnych bezpośrednich uprawnień dla grupy '$GroupName' na skanowanych ścieżkach."
            $NoResultsData = [PSCustomObject]@{
                Status            = "BRAK WYNIKÓW"
                Informacja        = $NoResultsMessage
                SkanowanaGrupa    = $GroupName
                SkanowaneSciezki  = ($ParentFolderPathsToScan -join "; ") # Lista głównych skanowanych ścieżek
                DataSkanowania    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            }
            # Export-Csv oczekuje kolekcji (nawet jeśli to pojedynczy obiekt, opakowujemy go w @() )
            @($NoResultsData) | Export-Csv -Path $CsvFilePath -NoTypeInformation -Encoding UTF8 -Delimiter ',' -ErrorAction Stop
            Write-Host "[INFO] Nie znaleziono żadnych uprawnień dla grupy '$GroupName'. Stosowna informacja została zapisana do pliku CSV:" -ForegroundColor Yellow
            Write-Host $CsvFilePath -ForegroundColor Yellow
        }
    } catch {
        Write-Error "[BŁĄD CSV] Nie udało się zapisać pliku CSV pod ścieżką '$CsvFilePath'. Powód: $($_.Exception.Message)"
    }
} else {
    Write-Warning "[OSTRZEŻENIE IO] Nie można zapisać pliku CSV - wystąpił problem z katalogiem wyjściowym '$BaseOutputDir'. Sprawdź uprawnienia lub ścieżkę."
}


# --- [KROK 5: Podsumowanie w Konsoli] ---
if ($PermissionsList.Count -gt 0) {
    Write-Host "`n--- [PODSUMOWANIE W KONSOLI] Znalezione uprawnienia dla grupy '$GroupName' (lub jej wariantów) ---" -ForegroundColor Yellow
    $PermissionsList | Format-Table -AutoSize -Wrap # Format-Table dla czytelnego wyświetlenia w konsoli
} else {
    Write-Host "`n--- [PODSUMOWANIE W KONSOLI] ---" -ForegroundColor Yellow
    Write-Host "[INFO] Nie znaleziono bezpośrednich uprawnień dla grupy '$GroupName' w żadnym ze sprawdzanych folderów i podfolderów (szczegółowa informacja znajduje się w wygenerowanym pliku CSV)." -ForegroundColor Yellow
}

Write-Host "`n--- Możliwe przyczyny braku wyników lub niepełnych danych ---" -ForegroundColor DarkGray
Write-Host "- Grupa może nie mieć jawnie przypisanych uprawnień (mogą one wynikać z dziedziczenia w sposób trudny do bezpośredniego wykrycia lub być przypisane do grupy nadrzędnej)."
Write-Host "- Serwer plików (np. QNAP) może korzystać z własnego, wewnętrznego systemu zarządzania uprawnieniami, a nie ze standardowych Windows ACL."
Write-Host "- Podane ścieżki startowe mogły być błędne, nieosiągalne lub konto uruchamiające skrypt nie miało do nich dostępu."
Write-Host "- Konto, na którym uruchomiono skrypt, może nie posiadać wystarczających uprawnień do odczytu list ACL na zdalnych zasobach."
Write-Host "WSKAZÓWKA: W przypadku wątpliwości, zawsze warto zweryfikować uprawnienia bezpośrednio w interfejsie administracyjnym serwera plików."
Write-Host "`n--- [KONIEC PRACY SKRYPTU] ---" -ForegroundColor Green