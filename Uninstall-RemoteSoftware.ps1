<#
.SYNOPSIS
    Umożliwia zdalną deinstalację aplikacji z wybranego komputera w domenie.
    Skrypt interaktywnie prosi o nazwę komputera, sprawdza jego dostępność oraz stan usługi WinRM
    (próbując ją skonfigurować w razie potrzeby). Następnie listuje zainstalowane oprogramowanie
    (odczytując dane z rejestru HKLM i HKCU) i pozwala użytkownikowi wybrać aplikacje do odinstalowania
    (podając numery po przecinku). Przed próbą deinstalacji aplikacji .exe, pyta o niestandardowe argumenty.
    Wyświetla wskaźnik postępu podczas próby deinstalacji, próbuje pokazać ID zdalnego procesu,
    implementuje timeout dla operacji deinstalacji oraz raportuje kod wyjściowy.
.DESCRIPTION
    # ... (reszta opisu bez zmian, ale można by tu dodać info o timeout) ...
    7. Skrypt próbuje sekwencyjnie odinstalować każdą wybraną aplikację:
       Operacja deinstalacji jest wykonywana jako zadanie w tle, z lokalnym wskaźnikiem postępu.
       Skrypt oczekuje na zakończenie procesu deinstalacyjnego przez określony czas (timeout).
       Jeśli proces nie zakończy się w tym czasie, skrypt podejmie próbę jego zatrzymania.
       Przechwytuje i raportuje kod wyjściowy oraz (jeśli dostępne) ID procesu instalatora.
       - Dla aplikacji MSI (rozpoznanych po UninstallString), próbuje użyć "msiexec.exe /x {PRODUCT_CODE} /qn /norestart".
       - Dla innych aplikacji (np. z deinstalatorami .exe), używa podanych przez użytkownika argumentów lub próbuje uruchomić UninstallString.
       - Jeśli podczas deinstalacji wystąpi błąd, skrypt wyświetla informację i pyta użytkownika, czy kontynuować z następnym programem z listy.
    # ... (reszta opisu bez zmian) ...
.NOTES
    # ... (reszta notatek bez zmian) ...
    - Zaimplementowano timeout (domyślnie 5 minut) dla operacji deinstalacji na zdalnej maszynie.

    Autor: Łukasz Grzywacki (SysTech Łukasz Grzywacki)
    Wersja: 1.8
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

# --- [POCZĄTEK SKRYPTU] ---
Write-Host "--- Rozpoczynanie skryptu zdalnej deinstalacji aplikacji ---" -ForegroundColor Green

do { # Główna pętla skryptu
    $CurrentPC = Read-Host "`nPodaj nazwę komputera, z którego chcesz odinstalować oprogramowanie (lub 'q' aby zakończyć)"
    if ($CurrentPC -eq 'q' -or [string]::IsNullOrWhiteSpace($CurrentPC)) {
        Write-Host "Zakończono działanie skryptu."
        break
    }

    Write-Host "[INFO] Sprawdzanie dostępności komputera: $CurrentPC..."
    if (-not (Test-Connection -ComputerName $CurrentPC -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Warning "[OSTRZEŻENIE] Komputer $CurrentPC jest nieosiągalny (ping nie odpowiada)."
        $RetryChoice = Read-Host "Czy chcesz spróbować z innym komputerem? [T/N]"
        if ($RetryChoice -ne 't') { Write-Host "Zakończono działanie skryptu."; break }
        continue 
    }
    Write-Host "[INFO] Komputer $CurrentPC jest dostępny (odpowiada na ping)." -ForegroundColor Green

    Write-Host "[INFO] Sprawdzanie podstawowej komunikacji WinRM z $CurrentPC za pomocą Test-WSMan..."
    $wsManTestSucceeded = $false
    try {
        Test-WSMan -ComputerName $CurrentPC -ErrorAction Stop
        Write-Host "[INFO] Test-WSMan dla $CurrentPC zakończony sukcesem. WinRM prawdopodobnie odpowiada." -ForegroundColor Green
        $wsManTestSucceeded = $true
    }
    catch {
        Write-Warning "[OSTRZEŻENIE] Test-WSMan dla $CurrentPC nie powiódł się. Szczegóły: $($_.Exception.Message)"
        Write-Warning "[OSTRZEŻENIE] Prawdopodobnie usługa WinRM na $CurrentPC nie jest skonfigurowana, nie nasłuchuje, lub zapora blokuje połączenie."
        
        $AttemptEnableRemoting = Read-Host "Czy chcesz spróbować zdalnie włączyć i skonfigurować PowerShell Remoting na $CurrentPC używając 'Enable-PSRemoting -Force'? (Wymaga uprawnień admina na $CurrentPC) [T/N]"
        if ($AttemptEnableRemoting -eq 't') {
            Write-Host "[INFO] Próba zdalnej konfiguracji WinRM na $CurrentPC za pomocą 'Enable-PSRemoting -Force'..."
            try {
                Invoke-Command -ComputerName $CurrentPC -ScriptBlock { Enable-PSRemoting -Force -SkipNetworkProfileCheck } -ErrorAction Stop
                Write-Host "[INFO] Polecenie 'Enable-PSRemoting -Force' zostało wysłane do $CurrentPC. Próba ponownego testu Test-WSMan..."
                Start-Sleep -Seconds 5 
                Test-WSMan -ComputerName $CurrentPC -ErrorAction Stop
                Write-Host "[INFO] Test-WSMan dla $CurrentPC po próbie konfiguracji ZAKOŃCZONY SUKCESEM." -ForegroundColor Green
                $wsManTestSucceeded = $true
            }
            catch {
                Write-Error "[BŁĄD] Próba zdalnej konfiguracji WinRM na $CurrentPC nie powiodła się lub Test-WSMan nadal zawodzi. Szczegóły: $($_.Exception.Message)"
                Write-Warning "[OSTRZEŻENIE] Sugerowane działania na $CurrentPC (jako administrator): 'winrm quickconfig', sprawdzenie reguł zapory dla portu 5985 (HTTP)."
            }
        } else {
            Write-Warning "[INFO] Pominięto próbę zdalnej konfiguracji WinRM."
        }
    }

    if (-not $wsManTestSucceeded) {
        Write-Error "[BŁĄD] Podstawowa komunikacja WinRM z $CurrentPC nie jest możliwa. Nie można kontynuować zdalnych operacji na tym komputerze."
        $RetryChoice = Read-Host "Czy chcesz spróbować z innym komputerem? [T/N]"
        if ($RetryChoice -ne 't') { Write-Host "Zakończono działanie skryptu."; break }
        continue
    }

    Write-Host "[INFO] Sprawdzanie statusu usługi WinRM na $CurrentPC (Invoke-Command)..."
    try {
        $winRMService = Invoke-Command -ComputerName $CurrentPC -ScriptBlock { Get-Service WinRM } -ErrorAction Stop
        if ($winRMService.Status -ne 'Running') {
            Write-Warning "[OSTRZEŻENIE] Usługa WinRM na $CurrentPC nie jest uruchomiona (Status: $($winRMService.Status)). Próba uruchomienia..."
            Invoke-Command -ComputerName $CurrentPC -ScriptBlock {
                Set-Service WinRM -StartupType Automatic -ErrorAction SilentlyContinue
                Start-Service WinRM -ErrorAction Stop
            }
            $winRMService = Invoke-Command -ComputerName $CurrentPC -ScriptBlock { Get-Service WinRM } 
            if ($winRMService.Status -eq 'Running') {
                Write-Host "[INFO] Usługa WinRM na $CurrentPC została pomyślnie uruchomiona." -ForegroundColor Green
            } else {
                Write-Error "[BŁĄD] Nie udało się uruchomić usługi WinRM na $CurrentPC (Aktualny status: $($winRMService.Status)). Pomijam ten komputer."
                $RetryChoiceLoop = Read-Host "Czy chcesz spróbować z innym komputerem? [T/N]"
                if ($RetryChoiceLoop -ne 't') { Write-Host "Zakończono działanie skryptu."; break }
                continue
            }
        } else {
            Write-Host "[INFO] Usługa WinRM na $CurrentPC jest uruchomiona." -ForegroundColor Green
        }
    } catch {
        Write-Error "[BŁĄD] Nie udało się wykonać Invoke-Command do sprawdzenia/uruchomienia usługi WinRM na $CurrentPC. Szczegóły: $($_.Exception.Message). Pomijam ten komputer."
        $RetryChoiceLoop = Read-Host "Czy chcesz spróbować z innym komputerem? [T/N]"
        if ($RetryChoiceLoop -ne 't') { Write-Host "Zakończono działanie skryptu."; break }
        continue
    }

    Write-Host "[INFO] Pobieranie listy zainstalowanego oprogramowania z $CurrentPC (z rejestru HKLM i HKCU, może to chwilę potrwać)..." -ForegroundColor Cyan
    $InstalledSoftware = @()
    try {
        $InstalledSoftware = Invoke-Command -ComputerName $CurrentPC -ScriptBlock {
            $uninstallPaths = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' 
            )
            $softwareList = foreach ($path in $uninstallPaths) {
                Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -and $_.UninstallString } |
                    Select-Object DisplayName, DisplayVersion, Publisher, UninstallString, PSChildName 
            }
            $softwareList = $softwareList | Sort-Object DisplayName, DisplayVersion | Group-Object DisplayName, DisplayVersion | ForEach-Object {$_.Group | Select-Object -First 1}
            return $softwareList | Sort-Object DisplayName
        } -ErrorAction Stop
        
        if ($InstalledSoftware.Count -eq 0) {
            Write-Warning "[OSTRZEŻENIE] Nie znaleziono żadnego oprogramowania (z rejestru) na komputerze $CurrentPC."
            $ContinueAfterNoSoftware = Read-Host "Brak oprogramowania do wylistowania. Czy chcesz spróbować z innym komputerem? [T/N]"
            if ($ContinueAfterNoSoftware -ne 't') { break } else { continue }
        }
    }
    catch {
        Write-Error "[BŁĄD] Nie udało się pobrać listy oprogramowania z $CurrentPC. Szczegóły: $($_.Exception.Message)"
        $ContinueAfterSoftwareError = Read-Host "Błąd pobierania listy oprogramowania. Czy chcesz spróbować z innym komputerem? [T/N]"
        if ($ContinueAfterSoftwareError -ne 't') { break } else { continue }
    }

    Write-Host "`nZainstalowane oprogramowanie na $($CurrentPC):" -ForegroundColor Yellow
    for ($i = 0; $i -lt $InstalledSoftware.Count; $i++) {
        Write-Host ("{0,3}. {1} (Wersja: {2}, Producent: {3})" -f ($i + 1), $InstalledSoftware[$i].DisplayName, $InstalledSoftware[$i].DisplayVersion, $InstalledSoftware[$i].Publisher)
    }
    
    $UserChoicesString = Read-Host "`nWybierz NUMERY programów do odinstalowania z '$CurrentPC' (oddzielone przecinkami, np. 1,3,5), 'c' aby anulować dla tego komputera, 'q' aby zakończyć skrypt"
    if ($UserChoicesString -eq 'q') { Write-Host "Zakończono działanie skryptu."; exit 0 }
    if ($UserChoicesString -eq 'c' -or [string]::IsNullOrWhiteSpace($UserChoicesString)) { 
        Write-Host "Anulowano wybór programów dla $CurrentPC."
        $AskForNextOpAfterCancel = Read-Host "Czy chcesz wybrać inny komputer lub zakończyć? [I/Z] (Inny komputer / Zakończ)"
        if ($AskForNextOpAfterCancel -eq 'i') { continue } else { break }
    }

    $SelectedIndices = @()
    $ChoicesArray = $UserChoicesString.Split(',') | ForEach-Object {$_.Trim()}
    foreach ($SingleChoice in $ChoicesArray) {
        if ($SingleChoice -match "^\d+$" -and [int]$SingleChoice -ge 1 -and [int]$SingleChoice -le $InstalledSoftware.Count) {
            $SelectedIndices += ([int]$SingleChoice - 1) 
        } else {
            Write-Warning "Nieprawidłowy numer w wyborze: '$SingleChoice'. Zostanie pominięty."
        }
    }
    $SelectedIndices = $SelectedIndices | Sort-Object -Unique 

    if ($SelectedIndices.Count -eq 0) {
        Write-Warning "Nie wybrano żadnych prawidłowych programów do odinstalowania."
    } else {
        Write-Host "[INFO] Wybrano $($SelectedIndices.Count) program(ów) do próby deinstalacji." -ForegroundColor Cyan
        
        $uninstallLoopCounter = 0 
        foreach ($SelectedIndex in $SelectedIndices) {
            $uninstallLoopCounter++
            $SelectedSoftwareToUninstall = $InstalledSoftware[$SelectedIndex]
            $SoftwareUninstallString = $SelectedSoftwareToUninstall.UninstallString
            $SoftwareName = $SelectedSoftwareToUninstall.DisplayName
            $ProductCodeForMSI = $SelectedSoftwareToUninstall.PSChildName 
            $UserProvidedUninstallArgs = $null 

            Write-Host "`n--- Próba deinstalacji ($($uninstallLoopCounter) z $($SelectedIndices.Count)): '$SoftwareName' na komputerze: $CurrentPC ---" -ForegroundColor Yellow
            Write-Host "[INFO] UninstallString z rejestru: $SoftwareUninstallString" -ForegroundColor DarkGray

            if (-not ($SoftwareUninstallString -match "msiexec.exe" -or $SoftwareUninstallString -match "MsiExec.exe")) {
                $useCustomArgsChoice = Read-Host "Czy chcesz podać niestandardowe argumenty cichej deinstalacji dla '$SoftwareName'? [T/N]"
                if ($useCustomArgsChoice -eq 't') {
                    $UserProvidedUninstallArgs = Read-Host "Podaj argumenty cichej deinstalacji dla '$SoftwareName' (np. /S /VERYSILENT). Zastąpią one automatycznie parsowane argumenty."
                }
            }

            if ($PSCmdlet.ShouldProcess($CurrentPC, "Zdalna deinstalacja '$SoftwareName'")) { 
                $RemoteUninstallScriptBlock = {
                    param(
                        $TargetSoftwareName,
                        $TargetUninstallString,
                        $TargetProductCode,
                        $CustomArgs 
                    )
                    $OperationStatus = [PSCustomObject]@{
                        Success = $false 
                        ExitCode = -1 
                        Message = "Deinstalacja nie została zainicjowana."
                        ProcessId = $null 
                    }
                    try {
                        Write-Host "[ZDALNIE][$($env:COMPUTERNAME)] Próba deinstalacji: $TargetSoftwareName"
                        Write-Host "[ZDALNIE][$($env:COMPUTERNAME)] Używam UninstallString z rejestru: $TargetUninstallString"

                        $UninstallCommand = ""
                        $UninstallArgs = ""
                        $IsMsiUninstall = $false
                        $ProcessObj = $null 

                        if ($TargetUninstallString -match "msiexec.exe" -or $TargetUninstallString -match "MsiExec.exe") {
                            if ($TargetUninstallString -match "{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}}") { 
                                $ProductCode = $Matches[0]
                                $UninstallCommand = "msiexec.exe"
                                $UninstallArgs = "/x $ProductCode /qn /norestart /L*V `"$($env:TEMP)\$($TargetSoftwareName -replace '[^a-zA-Z0-9]','_')_uninstall.log`""
                                $IsMsiUninstall = $true
                                Write-Host "[ZDALNIE][$($env:COMPUTERNAME)] Rozpoznano jako deinstalację MSI. ProductCode: $ProductCode"
                            } elseif ($TargetProductCode -match "{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}}") {
                                $UninstallCommand = "msiexec.exe"
                                $UninstallArgs = "/x $TargetProductCode /qn /norestart /L*V `"$($env:TEMP)\$($TargetSoftwareName -replace '[^a-zA-Z0-9]','_')_uninstall.log`""
                                $IsMsiUninstall = $true
                                Write-Host "[ZDALNIE][$($env:COMPUTERNAME)] Rozpoznano jako deinstalację MSI (z PSChildName). ProductCode: $TargetProductCode"
                            }
                        }

                        if (-not $IsMsiUninstall) {
                            if (-not [string]::IsNullOrWhiteSpace($CustomArgs)) {
                                Write-Host "[ZDALNIE][$($env:COMPUTERNAME)] Używam niestandardowych argumentów deinstalacji: $CustomArgs"
                                $UninstallCommand = $TargetUninstallString.Trim('"') 
                                $UninstallArgs = $CustomArgs
                            } else {
                                Write-Warning "[ZDALNIE][$($env:COMPUTERNAME)] Wybrany program prawdopodobnie używa niestandardowego deinstalatora. Próba parsowania UninstallString."
                                $regex = '^("([^"]+)"|([^ ]+)) *(.*)' 
                                $matchResult = [regex]::Match($TargetUninstallString, $regex)
                                if ($matchResult.Success) {
                                    $UninstallCommand = if ($matchResult.Groups[2].Success) { $matchResult.Groups[2].Value } else { $matchResult.Groups[3].Value }
                                    $UninstallArgs = if ($matchResult.Groups[4].Success) { $matchResult.Groups[4].Value.Trim() } else { "" } 
                                } else {
                                    Write-Warning "[ZDALNIE][$($env:COMPUTERNAME)] Nie udało się sparsować UninstallString. Używam całości jako polecenia."
                                    $UninstallCommand = $TargetUninstallString 
                                    $UninstallArgs = ""
                                }
                            }
                             Write-Warning "[ZDALNIE][$($env:COMPUTERNAME)] Cicha deinstalacja dla tego typu (.EXE) może wymagać specyficznych przełączników. Skrypt użyje: Komenda='$UninstallCommand', Argumenty='$UninstallArgs'."
                        }
                        
                        if ([string]::IsNullOrWhiteSpace($UninstallCommand)) {
                             $OperationStatus.Message = "Nie udało się określić polecenia deinstalacyjnego dla '$TargetSoftwareName'."
                             Write-Error "[ZDALNIE][$($env:COMPUTERNAME)] $($OperationStatus.Message)"
                             return $OperationStatus
                        }

                        Write-Host "[ZDALNIE][$($env:COMPUTERNAME)] Polecenie deinstalacyjne: `"$UninstallCommand`" $UninstallArgs"
                        
                        # Uruchom proces bez -Wait, aby uzyskać ID, potem poczekaj
                        $ProcessObj = Start-Process -FilePath $UninstallCommand -ArgumentList $UninstallArgs -ErrorAction Stop -PassThru 
                        
                        if ($ProcessObj) {
                            $OperationStatus.ProcessId = $ProcessObj.Id
                            Write-Output ([PSCustomObject]@{DataType = 'PIDNotification'; RemoteProcessID = $OperationStatus.ProcessId})
                            Write-Host "[ZDALNIE][$($env:COMPUTERNAME)] Proces deinstalatora '$TargetSoftwareName' uruchomiony z PID: $($OperationStatus.ProcessId)."
                            
                            $waitTimeoutSeconds = 300 # 5 minut na deinstalację
                            Write-Host "[ZDALNIE][$($env:COMPUTERNAME)] Oczekiwanie na zakończenie procesu PID $($OperationStatus.ProcessId) (max. $waitTimeoutSeconds sekund)..."
                            
                            if ($ProcessObj.WaitForExit($waitTimeoutSeconds * 1000)) {
                                $OperationStatus.ExitCode = $ProcessObj.ExitCode
                                Write-Host "[ZDALNIE][$($env:COMPUTERNAME)] Proces (PID: $($OperationStatus.ProcessId)) zakończył działanie. Kod wyjściowy: $($OperationStatus.ExitCode)."
                            } else {
                                Write-Warning "[ZDALNIE][$($env:COMPUTERNAME)] Proces (PID: $($OperationStatus.ProcessId)) nie zakończył się w ciągu $waitTimeoutSeconds sekund (TIMEOUT)."
                                $OperationStatus.Message = "Proces deinstalatora (PID: $($OperationStatus.ProcessId)) przekroczył limit czasu $waitTimeoutSeconds s. Mógł zawisnąć lub wymagać interakcji."
                                $OperationStatus.ExitCode = -999 # Kod dla timeoutu
                                try {
                                    Write-Warning "[ZDALNIE][$($env:COMPUTERNAME)] Próba zatrzymania zawieszonego procesu PID $($OperationStatus.ProcessId)."
                                    Stop-Process -Id $OperationStatus.ProcessId -Force -ErrorAction SilentlyContinue
                                    Write-Warning "[ZDALNIE][$($env:COMPUTERNAME)] Podjęto próbę zatrzymania procesu PID $($OperationStatus.ProcessId)."
                                } catch {
                                    Write-Warning "[ZDALNIE][$($env:COMPUTERNAME)] Nie udało się zatrzymać procesu PID $($OperationStatus.ProcessId) po timeout."
                                }
                            }
                        } else {
                             Write-Error "[ZDALNIE][$($env:COMPUTERNAME)] Nie udało się uruchomić procesu deinstalatora '$TargetSoftwareName'."
                             $OperationStatus.Message = "Nie udało się uruchomić procesu deinstalatora."
                        }

                        if ($OperationStatus.ExitCode -eq 0) {
                            $OperationStatus.Success = $true
                            $OperationStatus.Message = "Deinstalacja '$TargetSoftwareName' zakończona z kodem 0 (prawdopodobnie sukces)."
                        } elseif ($IsMsiUninstall -and $OperationStatus.ExitCode -eq 3010) {
                            $OperationStatus.Success = $true
                            $OperationStatus.Message = "Deinstalacja MSI '$TargetSoftwareName' zakończona sukcesem, ale WYMAGANY JEST RESTART (kod 3010)."
                        } elseif ($OperationStatus.ExitCode -ne -999) { # Jeśli nie timeout, to był jakiś inny kod błędu
                            $OperationStatus.Message = "Deinstalacja '$TargetSoftwareName' zakończona z kodem $($OperationStatus.ExitCode), co może oznaczać błąd."
                        }
                        # Komunikat o timeout już jest w $OperationStatus.Message
                        
                        if ($OperationStatus.Success) { Write-Host "[ZDALNIE][$($env:COMPUTERNAME)] $($OperationStatus.Message)" } else { Write-Warning "[ZDALNIE][$($env:COMPUTERNAME)] $($OperationStatus.Message)"}

                    }
                    catch {
                        $ErrorMessage = "[ZDALNIE][$($env:COMPUTERNAME)] BŁĄD krytyczny podczas próby deinstalacji '$TargetSoftwareName'. Szczegóły: $($_.Exception.Message)"
                        Write-Error $ErrorMessage
                        $OperationStatus.Message = $ErrorMessage
                    }
                    return $OperationStatus
                }

                $Job = Invoke-Command -ComputerName $CurrentPC -ScriptBlock $RemoteUninstallScriptBlock -ArgumentList $SoftwareName, $SoftwareUninstallString, $ProductCodeForMSI, $UserProvidedUninstallArgs -AsJob 
                
                $spinnerChars = @('-', '\', '|', '/')
                $spinnerIndex = 0
                $remotePidValueFromJob = $null
                $progressLineBase = "[INFO] Trwa zdalna deinstalacja '$SoftwareName' na $($CurrentPC) (Zadanie: $($Job.Id))"
                $currentProgressLineText = $progressLineBase + ": " # Zmieniono nazwę zmiennej
                
                Write-Host $currentProgressLineText -NoNewline

                while ($Job.State -eq 'Running') {
                    if (-not $remotePidValueFromJob) {
                        $jobOutputSoFar = Receive-Job -Job $Job -Keep
                        if ($jobOutputSoFar) {
                            $pidNotificationObj = $jobOutputSoFar | Where-Object { $_.PSObject.Properties['DataType'] -and $_.DataType -eq 'PIDNotification' } | Select-Object -First 1
                            if ($pidNotificationObj -and $pidNotificationObj.RemoteProcessID) {
                                $remotePidValueFromJob = $pidNotificationObj.RemoteProcessID
                                $progressLineBase = "[INFO] Trwa zdalna deinstalacja '$SoftwareName' na $($CurrentPC) (Zadanie: $($Job.Id), Zdalny PID: $remotePidValueFromJob)"
                                Write-Host "`r$(' ' * ($currentProgressLineText.Length + 1))`r" -NoNewline 
                                $currentProgressLineText = $progressLineBase + ": "
                                Write-Host $currentProgressLineText -NoNewline
                            }
                        }
                    }
                    
                    Write-Host "$($spinnerChars[$spinnerIndex])" -NoNewline
                    Start-Sleep -Milliseconds 250
                    Write-Host "`b" -NoNewline 
                    $spinnerIndex = ($spinnerIndex + 1) % $spinnerChars.Length
                }
                
                Write-Host "`r$(' ' * ($currentProgressLineText.Length + 1))`r$($progressLineBase): Gotowe.  "
                Write-Host "" 

                $UninstallStatus = $null
                if ($Job.State -eq 'Completed') {
                    $JobOutput = Receive-Job -Job $Job -Wait 
                    $UninstallStatus = $JobOutput | Where-Object {$_ -is [PSCustomObject] -and $_.PSObject.Properties.Name -contains "ExitCode" } | Select-Object -Last 1

                    if ($UninstallStatus) {
                        Write-Host "[INFO] Przetworzono wyniki zdalnej deinstalacji na $CurrentPC dla '$SoftwareName'."
                        if ($UninstallStatus.ProcessId) { 
                            Write-Host "[INFO] ID Zdalnego Procesu Deinstalacyjnego (z obiektu statusu): $($UninstallStatus.ProcessId)" 
                        } elseif ($remotePidValueFromJob) { 
                             Write-Host "[INFO] ID Zdalnego Procesu Deinstalacyjnego (z wczesnego outputu): $remotePidValueFromJob"
                        } else {
                            Write-Host "[INFO] ID Zdalnego Procesu Deinstalacyjnego: Nie udało się uzyskać."
                        }
                        Write-Host "[INFO] Kod wyjściowy operacji deinstalacji: $($UninstallStatus.ExitCode)"
                        Write-Host "[INFO] Komunikat statusu: $($UninstallStatus.Message)"

                        if ($UninstallStatus.Success) {
                            Write-Host "[INFO] Status deinstalacji '$SoftwareName': SUKCES" -ForegroundColor Green
                        } else {
                            Write-Error "[BŁĄD] Status deinstalacji '$SoftwareName': NIEPOWODZENIE. Szczegóły: $($UninstallStatus.Message)"
                        }
                    } else {
                        Write-Warning "[OSTRZEŻENIE] Nie udało się uzyskać strukturalnego statusu deinstalacji '$SoftwareName' z $CurrentPC. Wyświetlam cały output zadania:"
                        $JobOutput 
                    }
                } else { 
                    Write-Error "[BŁĄD] Zadanie zdalnej deinstalacji '$SoftwareName' na $CurrentPC nie powiodło się. Stan: $($Job.State)"
                    Receive-Job -Job $Job -Wait 
                }
                Remove-Job -Job $Job -Force 

                if ($UninstallStatus -and -not $UninstallStatus.Success) {
                    $ContinueOnErrorChoice = Read-Host "Wystąpił błąd lub timeout podczas deinstalacji '$SoftwareName'. Czy chcesz kontynuować z następnym wybranym programem (jeśli są)? [T/N]"
                    if ($ContinueOnErrorChoice -ne 't') {
                        Write-Warning "Przerwano dalsze deinstalacje na tym komputerze."
                        break 
                    }
                }
                
            } else { 
                 Write-Warning "[INFO] Pominięto deinstalację '$SoftwareName' na $CurrentPC z powodu opcji -WhatIf lub braku potwierdzenia."
            }
        } 
    } 

    $NextActionChoice = Read-Host "`nCzy chcesz wykonać kolejną operację (inny komputer lub ten sam)? [T/N]"
    if ($NextActionChoice -ne 't') {
        Write-Host "Zakończono działanie skryptu."
        break 
    }

} while ($true)

# Czyszczenie lokalnego folderu tymczasowego, jeśli istnieje
if ($LocalStagingDir -and (Test-Path -Path $LocalStagingDir -PathType Container)) {
    Write-Host "[INFO] Usuwanie lokalnego katalogu tymczasowego: $LocalStagingDir"
    Remove-Item -Path $LocalStagingDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n--- Skrypt zdalnej deinstalacji aplikacji zakończył całkowicie działanie ---" -ForegroundColor Green