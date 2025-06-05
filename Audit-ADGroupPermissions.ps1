<#
.SYNOPSIS
    Przeprowadza audyt uprawnień wskazanej grupy Active Directory do folderów i plików
    w podanych głównych udziałach sieciowych. Użytkownik może wybrać, czy skanowanie ma być rekursywne.
    Wyniki są listowane w konsoli, z różnymi kolorami dla folderów i plików.
    Po skanowaniu, użytkownik ma opcję zapisania wyników do pliku CSV.
    Skrypt działa w pętli, pozwalając na wielokrotne sprawdzanie.
.DESCRIPTION
    Skrypt skanuje zdefiniowane ścieżki UNC. Użytkownik decyduje, czy przeszukiwać tylko
    bezpośrednią zawartość podanych ścieżek, czy również wszystkie podfoldery.
    Dla każdego znalezionego elementu (folderu/pliku) odczytuje listę kontroli dostępu (ACL)
    i analizuje ją pod kątem uprawnień dla określonej grupy AD.
    Wyświetla pasek postępu w konsoli. Foldery, do których grupa ma uprawnienia, są listowane na zielono,
    a pliki na niebiesko.
    Po każdym skanowaniu, użytkownik może zapisać znalezione elementy do pliku CSV w wybranej lokalizacji
    (Pulpit, Dokumenty, Pobrane). Następnie może wybrać: sprawdzenie innej grupy, zmianę ścieżek,
    zmianę obu, lub zakończenie skryptu.
.PARAMETER GroupName
    Opcjonalny przy pierwszym uruchomieniu. Nazwa grupy Active Directory, której uprawnienia mają być sprawdzone.
    Jeśli nie podano, skrypt zapyta interaktywnie.
.PARAMETER ParentFolderPathsToScan
    Opcjonalny przy pierwszym uruchomieniu. Tablica ścieżek UNC do folderów głównych do przeskanowania.
    Jeśli nie podano, skrypt zapyta interaktywnie.
.EXAMPLE
    .\CheckGroupAccessOnNas.ps1 -GroupName "Marketing_Dzial" -ParentFolderPathsToScan "\\SERVER01\Share\Marketing"
    Audytuje uprawnienia, pyta o tryb skanowania, wyświetla wyniki, pyta o zapis do CSV, a następnie wyświetla menu.

.EXAMPLE
    .\CheckGroupAccessOnNas.ps1
    Skrypt uruchomi się w trybie interaktywnym.
.NOTES
    Wersja: 1.8
    Autor: Łukasz Grzywacki (SysTech Łukasz Grzywacki)
    Wymagania:
    - Moduł PowerShell 'ActiveDirectory'.
    - Konto uruchamiające skrypt musi posiadać uprawnienia do odczytu atrybutów grup w AD
      oraz uprawnienia do odczytu list ACL na skanowanych zasobach sieciowych.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "Nazwa grupy Active Directory do sprawdzenia.")]
    [string]$GroupName,

    [Parameter(Mandatory = $false, HelpMessage = "Tablica ścieżek UNC do folderów głównych do przeskanowania, np. '\\SERVER\Share','\\NAS\Data'.")]
    [string[]]$ParentFolderPathsToScan
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

function Get-ValidFolderPaths {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$PromptMessage
    )
    $paths = @()
    do {
        $inputPath = Read-Host -Prompt "$PromptMessage (wpisz ścieżkę i naciśnij Enter; pozostaw puste i naciśnij Enter, aby zakończyć dodawanie)"
        if (-not [string]::IsNullOrWhiteSpace($inputPath)) {
            if (Test-Path -Path $inputPath -PathType Container) {
                $paths += $inputPath
                Write-Host "[INFO] Dodano ścieżkę: $inputPath" -ForegroundColor Green
            } else {
                Write-Warning "Ścieżka '$inputPath' nie istnieje lub nie jest folderem. Spróbuj ponownie."
            }
        }
    } while (-not [string]::IsNullOrWhiteSpace($inputPath) -or $paths.Count -eq 0) 
    
    if ($paths.Count -eq 0) {
        Write-Error "Nie podano żadnych prawidłowych ścieżek do skanowania. Przerywam."
        exit 1 
    }
    return $paths
}

# Główna pętla skryptu
$ScriptRunning = $true
$ScanRecursively = $null # Inicjalizuj jako null, aby pytanie pojawiło się przy pierwszym uruchomieniu
$IsFirstRun = $true     # Flaga pierwszego uruchomienia

do {
    # --- [KROK 1: Inicjalizacja i Walidacja Parametrów] ---
    Write-Host "`n--- Rozpoczynanie nowej sesji audytu uprawnień grupy AD ---" -ForegroundColor Magenta

    if ([string]::IsNullOrWhiteSpace($GroupName)) {
        $GroupName = Get-ValidGroupName -PromptMessage "Podaj nazwę grupy Active Directory, której uprawnienia chcesz sprawdzić"
    }
    Write-Host "[INFO] Grupa do sprawdzenia: $GroupName" -ForegroundColor Cyan

    if ($null -eq $ParentFolderPathsToScan -or $ParentFolderPathsToScan.Count -eq 0) {
        $ParentFolderPathsToScan = Get-ValidFolderPaths -PromptMessage "Podaj ścieżkę UNC do folderu głównego do przeskanowania"
    }
    Write-Host "[INFO] Ścieżki do przeskanowania: $($ParentFolderPathsToScan -join ', ')" -ForegroundColor Cyan

    # Zapytaj o tryb skanowania (rekursywny czy nie), jeśli $ScanRecursively jest $null (pierwsza iteracja lub po opcji 3)
    if ($IsFirstRun -or ($null -eq $ScanRecursively)) { 
        $RecursiveChoice = Read-Host -Prompt "Czy przeszukiwać również podfoldery (rekursywnie)? [T/N] (Domyślnie N - tylko bieżący folder)"
        if ($RecursiveChoice -eq 't' -or $RecursiveChoice -eq 'T') {
            $ScanRecursively = $true
        } else {
            $ScanRecursively = $false
        }
        if ($IsFirstRun) { $IsFirstRun = $false } # Ustaw flagę na false po pierwszym zapytaniu
    }
    
    if ($ScanRecursively) {
        Write-Host "[INFO] Skanowanie będzie rekursywne (obejmie podfoldery)." -ForegroundColor Cyan
    } else {
        Write-Host "[INFO] Skanowanie obejmie tylko bezpośrednią zawartość podanych ścieżek." -ForegroundColor Cyan
    }


    Write-Host "[INFO] Sprawdzanie dostępności modułu ActiveDirectory..."
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Error "[BŁĄD KRYTYCZNY] Moduł 'ActiveDirectory' nie jest dostępny. Zainstaluj RSAT dla AD DS. Przerywam."
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

    $ADGroup = $null
    try {
        $ADGroup = Get-ADGroup -Identity $GroupName -Properties SID, SamAccountName -ErrorAction Stop
        Write-Host "[INFO] Pomyślnie pobrano dane grupy '$($ADGroup.Name)' (SID: $($ADGroup.SID.Value), SAM: $($ADGroup.SamAccountName))." -ForegroundColor Green
    }
    catch {
        Write-Error "[BŁĄD KRYTYCZNY] Nie udało się znaleźć grupy '$GroupName' w Active Directory lub wystąpił błąd. Szczegóły: $($_.Exception.Message)."
        Write-Warning "Sprawdź nazwę grupy i spróbuj ponownie."
        $GroupName = $null 
    }

    $ItemsWithAccessDetails = [System.Collections.Generic.List[PSCustomObject]]::new() 

    if ($null -ne $ADGroup) { 
        # --- [KROK 2: Skanowanie Elementów (Pliki i Foldery) i Analiza ACL] ---
        $ScannedItemCount = 0
        $ItemsWithAccessCount = 0
        Write-Host "`n[INFO] Rozpoczynam skanowanie elementów i analizę ACL dla grupy '$($ADGroup.Name)'..." -ForegroundColor Yellow
        Write-Host "Elementy (foldery/pliki), do których grupa '$($ADGroup.Name)' posiada uprawnienia:" -ForegroundColor Yellow

        foreach ($RootPath in $ParentFolderPathsToScan) {
            Write-Host "`n[INFO] Przetwarzanie ścieżki głównej: $RootPath ($(if ($ScanRecursively) { 'rekursywnie' } else { 'tylko bezpośrednia zawartość' }))" -ForegroundColor Cyan
            try {
                $gciParams = @{
                    Path = $RootPath
                    Force = $true
                    ErrorAction = 'SilentlyContinue'
                }
                if ($ScanRecursively) {
                    $gciParams.Recurse = $true
                }
                                
                $ItemsToScan = Get-ChildItem @gciParams
                
                if (-not $ScanRecursively) {
                    $RootItemItself = Get-Item -Path $RootPath -Force -ErrorAction SilentlyContinue
                    if ($RootItemItself -and ($ItemsToScan -notcontains $RootItemItself)) {
                        if (($ItemsToScan | Where-Object {$_.FullName -eq $RootItemItself.FullName}).Count -eq 0) {
                             $ItemsToScan = @($RootItemItself) + $ItemsToScan
                        }
                    }
                }

                if ($null -eq $ItemsToScan -or $ItemsToScan.Count -eq 0) {
                    Write-Warning "[OSTRZEŻENIE] Nie znaleziono żadnych elementów w '$RootPath' (lub brak dostępu)."
                    continue 
                }

                foreach ($Item in $ItemsToScan) {
                    $ScannedItemCount++
                    Write-Progress -Activity "Skanowanie uprawnień dla grupy '$($ADGroup.Name)'" -Status "Przetwarzanie: $($Item.FullName)" -PercentComplete (($ScannedItemCount % 100)) 

                    try {
                        $Acl = Get-Acl -Path $Item.FullName -ErrorAction Stop
                        foreach ($AccessRule in $Acl.Access) {
                            if (($AccessRule.IdentityReference -eq $ADGroup.SID.Value) -or 
                                ($AccessRule.IdentityReference.Value -eq $ADGroup.SamAccountName) -or
                                ($AccessRule.IdentityReference.Value -eq "$($env:USERDOMAIN)\$($ADGroup.SamAccountName)") -or 
                                ($AccessRule.IdentityReference.Value -eq $ADGroup.Name)) {
                                
                                $ItemType = if ($Item.PSIsContainer) { "Folder" } else { "Plik" }
                                $ItemsWithAccessDetails.Add([PSCustomObject]@{
                                    Sciezka = $Item.FullName
                                    Typ     = $ItemType
                                })

                                if ($Item.PSIsContainer) { 
                                    Write-Host $Item.FullName -ForegroundColor Green
                                } else { 
                                    Write-Host $Item.FullName -ForegroundColor Blue
                                }
                                $ItemsWithAccessCount++
                                break 
                            }
                        }
                    }
                    catch {
                        Write-Warning "[OSTRZEŻENIE] Nie udało się odczytać ACL dla elementu '$($Item.FullName)'. Szczegóły: $($_.Exception.Message)"
                    }
                }
            }
            catch {
                 Write-Error "[BŁĄD] Wystąpił błąd podczas przetwarzania ścieżki '$RootPath'. Szczegóły: $($_.Exception.Message)"
            }
        }
        Write-Progress -Activity "Skanowanie uprawnień" -Completed

        # --- [KROK 3: Podsumowanie] ---
        Write-Host "`n[INFO] Zakończono skanowanie." -ForegroundColor Green
        Write-Host "[INFO] Przetworzono łącznie: $ScannedItemCount elementów."
        if ($ItemsWithAccessCount -gt 0) {
            Write-Host "[INFO] Znaleziono $ItemsWithAccessCount elementów, do których grupa '$($ADGroup.Name)' ma uprawnienia (wylistowane powyżej)." -ForegroundColor Green
        } else {
            Write-Host "[INFO] Nie znaleziono żadnych elementów na skanowanych ścieżkach, do których grupa '$($ADGroup.Name)' miałaby uprawnienia." -ForegroundColor Yellow
        }

        # --- [KROK 3.5: Opcjonalny Zapis do Pliku CSV] ---
        if ($ItemsWithAccessCount -gt 0) {
            $saveToCsvChoice = Read-Host "`nCzy chcesz zapisać listę znalezionych elementów do pliku CSV? [T/N]"
            if ($saveToCsvChoice -eq 't' -or $saveToCsvChoice -eq 'T') {
                $DesktopPath = [Environment]::GetFolderPath('Desktop')
                $DocumentsPath = [Environment]::GetFolderPath('MyDocuments')
                $DownloadsPath = ''
                try { 
                    $DownloadsPath = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name '{374DE290-123F-4565-9164-39C4925E467B}' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
                } catch {
                    Write-Warning "Nie udało się automatycznie zlokalizować folderu Pobrane. Ta opcja może nie być dostępna."
                }

                Write-Host "`nWybierz lokalizację zapisu pliku CSV:"
                Write-Host "1. Pulpit ($DesktopPath)"
                Write-Host "2. Dokumenty ($DocumentsPath)"
                if (-not [string]::IsNullOrWhiteSpace($DownloadsPath)) {
                    Write-Host "3. Pobrane ($DownloadsPath)"
                }
                
                $locationChoice = Read-Host -Prompt "Wybierz numer lokalizacji (lub inny aby pominąć)"
                $chosenPath = $null
                
                switch ($locationChoice) {
                    "1" { $chosenPath = $DesktopPath }
                    "2" { $chosenPath = $DocumentsPath }
                    "3" { if (-not [string]::IsNullOrWhiteSpace($DownloadsPath)) { $chosenPath = $DownloadsPath } }
                }

                if ($chosenPath -and (Test-Path $chosenPath -PathType Container)) {
                    $timestampForFile = Get-Date -Format "yyyyMMdd_HHmmss"
                    $csvFileName = "UprawnieniaGrupy_$($ADGroup.Name -replace '[^a-zA-Z0-9]','_')_$timestampForFile.csv"
                    $fullCsvPath = Join-Path -Path $chosenPath -ChildPath $csvFileName
                    try {
                        $ItemsWithAccessDetails | Export-Csv -Path $fullCsvPath -NoTypeInformation -Delimiter "," -Encoding UTF8 -ErrorAction Stop
                        Write-Host "[INFO] Wyniki zapisano do pliku CSV: $fullCsvPath" -ForegroundColor Green
                    } catch {
                        Write-Error "[BŁĄD] Nie udało się zapisać pliku CSV. Szczegóły: $($_.Exception.Message)"
                    }
                } else {
                    Write-Warning "Nie wybrano prawidłowej lokalizacji lub wystąpił błąd. Pominięto zapis do CSV."
                }
            }
        }
    } 

    # --- [KROK 4: Menu Dalszych Działań] ---
    if ($ScriptRunning) { 
        Write-Host "`n--- Opcje Dalszego Działania ---" -ForegroundColor Yellow
        Write-Host "1. Sprawdź inną grupę (aktualne ścieżki: $($ParentFolderPathsToScan -join ', '); Rekurencja: $ScanRecursively)"
        Write-Host "2. Sprawdź tę samą grupę ('$GroupName') w innej ścieżce (Rekurencja: $ScanRecursively)"
        Write-Host "3. Zmień grupę, ścieżkę i tryb rekurencji"
        Write-Host "4. Zakończ działanie skryptu"
        
        $choice = Read-Host -Prompt "Wybierz opcję (1-4)"
        
        switch ($choice) {
            "1" { $GroupName = $null } 
            "2" { $ParentFolderPathsToScan = $null } 
            "3" { $GroupName = $null; $ParentFolderPathsToScan = $null; $ScanRecursively = $null } 
            "4" { Write-Host "Kończenie działania skryptu..."; $ScriptRunning = $false } 
            default { Write-Warning "Nieprawidłowy wybór. W następnej iteracji zostaną użyte poprzednie wartości lub skrypt poprosi o nowe." }
        }
    }

} while ($ScriptRunning) 

Write-Host "`n--- Skrypt audytu uprawnień zakończył pracę ---" -ForegroundColor Green