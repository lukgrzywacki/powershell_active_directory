<#
.SYNOPSIS
    Sprawdza wersję przeglądarki Google Chrome zainstalowanej na aktywnych komputerach w domenie Active Directory.
    Próbuje włączyć i skonfigurować WinRM oraz zsynchronizować czas na komputerach docelowych, 
    jeśli jest to konieczne i użytkownik wyrazi zgodę.
.DESCRIPTION
    Skrypt pobiera listę wszystkich aktywnych (włączonych) komputerów z domeny.
    Dla każdego komputera:
    1. Sprawdza, czy jest online (odpowiada na ping).
    2. Wykonuje Test-WSMan w celu weryfikacji podstawowej komunikacji WinRM.
       - Jeśli Test-WSMan zawiedzie, informuje o problemach i pyta użytkownika, czy podjąć próbę
         zdalnej konfiguracji WinRM za pomocą "Enable-PSRemoting -Force -SkipNetworkProfileCheck".
       - Jeśli użytkownik się zgodzi, skrypt próbuje wykonać to polecenie zdalnie.
       - Po próbie, Test-WSMan jest wykonywany ponownie.
    3. Jeśli WinRM odpowiada (Test-WSMan sukces), skrypt sprawdza stan usługi WinRM.
       - Jeśli usługa nie jest uruchomiona, próbuje ją uruchomić i ustawić na start automatyczny.
    4. Jeśli usługa WinRM działa, skrypt podejmuje próbę zdalnej synchronizacji czasu na komputerze docelowym
       za pomocą polecenia "w32tm /resync /force".
    5. Jeśli komputer jest dostępny i WinRM działa, skrypt próbuje zdalnie ustalić wersję Google Chrome.
       Priorytetowo sprawdzana jest wersja pliku chrome.exe w standardowych lokalizacjach instalacji.
       Jako fallback, skrypt próbuje odczytać wersję z rejestru.
    Wyniki są zbierane i wyświetlane w tabeli w konsoli.
.EXAMPLE
    .\Get-DomainChromeVersions.ps1
    Uruchamia skrypt w celu sprawdzenia wersji Chrome na wszystkich aktywnych komputerach w domenie.
.NOTES
    Wersja: 1.3
    Autor: Łukasz Grzywacki (SysTech Łukasz Grzywacki) przy pomocy Asystenta AI

    Wymagania:
    - Moduł PowerShell 'ActiveDirectory'.
    - Konto uruchamiające skrypt musi mieć uprawnienia do odczytu obiektów komputerów w AD.
    - PowerShell Remoting (WinRM) musi być włączony i skonfigurowany na komputerach docelowych.
      Skrypt podejmie próbę podstawowej konfiguracji WinRM oraz synchronizacji czasu.
    - Konto uruchamiające skrypt MUSI MIEĆ UPRAWNIENIA ADMINISTRATORA na komputerach docelowych
      do zdalnej konfiguracji WinRM, synchronizacji czasu i wykonywania poleceń.
    - Zapora sieciowa na komputerach docelowych musi zezwalać na komunikację WinRM.
    - Problemy z uwierzytelnianiem Kerberos (np. błąd 0x80090322) mogą wskazywać na brakujące SPN dla usługi WinRM
      na komputerze docelowym, problemy z synchronizacją czasu lub brak zaufania między domenami.
      Skrypt próbuje zsynchronizować czas, ale inne problemy mogą wymagać manualnej interwencji.
.INPUTS
    Brak.
.OUTPUTS
    Tablica obiektów PSCustomObject wyświetlana w konsoli.
#>

# --- [KROK 1: Inicjalizacja i Sprawdzenie Wymagań] ---
Write-Host "--- Rozpoczynanie skryptu sprawdzania wersji Google Chrome na komputerach domenowych ---" -ForegroundColor Green

Write-Host "[INFO] Sprawdzanie dostępności modułu ActiveDirectory..."
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "[BŁĄD KRYTYCZNY] Moduł 'ActiveDirectory' nie jest dostępny. Zainstaluj RSAT dla AD DS. Przerywam."
    exit 1
}
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Host "[INFO] Moduł ActiveDirectory załadowany." -ForegroundColor Green
} catch {
    Write-Error "[BŁĄD KRYTYCZNY] Nie udało się zaimportować modułu ActiveDirectory. Szczegóły: $($_.Exception.Message). Przerywam."
    exit 1
}

# --- [KROK 2: Pobieranie Aktywnych Komputerów z AD] ---
Write-Host "`n[INFO] Pobieranie listy aktywnych komputerów z Active Directory..."
$ActiveComputers = @()
try {
    $ActiveComputers = Get-ADComputer -Filter { Enabled -eq $true } -ErrorAction Stop | Select-Object -ExpandProperty Name
    if ($ActiveComputers.Count -eq 0) {
        Write-Warning "[OSTRZEŻENIE] Nie znaleziono żadnych aktywnych komputerów w domenie."
        Write-Host "`n--- Skrypt zakończył działanie (brak komputerów do sprawdzenia) ---" -ForegroundColor Yellow
        exit 0
    }
    Write-Host "[INFO] Znaleziono $($ActiveComputers.Count) aktywnych komputerów do sprawdzenia." -ForegroundColor Green
}
catch {
    Write-Error "[BŁĄD KRYTYCZNY] Nie udało się pobrać listy komputerów z AD. Szczegóły: $($_.Exception.Message). Przerywam."
    exit 1
}

# --- [KROK 3: Pętla po Komputerach i Sprawdzanie Wersji Chrome] ---
$Results = [System.Collections.Generic.List[PSCustomObject]]::new()
$TotalComputers = $ActiveComputers.Count
$ProcessedCount = 0

Write-Host "`n[INFO] Rozpoczynam sprawdzanie wersji Chrome na poszczególnych komputerach..."
foreach ($ComputerName in $ActiveComputers) {
    $ProcessedCount++
    Write-Progress -Activity "Sprawdzanie wersji Chrome" -Status "Przetwarzanie komputera: $ComputerName ($ProcessedCount/$TotalComputers)" -PercentComplete (($ProcessedCount / $TotalComputers) * 100)
    
    $CurrentStatus = ""
    $CurrentChromeVersion = "N/A"
    $CurrentVersionSource = "N/A"
    $CurrentErrorMessage = ""
    $WinRMConfiguredSuccessfully = $false
    $TimeSyncedSuccessfully = $false

    Write-Host "[INFO] Przetwarzanie: $ComputerName" -ForegroundColor Cyan

    if (-not (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Warning "[OSTRZEŻENIE] Komputer $($ComputerName) jest nieosiągalny (ping nie odpowiada)."
        $CurrentStatus = "Offline"
    } else {
        Write-Host "[INFO] Komputer $ComputerName jest online. Sprawdzanie WinRM..."
        
        Write-Host "[INFO] Sprawdzanie podstawowej komunikacji WinRM z $ComputerName za pomocą Test-WSMan..."
        try {
            Test-WSMan -ComputerName $ComputerName -ErrorAction Stop
            Write-Host "[INFO] Test-WSMan dla $ComputerName zakończony sukcesem. WinRM prawdopodobnie odpowiada." -ForegroundColor Green
            $WinRMConfiguredSuccessfully = $true
        }
        catch {
            Write-Warning "[OSTRZEŻENIE] Test-WSMan dla $ComputerName nie powiódł się. Szczegóły: $($_.Exception.Message)"
            Write-Warning "[OSTRZEŻENIE] Prawdopodobnie usługa WinRM na $ComputerName nie jest skonfigurowana, nie nasłuchuje, lub zapora blokuje połączenie."
            
            $AttemptEnableRemoting = Read-Host "Czy chcesz spróbować zdalnie włączyć i skonfigurować PowerShell Remoting na $ComputerName używając 'Enable-PSRemoting -Force'? (Wymaga uprawnień admina na $ComputerName) [T/N]"
            if ($AttemptEnableRemoting -eq 't') {
                Write-Host "[INFO] Próba zdalnej konfiguracji WinRM na $ComputerName za pomocą 'Enable-PSRemoting -Force'..."
                try {
                    Invoke-Command -ComputerName $ComputerName -ScriptBlock { Enable-PSRemoting -Force -SkipNetworkProfileCheck } -ErrorAction Stop
                    Write-Host "[INFO] Polecenie 'Enable-PSRemoting -Force' zostało wysłane do $ComputerName. Próba ponownego testu Test-WSMan..."
                    Start-Sleep -Seconds 5 
                    Test-WSMan -ComputerName $ComputerName -ErrorAction Stop
                    Write-Host "[INFO] Test-WSMan dla $ComputerName po próbie konfiguracji ZAKOŃCZONY SUKCESEM." -ForegroundColor Green
                    $WinRMConfiguredSuccessfully = $true
                }
                catch {
                    $ErrorMessage = $_.Exception.Message
                    Write-Error "[BŁĄD] Próba zdalnej konfiguracji WinRM na $ComputerName nie powiodła się lub Test-WSMan nadal zawodzi. Szczegóły: $ErrorMessage"
                    if ($ErrorMessage -match "0x80090322" -or $ErrorMessage -match "Kerberos") {
                        Write-Warning "[OSTRZEŻENIE KERBEROS] Wygląda na problem z uwierzytelnianiem Kerberos. Sprawdź SPN dla $ComputerName (np. 'setspn -L $ComputerName'), synchronizację czasu oraz zaufania domenowe."
                    } else {
                        Write-Warning "[OSTRZEŻENIE] Sugerowane działania na $ComputerName (jako administrator): 'winrm quickconfig', sprawdzenie reguł zapory dla portu 5985 (HTTP)."
                    }
                    $CurrentStatus = "Błąd konfiguracji WinRM"
                }
            } else {
                Write-Warning "[INFO] Pominięto próbę zdalnej konfiguracji WinRM."
                $CurrentStatus = "WinRM nieskonfigurowany (pominięto próbę)"
            }
        }

        if ($WinRMConfiguredSuccessfully) {
            Write-Host "[INFO] Sprawdzanie statusu usługi WinRM na $ComputerName (Invoke-Command)..."
            try {
                $winRMService = Invoke-Command -ComputerName $ComputerName -ScriptBlock { Get-Service WinRM } -ErrorAction Stop
                if ($winRMService.Status -ne 'Running') {
                    Write-Warning "[OSTRZEŻENIE] Usługa WinRM na $ComputerName nie jest uruchomiona (Status: $($winRMService.Status)). Próba uruchomienia..."
                    Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                        Set-Service WinRM -StartupType Automatic -ErrorAction SilentlyContinue
                        Start-Service WinRM -ErrorAction Stop
                    }
                    $winRMService = Invoke-Command -ComputerName $ComputerName -ScriptBlock { Get-Service WinRM } 
                    if ($winRMService.Status -eq 'Running') {
                        Write-Host "[INFO] Usługa WinRM na $ComputerName została pomyślnie uruchomiona." -ForegroundColor Green
                        $CurrentStatus = "Online, WinRM OK"
                    } else {
                        Write-Error "[BŁĄD] Nie udało się uruchomić usługi WinRM na $ComputerName (Aktualny status: $($winRMService.Status))."
                        $CurrentStatus = "WinRM - błąd startu usługi"
                        $WinRMConfiguredSuccessfully = $false 
                    }
                } else {
                    Write-Host "[INFO] Usługa WinRM na $ComputerName jest uruchomiona." -ForegroundColor Green
                    $CurrentStatus = "Online, WinRM OK"
                }
            } catch {
                $ErrorMessage = $_.Exception.Message
                Write-Error "[BŁĄD] Nie udało się wykonać Invoke-Command do sprawdzenia/uruchomienia usługi WinRM na $ComputerName. Szczegóły: $ErrorMessage"
                 if ($ErrorMessage -match "0x80090322" -or $ErrorMessage -match "Kerberos") {
                    Write-Warning "[OSTRZEŻENIE KERBEROS] Wygląda na problem z uwierzytelnianiem Kerberos przy próbie połączenia Invoke-Command. Sprawdź SPN dla $ComputerName (np. 'setspn -L $ComputerName'), synchronizację czasu oraz zaufania domenowe."
                }
                $CurrentStatus = "WinRM - błąd Invoke-Command"
                $WinRMConfiguredSuccessfully = $false 
            }
        }
        
        # Próba synchronizacji czasu, jeśli WinRM jest skonfigurowany i usługa działa
        if ($WinRMConfiguredSuccessfully -and $CurrentStatus -eq "Online, WinRM OK") {
            Write-Host "[INFO] Próba synchronizacji czasu na $ComputerName..."
            try {
                Invoke-Command -ComputerName $ComputerName -ScriptBlock { 
                    Write-Host "[ZDALNIE][$($env:COMPUTERNAME)] Uruchamianie w32tm /resync /force"
                    w32tm /resync /force 
                } -ErrorAction Stop
                Write-Host "[INFO] Polecenie synchronizacji czasu wysłane do $ComputerName." -ForegroundColor Green
                $TimeSyncedSuccessfully = $true # Zakładamy sukces, jeśli polecenie nie rzuciło błędu
            } catch {
                $ErrorMessage = $_.Exception.Message
                Write-Warning "[OSTRZEŻENIE] Nie udało się zsynchronizować czasu na $ComputerName. Szczegóły: $ErrorMessage"
                if ($ErrorMessage -match "0x80090322" -or $ErrorMessage -match "Kerberos") {
                    Write-Warning "[OSTRZEŻENIE KERBEROS] Błąd Kerberos podczas próby synchronizacji czasu. Może to nadal być problem z SPN/czasem."
                }
                $CurrentErrorMessage += " Błąd synchr. czasu: " + $ErrorMessage.Split([Environment]::NewLine)[0] + ";"
            }
        }

        if ($WinRMConfiguredSuccessfully -and $CurrentStatus -eq "Online, WinRM OK") {
            Write-Host "[INFO] WinRM na $ComputerName działa. Próba pobrania wersji Chrome..."
            try {
                $RemoteOutput = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                    $chromeVersionInfo = $null
                    $foundPath = $null
                    
                    $possibleExePaths = @(
                        "C:\Program Files\Google\Chrome\Application\chrome.exe",
                        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
                        (Join-Path $env:LOCALAPPDATA "Google\Chrome\Application\chrome.exe") 
                    )

                    foreach ($path in $possibleExePaths) {
                        if (Test-Path $path -PathType Leaf) {
                            try {
                                $fileInfo = Get-Item -Path $path -ErrorAction Stop
                                if ($fileInfo.VersionInfo.ProductVersion) {
                                    $chromeVersionInfo = $fileInfo.VersionInfo.ProductVersion
                                    $foundPath = $path
                                    break
                                } elseif ($fileInfo.VersionInfo.FileVersion) { 
                                    $chromeVersionInfo = $fileInfo.VersionInfo.FileVersion
                                    $foundPath = $path
                                    break
                                }
                            } catch { }
                        }
                    }

                    if (-not $chromeVersionInfo) {
                        $regKeysToCheck = @{
                            "HKLM:\SOFTWARE\WOW6432Node\Google\Update\Clients\{8A69D345-D564-463c-AFF1-A69D9E530F96}" = "pv"; 
                            "HKLM:\SOFTWARE\Google\Update\Clients\{8A69D345-D564-463c-AFF1-A69D9E530F96}" = "pv";            
                        }
                        foreach ($keyEntry in $regKeysToCheck.GetEnumerator()) {
                            try {
                                if (Test-Path $keyEntry.Name) {
                                    $regVersion = (Get-ItemProperty -Path $keyEntry.Name -ErrorAction SilentlyContinue).($keyEntry.Value)
                                    if ($regVersion) {
                                        $chromeVersionInfo = $regVersion
                                        $foundPath = "Rejestr: $($keyEntry.Name)"
                                        break
                                    }
                                }
                            } catch { }
                        }
                    }
                    
                    if ($chromeVersionInfo) {
                        return [PSCustomObject]@{ ChromeVersion = $chromeVersionInfo; VersionSource = $foundPath; Error = $null }
                    } else {
                        return [PSCustomObject]@{ ChromeVersion = "Nie znaleziono"; VersionSource = "N/A"; Error = "Nie udało się ustalić wersji Chrome." }
                    }
                } -ErrorAction Stop 

                if ($RemoteOutput) {
                    $CurrentChromeVersion = $RemoteOutput.ChromeVersion
                    $CurrentVersionSource = $RemoteOutput.VersionSource
                    if ($RemoteOutput.Error) {
                        $CurrentErrorMessage += " $($RemoteOutput.Error);"
                        Write-Warning "[OSTRZEŻENIE] $($ComputerName): $($RemoteOutput.Error)" 
                    }
                } else {
                     $CurrentErrorMessage += " Invoke-Command (wersja Chrome) nie zwrócił danych;"
                     Write-Warning "[OSTRZEŻENIE] $($ComputerName): Invoke-Command nie zwrócił danych (wersja Chrome)." 
                }
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                $CurrentErrorMessage += " Błąd pobierania wersji Chrome: " + $ErrorMessage.Split([Environment]::NewLine)[0] + ";"
                Write-Error "[BŁĄD] Błąd podczas wykonywania zdalnego polecenia na $($ComputerName): $ErrorMessage" 
                 if ($ErrorMessage -match "0x80090322" -or $ErrorMessage -match "Kerberos") {
                    Write-Warning "[OSTRZEŻENIE KERBEROS] Wygląda na problem z uwierzytelnianiem Kerberos przy próbie pobrania wersji Chrome. Sprawdź SPN dla $ComputerName, synchronizację czasu oraz zaufania domenowe."
                }
                $CurrentStatus = "Błąd WinRM/Skryptu (pobieranie wersji)" 
            }
        } elseif (-not $WinRMConfiguredSuccessfully -and $CurrentStatus -notlike "Offline") { 
             $CurrentStatus = "WinRM nieskonfigurowany/błąd"
        }
    } 
    
    $Results.Add([PSCustomObject]@{
        ComputerName = $ComputerName
        Status = $CurrentStatus
        ChromeVersion = $CurrentChromeVersion
        VersionSource = $CurrentVersionSource
        ErrorMessage = $CurrentErrorMessage.Trim(";")
    })
}
Write-Progress -Activity "Sprawdzanie wersji Chrome" -Completed

# --- [KROK 4: Wyświetlanie Wyników] ---
Write-Host "`n--- Wyniki Sprawdzania Wersji Google Chrome ---" -ForegroundColor Yellow
if ($Results.Count -gt 0) {
    $Results | Format-Table -AutoSize -Wrap
} else {
    Write-Host "[INFO] Brak wyników do wyświetlenia."
}

Write-Host "`n--- Skrypt zakończył działanie ---" -ForegroundColor Green