<#
.SYNOPSIS
    Audyt wykorzystania grupy Active Directory w Obiektach Zasad Grupy (GPO).
.DESCRIPTION
    Ten skrypt przeszukuje wszystkie Obiekty Zasad Grupy (GPO) w bieżącej domenie Active Directory
    w celu zidentyfikowania miejsc, w których określona grupa zabezpieczeń jest wykorzystywana.
    Analiza obejmuje:
    - Filtrowanie zabezpieczeń (Security Filtering) GPO.
    - Ustawienia w sekcji "Grupy ograniczone" (Restricted Groups).
    - Ustawienia w sekcji "Przypisywanie praw użytkownika" (User Rights Assignment).
    - Kierowanie na poziomie elementu (Item-Level Targeting) w Preferencjach Zasad Grupy (GPP).
    - Ogólne wystąpienia nazwy lub SID grupy w wygenerowanych raportach XML z GPO.

    Skrypt generuje podsumowanie znalezionych GPO i kontekstów użycia grupy.
    Wymaga modułów PowerShell 'ActiveDirectory' oraz 'GroupPolicy'.

    Wersja: 1.0 (Data modyfikacji: 20.05.2025)
    Autor: Łukasz Grzywacki (SysTech Łukasz Grzywacki)
.PARAMETER GroupName
    Nazwa (lub inny identyfikator jak SID/DN) grupy zabezpieczeń Active Directory,
    której wystąpienia w GPO mają zostać wyszukane. Parametr jest obowiązkowy.
    Przykład: "Administratorzy Domeny", "Dzial_Kadr_Odczyt"
.EXAMPLE
    .\Find-GroupInGPOs.ps1 -GroupName "Kontrolerzy Domeny"
    To polecenie przeszuka wszystkie GPO pod kątem użycia grupy "Kontrolerzy Domeny".
.NOTES
    - Uruchom skrypt z konta posiadającego uprawnienia do odczytu wszystkich GPO w domenie
      oraz do odpytywania Active Directory (np. jako Administrator Domeny lub członek grupy
      Group Policy Creator Owners z odpowiednimi delegacjami).
    - Analiza raportów XML jest oparta na wyszukiwaniu tekstowym nazwy grupy oraz jej SID,
      co może czasami prowadzić do fałszywych trafień w przypadku bardzo ogólnych nazw grup
      lub wystąpień SID w nieoczekiwanych kontekstach (dlatego niektóre wyniki są oznaczone
      jako "wymaga weryfikacji").
    - Przetwarzanie dużej liczby GPO może być czasochłonne.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Podaj nazwę (lub inny identyfikator, np. SID, DN) grupy AD, którą chcesz wyszukać w GPO.")]
    [string]$GroupName
)

# --- [KROK 1/5: Inicjalizacja i Sprawdzenie Modułów] ---
Write-Host "--- Rozpoczynanie skryptu audytu grupy '$GroupName' w GPO ---" -ForegroundColor Green

Write-Host "[INFO] Sprawdzanie wymaganych modułów PowerShell (ActiveDirectory, GroupPolicy)..."
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "[BŁĄD KRYTYCZNY] Moduł 'ActiveDirectory' nie jest dostępny. Zainstaluj RSAT dla AD DS (Funkcje systemu Windows). Przerywam."
    exit 1
}
if (-not (Get-Module -ListAvailable -Name GroupPolicy)) {
    Write-Error "[BŁĄD KRYTYCZNY] Moduł 'GroupPolicy' nie jest dostępny. Zainstaluj RSAT dla Group Policy Management (Funkcje systemu Windows). Przerywam."
    exit 1
}

Write-Host "[INFO] Wymagane moduły są dostępne. Importuję..."
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Import-Module GroupPolicy -ErrorAction Stop
    Write-Host "[INFO] Moduły 'ActiveDirectory' i 'GroupPolicy' zostały pomyślnie zaimportowane." -ForegroundColor Green
}
catch {
    Write-Error "[BŁĄD KRYTYCZNY] Nie udało się zaimportować wymaganych modułów. Szczegóły: $($_.Exception.Message). Przerywam."
    exit 1
}


# --- [KROK 2/5: Pobieranie Informacji o Grupie z AD] ---
Write-Host "`n[INFO] Pobieranie szczegółów grupy '$GroupName' z Active Directory..."
$ADGroupObject = $null # Jawna inicjalizacja, żeby było wiadomo co jest grane
$GroupSIDValue = $null # Jak wyżej

try {
    $ADGroupObject = Get-ADGroup -Identity $GroupName -ErrorAction Stop
    $GroupSIDValue = $ADGroupObject.SID.Value
    Write-Host "[INFO] Znaleziono grupę: '$($ADGroupObject.Name)' (DN: $($ADGroupObject.DistinguishedName))." -ForegroundColor Green
    Write-Host "[INFO] SID grupy: $GroupSIDValue" -ForegroundColor Green
}
catch {
    Write-Error "[BŁĄD KRYTYCZNY] Nie udało się pobrać informacji dla grupy '$GroupName' z AD. Upewnij się, że grupa istnieje i masz odpowiednie uprawnienia. Szczegóły: $($_.Exception.Message). Przerywam."
    exit 1
}

# --- [KROK 3/5: Pobieranie Listy Wszystkich GPO] ---
Write-Host "`n[INFO] Pobieranie listy wszystkich Obiektów Zasad Grupy (GPO) w domenie..."
$AllGPOs = $null
try {
    $AllGPOs = Get-GPO -All -ErrorAction Stop
}
catch {
    Write-Error "[BŁĄD KRYTYCZNY] Nie udało się pobrać listy GPO. Sprawdź uprawnienia i połączenie z kontrolerem domeny. Szczegóły: $($_.Exception.Message). Przerywam."
    exit 1
}

if (-not $AllGPOs) {
    Write-Host "[INFO] Nie znaleziono żadnych GPO w domenie. Zakończono." -ForegroundColor Yellow
    exit 0 # Kończymy, bo nie ma czego przeszukiwać
}
Write-Host "[INFO] Znaleziono $(($AllGPOs).Count) GPO do przeanalizowania." -ForegroundColor Green

# --- [KROK 4/5: Analiza Każdego GPO] ---
Write-Host "`n[INFO] Rozpoczynam przeszukiwanie GPO pod kątem użycia grupy '$GroupName' (SID: $GroupSIDValue)...`n"
$FoundInGPOs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Funkcja pomocnicza do przeszukiwania fragmentów XML
# Sprawdza, czy w danym węźle XML (lub jego potomkach) występuje nazwa lub SID grupy.
# Jest to proste wyszukiwanie tekstowe, więc wyniki mogą wymagać dodatkowej weryfikacji.
function Test-XmlSectionForGroup {
    param(
        [Parameter(Mandatory = $true)] [xml]$XmlDoc,            # Dokument XML do przeszukania (raport GPO)
        [Parameter(Mandatory = $true)] [string[]]$SectionXPaths, # Tablica ścieżek XPath wskazujących na sekcje do sprawdzenia
        [Parameter(Mandatory = $true)] [string]$SearchGroupName, # Nazwa grupy do wyszukania
        [Parameter(Mandatory = $true)] [string]$SearchGroupSID   # SID grupy do wyszukania
    )
    
    foreach ($XPath in $SectionXPaths) {
        try {
            $SectionNodes = $XmlDoc.SelectNodes($XPath) # Wybierz węzły pasujące do XPath
            if ($SectionNodes) {
                foreach($SectionNode in $SectionNodes){
                    $NodeOuterXml = $SectionNode.OuterXml # Pobierz zawartość węzła jako tekst
                    # Sprawdź, czy tekst zawiera nazwę grupy lub jej SID (uwzględniając znaki specjalne w regex)
                    if (($NodeOuterXml -match [regex]::Escape($SearchGroupName)) -or ($NodeOuterXml -match [regex]::Escape($SearchGroupSID))) {
                        return $true # Znaleziono, zwracamy prawdę i kończymy funkcję
                    }
                }
            }
        } catch {
            # Ignorujemy błędy XPath - jeśli ścieżka nie pasuje do struktury XML danego GPO, to po prostu nie ma tam tej sekcji
            # Write-Verbose "Błąd XPath '$XPath' dla GPO (normalne, jeśli sekcja nie istnieje): $($_.Exception.Message)"
        }
    }
    return $false # Nie znaleziono w żadnej ze sprawdzanych sekcji
}

# Główna pętla - iteracja przez wszystkie znalezione GPO
$GpoCounter = 0
foreach ($GPO in $AllGPOs) {
    $GpoCounter++
    Write-Host "[INFO] Analizuję GPO ($GpoCounter/$($AllGPOs.Count)): '$($GPO.DisplayName)' (GUID: $($GPO.Id))"
    
    # Generowanie ścieżki do tymczasowego pliku raportu XML
    $GpoReportPath = Join-Path -Path $env:TEMP -ChildPath "$($GPO.Id.ToString()).xml" # Używamy ToString() dla pewności
    $CurrentGpoFoundContexts = [System.Collections.Generic.List[string]]::new()

    # 1. Sprawdź filtrowanie zabezpieczeń (Security Filtering)
    # To podstawowe miejsce, gdzie grupy są używane do określania, do kogo GPO ma być stosowane.
    try {
        # Get-GPPermission zwraca listę uprawnień do GPO. Szukamy naszej grupy i prawa "GpoApply".
        $Permissions = Get-GPPermission -Guid $GPO.Id -TargetName $GroupName -TargetType Group -ErrorAction SilentlyContinue
        if ($Permissions | Where-Object { $_.Permission -eq "GpoApply" }) { # Sprawdzamy czy którekolwiek z uprawnień to "GpoApply"
            $CurrentGpoFoundContexts.Add("Filtrowanie zabezpieczeń (Security Filtering)")
        }
    }
    catch {
        Write-Warning "  [OSTRZEŻENIE] Nie udało się sprawdzić standardowych uprawnień (Get-GPPermission) dla GPO '$($GPO.DisplayName)'. Błąd: $($_.Exception.Message)"
    }

    # Wygeneruj raport XML dla GPO - będzie on podstawą do dalszej, bardziej szczegółowej analizy.
    # Używamy SilentlyContinue, bo niektóre GPO (np. startowe) mogą nie generować raportów lub mogą wystąpić błędy dostępu.
    Get-GPOReport -Guid $GPO.Id -ReportType Xml -Path $GpoReportPath -ErrorAction SilentlyContinue
    
    if (-not (Test-Path $GpoReportPath)) {
        Write-Warning "  [OSTRZEŻENIE] Nie udało się wygenerować raportu XML dla GPO: '$($GPO.DisplayName)'. Analiza XML dla tego GPO zostanie pominięta."
    } else {
        try {
            [xml]$GpoXml = Get-Content -Path $GpoReportPath -Raw -ErrorAction Stop # Wczytujemy cały plik XML
            $GpoXmlString = $GpoXml.OuterXml # Konwersja całego XML do stringa na potrzeby ogólnego wyszukiwania, jeśli specyficzne XPath zawiodą

            # 2. Sprawdź Grupy Ograniczone (Restricted Groups)
            # Sekcja GPO pozwalająca zarządzać członkostwem grup (np. dodawać grupę domenową do lokalnych Administratorów).
            # Ścieżki XPath są przykładami i mogą się różnić w zależności od wersji systemu/schematu raportu.
            $RestrictedGroupsXPaths = @(
                "//*[local-name()='RestrictedGroup' and (*[local-name()='GroupName' and (contains(text(),'$GroupName') or contains(text(),'$GroupSID'))] or .//*[local-name()='Member']/*[local-name()='Name' and (contains(text(),'$GroupName') or contains(text(),'$GroupSID'))])]", # Bardziej precyzyjne
                "//*[local-name()='RestrictedGroupsSettings']", # Ogólny kontener ustawień
                "//*[local-name()='RestrictedGroups']"          # Inny możliwy ogólny kontener
            )
            if (Test-XmlSectionForGroup -XmlDoc $GpoXml -SectionXPaths $RestrictedGroupsXPaths -SearchGroupName $GroupName -SearchGroupSID $GroupSIDValue) {
                # Dodatkowa weryfikacja, czy na pewno trafienie jest w relevantnej części kontenera
                 if (Test-XmlSectionForGroup -XmlDoc $GpoXml -SectionXPaths @("//*[local-name()='RestrictedGroupsSettings']","//*[local-name()='RestrictedGroups']") -SearchGroupName $GroupName -SearchGroupSID $GroupSIDValue){
                    $CurrentGpoFoundContexts.Add("Grupy ograniczone (Restricted Groups) - (zalecana weryfikacja manualna w raporcie)")
                 }
            }
            
            # 3. Sprawdź Przypisywanie Praw Użytkownika (User Rights Assignment)
            # Definiuje, jakie specjalne uprawnienia ma grupa na komputerach (np. "Logowanie lokalne", "Zmiana czasu systemowego").
            $UserRightsXPaths = @(
                "//*[local-name()='UserRightsAssignment']//Policy[descendant-or-self::*[contains(text(),'$GroupName') or contains(text(),'$GroupSIDValue')]]", # Bardziej precyzyjne
                "//*[local-name()='UserRights']" # Ogólny kontener
            )
            if (Test-XmlSectionForGroup -XmlDoc $GpoXml -SectionXPaths $UserRightsXPaths -SearchGroupName $GroupName -SearchGroupSID $GroupSIDValue) {
                 if (Test-XmlSectionForGroup -XmlDoc $GpoXml -SectionXPaths @("//*[local-name()='UserRightsAssignment']","//*[local-name()='UserRights']") -SearchGroupName $GroupName -SearchGroupSID $GroupSIDValue){
                    $CurrentGpoFoundContexts.Add("Przypisywanie praw użytkownika (User Rights Assignment) - (zalecana weryfikacja manualna w raporcie)")
                 }
            }

            # 4. Sprawdź Preferencje Zasad Grupy (Group Policy Preferences) - Item-Level Targeting (ILT)
            # GPP to potężny mechanizm konfiguracji, a ILT pozwala precyzyjnie kierować te ustawienia, m.in. na grupy.
            # Szukamy specyficznych atrybutów 'name' lub 'sid' w elementach związanych z filtrowaniem w GPP.
            $GppIltNodes = $GpoXml.SelectNodes("//*[local-name()='Filters']//*[(@name='$GroupName' or @sid='$GroupSIDValue') and (local-name()='FilterMembership' or local-name()='FilterGroup' or local-name()='FilterUser' or local-name()='FilterComputer')]")
            if ($GppIltNodes -and $GppIltNodes.Count -gt 0) {
                $CurrentGpoFoundContexts.Add("Preferencje zasad grupy (GPP) - Item-Level Targeting")
            }

            # 5. Ogólne wystąpienie nazwy/SID w raporcie XML (jeśli nie znaleziono w specyficznych kontekstach)
            # To jest "ostatnia deska ratunku" - jeśli grupa nie pasowała do powyższych, ale jej nazwa/SID jest gdzieś w XML.
            # Może to być np. w opisie GPO, komentarzu, ścieżce skryptu itp. Zawsze wymaga weryfikacji.
            # Sprawdzamy tylko, jeśli nic konkretnego (poza Security Filtering) jeszcze nie znaleźliśmy.
            $NonFilteringContextsAlreadyFound = $CurrentGpoFoundContexts | Where-Object { $_ -ne "Filtrowanie zabezpieczeń (Security Filtering)" }
            if ($NonFilteringContextsAlreadyFound.Count -eq 0) { # Jeśli tylko (lub wcale) Security Filtering było znalezione do tej pory
                 if (($GpoXmlString -match [regex]::Escape($GroupName)) -or ($GpoXmlString -match [regex]::Escape($GroupSIDValue))) {
                    # Upewnijmy się, że nie dodajemy tego, jeśli już jest Security Filtering (bo to jest już osobna kategoria)
                    if (-not ($CurrentGpoFoundContexts -contains "Filtrowanie zabezpieczeń (Security Filtering)")) {
                        $CurrentGpoFoundContexts.Add("Ogólne wystąpienie nazwy/SID w raporcie XML (np. opis, skrypt) - (wymaga weryfikacji)")
                    }
                 }
            }
        }
        catch {
            Write-Warning "  [OSTRZEŻENIE] Błąd podczas przetwarzania raportu XML dla GPO '$($GPO.DisplayName)'. Szczegóły: $($_.Exception.Message)"
        }
        finally {
            # Zawsze usuwamy tymczasowy plik raportu, żeby nie zostawiać śmieci
            Remove-Item -Path $GpoReportPath -ErrorAction SilentlyContinue
        }
    } # Koniec bloku else dla if (Test-Path $GpoReportPath)
    
    # Jeśli znaleziono grupę w jakimkolwiek kontekście w tym GPO, dodajemy do listy wyników
    if ($CurrentGpoFoundContexts.Count -gt 0) {
        $UniqueContexts = $CurrentGpoFoundContexts | Select-Object -Unique # Na wypadek duplikatów
        $FoundInGPOs.Add([PSCustomObject]@{
            GPOName  = $GPO.DisplayName
            GPOId    = $GPO.Id
            Contexts = $UniqueContexts -join "; " # Łączymy konteksty w jeden string
        })
    }
} # Koniec pętli foreach ($GPO in $AllGPOs)

# --- [KROK 5/5: Wyświetlanie Wyników i Zakończenie] ---
if ($FoundInGPOs.Count -gt 0) {
    Write-Host "`n--- [WYNIKI WYSZUKIWANIA] ---" -ForegroundColor Green
    Write-Host "Znaleziono odwołania do grupy '$GroupName' (lub jej SID: $GroupSIDValue) w następujących GPO:" -ForegroundColor Green
    $FoundInGPOs | Format-Table -AutoSize -Wrap
} else {
    Write-Host "`n--- [WYNIKI WYSZUKIWANIA] ---" -ForegroundColor Yellow
    Write-Host "Nie znaleziono żadnych odwołań do grupy '$GroupName' (lub jej SID: $GroupSIDValue) w żadnym z analizowanych GPO i kontekstów." -ForegroundColor Yellow
}

Write-Host "`n--- [WAŻNE UWAGI KOŃCOWE] ---" -ForegroundColor DarkGray
Write-Host "1. Wyniki oznaczone jako '(wymaga weryfikacji w raporcie)' opierają się na ogólnym wyszukiwaniu tekstowym w sekcjach XML."
Write-Host "   Zalecana jest manualna inspekcja raportu GPO (`Get-GPOReport -Guid 'GUID_GPO' -ReportType Html -Path 'C:\raport.html'`) dla potwierdzenia."
Write-Host "2. Analiza 'Preferencji zasad grupy (GPP)' pod kątem Item-Level Targeting jest skomplikowana ze względu na różnorodność struktur XML."
Write-Host "   Skrypt próbuje wykryć najczęstsze przypadki, ale pełna analiza może wymagać bardziej zaawansowanych metod lub inspekcji plików GPP."
Write-Host "3. Aby przeprowadzić dogłębną analizę GPP Item-Level Targeting, można również przeszukać pliki XML preferencji bezpośrednio w SYSVOL:"
Write-Host "   Ścieżka do GPO w SYSVOL: \\$($env:USERDOMAIN)\SYSVOL\$($env:USERDOMAIN)\Policies"
Write-Host "   Pliki XML dla GPP znajdują się w podfolderach User lub Computer (np. ...\User\Preferences\Drives\Drives.xml)."
Write-Host "`n--- Skrypt zakończył działanie ---" -ForegroundColor Green