# 📂 PowerShell Scripts by SysTech

Zestaw profesjonalnych, modularnych i gotowych do użycia skryptów PowerShell stworzonych przez SysTech do zarządzania środowiskiem Active Directory, GPO oraz uprawnieniami do zasobów sieciowych (NAS, ACL itp.).

Każdy skrypt przestrzega konwencji nazewnictwa `Czynność-Co.ps1`, co ułatwia porządkowanie i zrozumienie ich funkcji.

## 🧰 Zawartość repozytorium

### `Audit-ADGroupPermissions.ps1`
Interaktywnie przeprowadza audyt uprawnień wskazanej grupy AD do folderów i plików w udziałach sieciowych.
* **Wyróżniki**: Umożliwia wybór trybu rekursywnego, działa w pętli pozwalając na wielokrotne audyty z różnymi parametrami (zmiana grupy, ścieżek), wyniki wyświetla w konsoli z kolorami odróżniającymi pliki od folderów, oferuje opcjonalny zapis do pliku CSV.

### `Audit-GroupACLOnNAS.ps1`
Przeprowadza szczegółowy audyt uprawnień grupy AD do folderów na udziałach sieciowych (np. QNAP).
* **Wyróżniki**: Skanuje rekursywnie podane ścieżki UNC, odpytuje Active Directory o szczegóły grupy (w tym SID) dla dokładniejszego dopasowania, generuje plik CSV z wynikami (lub informacją o braku wyników), wyświetla dynamiczny, tekstowy pasek postępu w jednej linii konsoli.

### `Audit-GroupUsageInGPO.ps1`
Audytuje wykorzystanie wskazanej grupy Active Directory w Obiektach Zasad Grupy (GPO) w całej domenie.
* **Wyróżniki**: Analizuje wiele kontekstów użycia grupy: filtrowanie zabezpieczeń, grupy ograniczone, przypisywanie praw użytkownika, kierowanie na poziomie elementu (Item-Level Targeting) w Preferencjach Zasad Grupy (GPP) oraz ogólne wystąpienia nazwy lub SID grupy w wygenerowanych raportach XML z GPO. Wyniki wymagające dodatkowej uwagi są odpowiednio oznaczane.

### `Clean-DisabledUsersFromGroups.ps1`
Identyfikuje i opcjonalnie usuwa użytkowników z wyłączonymi kontami z grup zabezpieczeń AD.
* **Wyróżniki**: Optymalizuje proces pobierając listę wszystkich wyłączonych kont tylko raz, wyświetla pasek postępu podczas skanowania grup, a przed faktycznym usunięciem użytkowników z grup prosi o potwierdzenie operacji.

### `Copy-GroupACLsOnNAS.ps1`
Kopiuje uprawnienia ACL (Access Control List) z jednej grupy AD do drugiej na wszystkich folderach w określonej lokalizacji NAS.
* **Wyróżniki**: Interaktywnie pobiera od użytkownika nazwę grupy źródłowej, docelowej oraz ścieżkę sieciową do folderu nadrzędnego na NAS. Następnie iteruje po folderach i dla każdego folderu, w którym grupa źródłowa ma uprawnienia, tworzy i przypisuje analogiczne uprawnienia grupie docelowej.

### `Export-ADGroupMembers.ps1`
Eksportuje listę członków (lub tylko użytkowników) z wybranej grupy Active Directory do pliku tekstowego.
* **Wyróżniki**: Interaktywnie pyta o nazwę grupy oraz ścieżkę pliku docelowego (sugerując nazwę opartą o nazwę grupy i datę), pozwala na zdefiniowanie eksportowanego atrybutu członka (domyślnie `SamAccountName`) oraz umożliwia eksport wyłącznie obiektów typu 'user'. Jeśli grupa nie ma członków lub nie uda się wyodrębnić atrybutu, tworzony jest pusty plik.

### `Find-EmptyFolders.ps1`
Wyszukuje, listuje i opcjonalnie usuwa "najwyższego poziomu" puste foldery w podanej ścieżce lub ścieżkach.
* **Wyróżniki**: Definiuje folder jako "efektywnie pusty" (nie zawiera plików bezpośrednio, a wszystkie jego podfoldery są również "efektywnie puste"). Listuje tylko te puste foldery, które nie są podfolderami innych znalezionych pustych folderów. Oferuje interaktywne usuwanie z indywidualnym potwierdzeniem dla każdego folderu oraz wykorzystuje mechanizm cache'owania dla optymalizacji skanowania.

### `Find-Orphaned-HomeFolders.ps1`
Wykrywa "osierocone" foldery domowe, czyli katalogi w podanej lokalizacji (np. `\\NAS\Users`), które nie mają przypisanego aktywnego użytkownika w Active Directory.
* **Wyróżniki**: Skrypt interaktywnie pyta o ścieżkę do folderów domowych, pobiera listę aktywnych użytkowników z AD (SamAccountName) i porównuje ją z nazwami folderów. Oferuje zapis listy osieroconych folderów do pliku tekstowego (domyślnie na Pulpicie).

### `Get-ChromeVersionFromDomain.ps1`
Sprawdza wersję przeglądarki Google Chrome zainstalowanej na aktywnych komputerach w domenie Active Directory.
* **Wyróżniki**: Dla każdego komputera sprawdza dostępność (ping), weryfikuje komunikację WinRM (Test-WSMan) i jeśli jest potrzeba, pyta o zgodę na próbę zdalnej konfiguracji WinRM (`Enable-PSRemoting -Force`) oraz uruchomienia usługi. Próbuje również zdalnie zsynchronizować czas (`w32tm /resync /force`). Wersję Chrome ustala priorytetowo z pliku `chrome.exe` (w standardowych lokalizacjach) lub jako fallback z rejestru.

### `Import-ADGroupMembers.ps1`
Masowo dodaje członków do grupy Active Directory na podstawie listy identyfikatorów (np. SamAccountName) z pliku tekstowego.
* **Wyróżniki**: Odczytuje identyfikatory z pliku (jeden na linię), interaktywnie pyta o grupę docelową i ścieżkę pliku. Weryfikuje istnienie użytkownika w AD przed próbą dodania, pomija użytkowników już będących członkami (optymalizacja przez wstępne pobranie listy członków) oraz tych nieznalezionych w AD. Na koniec wyświetla szczegółowe podsumowanie operacji.

### `Remove-DisabledUsersFromShares.ps1`
Usuwa uprawnienia (wpisy ACL) przypisane wyłączonym użytkownikom Active Directory z folderów sieciowych we wskazanej lokalizacji.
* **Wyróżniki**: Działa wyłącznie na folderach (nie na plikach). Pobiera listę wyłączonych kont użytkowników (na podstawie ich SID), a następnie skanuje foldery, usuwając odpowiednie wpisy ACL. Wyświetla pasek postępu podczas operacji.

### `Remove-GroupPermissions.ps1`
Usuwa wszystkie wpisy ACL (Access Control List) powiązane ze wskazaną grupą z wszystkich folderów (nie plików) w podanej lokalizacji sieciowej.
* **Wyróżniki**: Skrypt interaktywnie pyta o nazwę grupy, której uprawnienia mają być usunięte, oraz o ścieżkę do folderu nadrzędnego. Przetwarza każdy folder, usuwając z jego ACL wszelkie wpisy dotyczące podanej grupy.

### `Report-ADGroupMembershipChanges.ps1`
Wykrywa i raportuje zmiany w członkostwie wskazanej grupy Active Directory na przestrzeni czasu.
* **Wyróżniki**: Użytkownik podaje nazwę grupy i ścieżkę do pliku referencyjnego. Skrypt pobiera aktualnych członków grupy (ich `SamAccountName`), porównuje z zawartością pliku referencyjnego (jeśli istnieje), a następnie raportuje dodanych i usuniętych członków. Po analizie aktualizuje plik referencyjny obecnym stanem.

### `Report-ADUserLastLogon.ps1`
Tworzy raport CSV zawierający informacje o ostatnim logowaniu użytkowników Active Directory.
* **Wyróżniki**: Zbierane dane to `SamAccountName`, Nazwa użytkownika, status konta (włączone/wyłączone), data ostatniego logowania (z atrybutu `LastLogonTimestamp`, konwertowanego na czytelny format) oraz obliczona liczba dni nieaktywności. Opcjonalnie raport może zawierać listę grup, do których należy użytkownik. Użytkownik jest proszony o wskazanie ścieżki zapisu pliku CSV (domyślnie Pulpit).

### `Report-ADUsersWithoutGroups.ps1`
Raportuje aktywne konta użytkowników w domenie Active Directory, które nie są członkami żadnej grupy (poza domyślną, np. "Domain Users").
* **Wyróżniki**: Skupia się wyłącznie na aktywnych użytkownikach, co pomaga identyfikować potencjalne błędy w zarządzaniu dostępami. Raport zapisywany jest do pliku tekstowego, a użytkownik może wskazać własną lokalizację zapisu (domyślnie Pulpit).

### `Report-EmptyADGroups.ps1`
Generuje raport z pustych grup Active Directory, które prawdopodobnie zostały utworzone przez użytkowników.
* **Wyróżniki**: Skrypt pomija grupy znajdujące się w domyślnych kontenerach systemowych (takich jak `CN=Users`, `CN=Builtin`), aby skupić się na grupach niestandardowych. Raport zapisywany jest do pliku tekstowego, z możliwością wyboru lokalizacji przez użytkownika (domyślnie Pulpit, z unikalnym timestampem w nazwie). Wyświetla pasek postępu podczas skanowania grup.

### `Uninstall-RemoteSoftware.ps1`
Umożliwia zdalną deinstalację aplikacji z wybranego komputera w domenie.
* **Wyróżniki**: Działa interaktywnie: pyta o nazwę komputera, sprawdza jego dostępność i stan usługi WinRM (podejmując próbę konfiguracji i uruchomienia w razie potrzeby). Listuje zainstalowane oprogramowanie (odczytując dane z rejestru HKLM i HKCU dla pełnego obrazu) i pozwala użytkownikowi wybrać wiele aplikacji do odinstalowania (podając numery po przecinku). Przed próbą deinstalacji aplikacji .exe, pyta o niestandardowe argumenty cichej deinstalacji. Operacja deinstalacji jest wykonywana jako zadanie w tle z lokalnym wskaźnikiem postępu i próbą wyświetlenia ID zdalnego procesu. Implementuje timeout dla każdej operacji deinstalacji i raportuje kod wyjściowy. Obsługuje `ShouldProcess` dla bezpieczeństwa.

---

## 🛠️ Wymagania (Ogólne)

- PowerShell w wersji 5.1 lub nowszej (zalecane PowerShell 7+).
- Odpowiednie uprawnienia administracyjne do wykonywania operacji na Active Directory, GPO oraz systemach zdalnych (odczyt ACL, modyfikacja ACL, zarządzanie usługami itp.).
- Moduły PowerShell:
  - `ActiveDirectory` (wymagany przez większość skryptów).
  - `GroupPolicy` (wymagany przez `Audit-GroupUsageInGPO.ps1`).

## 📦 Sposób użycia

Większość skryptów jest interaktywna i jeśli nie zostaną podane wymagane parametry przy uruchomieniu, skrypt poprosi o nie użytkownika. Szczegółowe informacje o parametrach i przykłady użycia znajdują się w blokach komentarzy (SYNOPSIS, DESCRIPTION, PARAMETER, EXAMPLE) na początku każdego pliku `.ps1`.

Aby uruchomić skrypt, otwórz konsolę PowerShell, przejdź do katalogu ze skryptami i wykonaj polecenie, np.:

```powershell
.\Audit-ADGroupPermissions.ps1 -GroupName "NazwaTwojejGrupy" -ParentFolderPathsToScan "\\Serwer\Udział"
.\Get-ChromeVersionFromDomain.ps1
