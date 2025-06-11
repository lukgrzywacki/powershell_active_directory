<#
.SYNOPSIS
    Audytuje i opcjonalnie usuwa uprawnienia do folderów, inteligentnie rozróżniając prawa jawne i dziedziczone.
.DESCRIPTION
    Skrypt rekursywnie skanuje podaną ścieżkę sieciową i analizuje listy kontroli dostępu (ACL) folderów.
    Po zakończeniu skanowania prezentuje raport w dwóch czytelnych sekcjach:

    1. Problematyczni Użytkownicy i SID-y:
       - Listuje wyłączone konta użytkowników oraz osierocone SID-y.
       - Pod każdym wpisem wyświetla listę folderów, do których ma on prawa, z wyraźnym oznaczeniem,
         czy uprawnienie jest JAWNE (można je usunąć) czy DZIECZICZONE.

    2. Nadmiarowe Uprawnienia w Folderach:
       - W osobnej sekcji raportuje o nadmiarowych uprawnieniach.

    3. Interaktywne Usuwanie Uprawnień:
       - W interaktywnej pętli pozwala na usunięcie uprawnień dla kont osieroconych [O] lub wyłączonych [W].
       - Skrypt podejmie próbę usunięcia uprawnień osieroconych zawsze, a uprawnień dla kont wyłączonych
         tylko wtedy, gdy nie są one dziedziczone.

    Wersja: 1.6 (Data modyfikacji: 11.06.2025)
    Autor: Łukasz Grzywacki (SysTech Łukasz Grzywacki) & Gemini
.PARAMETER RootPath
    Opcjonalny. Pełna ścieżka UNC do folderu głównego, od którego rozpocznie się skanowanie.
.EXAMPLE
    .\Audit-RedundantAndOrphanedPermissions.ps1 -RootPath "\\NAS01\Wspolny"
    Przeskanuje udział, a następnie pozwoli na inteligentne czyszczenie uprawnień.
.NOTES
    - UWAGA: Operacja usuwania uprawnień jest nieodwracalna.
    - Wymagany jest moduł PowerShell 'ActiveDirectory'.
    - Skrypt wymaga uprawnień do ZAPISU list ACL, jeśli planowane jest usuwanie.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Podaj pełną ścieżkę UNC do folderu głównego, który ma być przeskanowany.")]
    [string]$RootPath
)

# --- [KROK 1: Inicjalizacja i Wprowadzanie Danych] ---
Write-Host "--- Rozpoczynanie skryptu audytu uprawnień (Osierocone i Nadmiarowe) ---" -ForegroundColor Green
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) { Write-Error "[BŁĄD KRYTYCZNY] Moduł 'ActiveDirectory' nie jest dostępny..."; exit 1 }
try { Import-Module ActiveDirectory -ErrorAction Stop; Write-Host "[INFO] Moduł ActiveDirectory gotowy." -ForegroundColor Green }
catch { Write-Error "[BŁĄD KRYTYCZNY] Nie udało się zaimportować modułu...: $($_.Exception.Message)"; exit 1 }
if ([string]::IsNullOrWhiteSpace($RootPath)) { $RootPath = Read-Host "[WEJŚCIE] Podaj ścieżkę do folderu głównego" }
if ([string]::IsNullOrWhiteSpace($RootPath)) { Write-Error "[BŁĄD KRYTYCZNY] Ścieżka jest wymagana."; exit 1 }
if (-not (Test-Path -Path $RootPath -PathType Container)) { Write-Error "[BŁĄD KRYTYCZNY] Ścieżka '$RootPath' nie istnieje..."; exit 1 }
Write-Host "[INFO] Ścieżka docelowa: '$RootPath'" -ForegroundColor Cyan

# --- [KROK 2: Przygotowanie Danych z Active Directory (Optymalizacja)] ---
Write-Host "`n[INFO] Przygotowywanie danych z AD..." -ForegroundColor Yellow
try {
    $disabledUserSids = (Get-ADUser -Filter 'Enabled -eq $false' -ErrorAction Stop).SID | ForEach-Object { $_.Value }
    $disabledUserSidSet = New-Object 'System.Collections.Generic.HashSet[string]'
    if ($null -ne $disabledUserSids) { foreach ($sid in $disabledUserSids) { [void]$disabledUserSidSet.Add($sid) } }
    Write-Host "[INFO] Znaleziono $($disabledUserSidSet.Count) wyłączonych użytkowników." -ForegroundColor Green
} catch { Write-Error "[BŁĄD KRYTYCZNY] Nie udało się pobrać wyłączonych użytkowników..."; exit 1 }
$allDomainSidsSet = New-Object 'System.Collections.Generic.HashSet[string]'
try {
    $allUsers = Get-ADUser -Filter * -ErrorAction Stop; $allGroups = Get-ADGroup -Filter * -ErrorAction Stop
    foreach ($user in $allUsers) { [void]$allDomainSidsSet.Add($user.SID.Value) }
    foreach ($group in $allGroups) { [void]$allDomainSidsSet.Add($group.SID.Value) }
    Write-Host "[INFO] Załadowano $($allDomainSidsSet.Count) obiektów z AD." -ForegroundColor Green
} catch { Write-Error "[BŁĄD KRYTYCZNY] Nie udało się pobrać obiektów z AD..."; exit 1 }


# --- [KROK 3: Skanowanie Folderów i Gromadzenie Danych] ---
Write-Host "`n[INFO] Rozpoczynam rekursywne skanowanie folderów w '$RootPath'. To może potrwać..." -ForegroundColor Yellow
$problematicPrincipals = @{}
$redundantFindings = [System.Collections.Generic.List[PSCustomObject]]::new()
try {
    $allFolders = Get-ChildItem -Path $RootPath -Recurse -Directory -Force -ErrorAction SilentlyContinue
    $rootFolderObject = Get-Item -Path $RootPath
    $allFolders = @($rootFolderObject) + $allFolders
    $totalFolders = $allFolders.Count
    $processedFolders = 0
    Write-Host "[INFO] Znaleziono $totalFolders folderów do przeanalizowania."

    foreach ($folder in $allFolders) {
        $processedFolders++
        Write-Progress -Activity "Analiza uprawnień ACL" -Status "Skanowanie: $($folder.FullName)" -PercentComplete (($processedFolders / $totalFolders) * 100)
        try {
            $acl = Get-Acl -Path $folder.FullName -ErrorAction Stop
            $usersWithAccessOnFolder = @{}
            $groupsWithAccessOnFolder = @{}

            foreach ($ace in $acl.Access) {
                $identity = $ace.IdentityReference
                if ($identity.Value -like "BUILTIN\*" -or $identity.Value -like "NT AUTHORITY\*" -or $identity.Value -like "AUTORYTET NT\*") { continue }
                try {
                    $sid = $identity.Translate([System.Security.Principal.SecurityIdentifier])
                    $sidValue = $sid.Value
                    $problemType = $null
                    if (-not $allDomainSidsSet.Contains($sidValue)) { $problemType = 'Orphaned' }
                    elseif ($disabledUserSidSet.Contains($sidValue)) { $problemType = 'Disabled' }

                    if ($problemType) {
                        if (-not $problematicPrincipals.ContainsKey($sidValue)) {
                            $problematicPrincipals[$sidValue] = [PSCustomObject]@{ Type = $problemType; Name = $identity.Value; Paths = [System.Collections.Generic.List[PSCustomObject]]::new() }
                        }
                        $problematicPrincipals[$sidValue].Paths.Add([PSCustomObject]@{ Path = $folder.FullName; IsInherited = $ace.IsInherited })
                        continue
                    }
                    $adObject = Get-ADObject -Identity $sid -ErrorAction SilentlyContinue
                    if ($adObject) {
                        if ($adObject.ObjectClass -eq 'user') { $usersWithAccessOnFolder[$adObject.SamAccountName] = $adObject }
                        elseif ($adObject.ObjectClass -eq 'group') { $groupsWithAccessOnFolder[$adObject.SamAccountName] = $adObject }
                    }
                } catch { }
            }
            if ($usersWithAccessOnFolder.Count -gt 0 -and $groupsWithAccessOnFolder.Count -gt 0) {
                foreach ($userEntry in $usersWithAccessOnFolder.GetEnumerator()) {
                    $userObject = $userEntry.Value
                    try {
                        $userGroups = Get-ADPrincipalGroupMembership -Identity $userObject.SamAccountName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName
                        if ($null -ne $userGroups) {
                            $intersectingGroups = $userGroups | Where-Object { $groupsWithAccessOnFolder.ContainsKey($_) }
                            if ($intersectingGroups) {
                                $redundantFindings.Add([PSCustomObject]@{ Path = $folder.FullName; Principal = $userObject.SamAccountName; Details = "Użytkownik ma bezpośrednie prawa i należy do grupy z uprawnieniami: $($intersectingGroups -join ', ')"})
                            }
                        }
                    } catch { }
                }
            }
        } catch { Write-Warning "Nie udało się odczytać ACL dla folderu '$($folder.FullName)'. Błąd: $($_.Exception.Message.Split([Environment]::NewLine)[0])" }
    }
    Write-Progress -Activity "Analiza uprawnień ACL" -Completed
} catch { Write-Error "[BŁĄD KRYTYCZNY] Wystąpił błąd podczas listowania folderów w '$RootPath'."; exit 1 }


# --- [KROK 4: Prezentacja Wyników] ---
if ($problematicPrincipals.Count -eq 0 -and $redundantFindings.Count -eq 0) {
    Write-Host "`n--- [WYNIKI AUDYTU] ---" -ForegroundColor Green
    Write-Host "Gratulacje! Nie znaleziono żadnych osieroconych, wyłączonych ani nadmiarowych uprawnień." -ForegroundColor Green
} else {
    Write-Host "`n--- [WYNIKI AUDYTU] ---" -ForegroundColor Yellow
    if ($problematicPrincipals.Count -gt 0) {
        Write-Host "`n--- Sekcja 1: Osierocone i Wyłączone Konta ---" -ForegroundColor White
        $sortedPrincipals = $problematicPrincipals.GetEnumerator() | Sort-Object { $_.Value.Name }
        foreach ($entry in $sortedPrincipals) {
            $principalInfo = $entry.Value
            $color = if ($principalInfo.Type -eq 'Orphaned') { "Red" } else { "DarkYellow" }
            $typeDesc = if ($principalInfo.Type -eq 'Orphaned') { "Osierocony SID" } else { "Użytkownik Wyłączony" }
            Write-Host "`n[$typeDesc] $($principalInfo.Name)" -ForegroundColor $color
            foreach ($pathObject in ($principalInfo.Paths | Sort-Object Path)) {
                Write-Host "  - Posiada prawa do: $($pathObject.Path)" -NoNewline
                if ($pathObject.IsInherited) { Write-Host " (DZIECZICZONE)" -ForegroundColor Gray }
                else { Write-Host " (JAWNE)" -ForegroundColor Green }
            }
        }
    }
    if ($redundantFindings.Count -gt 0) {
        Write-Host "`n--- Sekcja 2: Nadmiarowe Uprawnienia Użytkowników ---" -ForegroundColor White
        $groupedRedundant = $redundantFindings | Group-Object -Property Path | Sort-Object Name
        foreach ($group in $groupedRedundant) {
            Write-Host "`n[FOLDER] $($group.Name)" -ForegroundColor Magenta
            foreach ($finding in $group.Group) { Write-Host "  - Użytkownik: $($finding.Principal)`n    Szczegóły: $($finding.Details)" }
        }
    }
}


# --- [KROK 5: Interaktywne Usuwanie Uprawnień] ---
if ($problematicPrincipals.Count -gt 0) {
    Write-Host "`n`n--- [AKCJA] Interaktywne Czyszczenie Uprawnień ---" -ForegroundColor Cyan
    do {
        $orphanedCount = ($problematicPrincipals.Values | Where-Object { $_.Type -eq 'Orphaned' }).Count
        $disabledCount = ($problematicPrincipals.Values | Where-Object { $_.Type -eq 'Disabled' }).Count

        if ($orphanedCount -eq 0 -and $disabledCount -eq 0) {
            Write-Host "`n[INFO] Wszystkie modyfikowalne problemy z uprawnieniami zostały rozwiązane." -ForegroundColor Green
            break
        }

        Write-Host "`nAktualne podsumowanie problemów:"
        Write-Host "- Konta osierocone: $orphanedCount" -ForegroundColor Red
        Write-Host "- Konta wyłączone: $disabledCount" -ForegroundColor DarkYellow
        $choice = Read-Host -Prompt "Co chcesz zrobić? [O]sierocone ($orphanedCount) / [W]yłączone ($disabledCount) / [N]ie (zakończ czyszczenie)"
        
        $targetType = $null
        switch ($choice.ToUpper()) {
            'O' { if ($orphanedCount -gt 0) { $targetType = 'Orphaned'; Write-Host "`n[INFO] Rozpoczynam usuwanie uprawnień dla kont OSIEROCONYCH..." -ForegroundColor Yellow } else { Write-Host "[INFO] Brak kont osieroconych do przetworzenia." -ForegroundColor Green } }
            'W' { if ($disabledCount -gt 0) { $targetType = 'Disabled'; Write-Host "`n[INFO] Rozpoczynam usuwanie uprawnień dla kont WYŁĄCZONYCH..." -ForegroundColor Yellow } else { Write-Host "[INFO] Brak kont wyłączonych do przetworzenia." -ForegroundColor Green } }
            'N' { Write-Host "[INFO] Zakończono sesję czyszczenia uprawnień." -ForegroundColor Green; break } # <-- POPRAWKA: Dodano 'break'
            default { Write-Warning "[OSTRZEŻENIE] Nieprawidłowy wybór. Spróbuj ponownie." }
        }

        if ($targetType) {
            $sidsToProcess = ($problematicPrincipals.GetEnumerator() | Where-Object { $_.Value.Type -eq $targetType }).Key
            foreach ($sid in $sidsToProcess) {
                $principalInfo = $problematicPrincipals[$sid]
                Write-Host "`n--- Przetwarzanie: '$($principalInfo.Name)' (SID: $sid) ---" -ForegroundColor Cyan
                $pathsToRemoveFromPrincipal = [System.Collections.Generic.List[PSCustomObject]]::new()

                foreach ($pathObject in $principalInfo.Paths) {
                    # === POPRAWKA: Logika sprawdzania dziedziczenia ===
                    # Ignoruj flagę IsInherited tylko dla kont osieroconych. Dla wyłączonych sprawdzaj ją nadal.
                    if ($principalInfo.Type -ne 'Orphaned' -and $pathObject.IsInherited) {
                        Write-Warning "[POMINIĘTO] Uprawnienie dla '$($pathObject.Path)' jest dziedziczone. Należy je usunąć na folderze nadrzędnym."
                        continue
                    }

                    if ($PSCmdlet.ShouldProcess($pathObject.Path, "Usunięcie uprawnień dla '$($principalInfo.Name)'")) {
                        try {
                            $acl = Get-Acl -Path $pathObject.Path -ErrorAction Stop
                            $acesToRemove = $acl.Access | Where-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $sid }
                            
                            if ($acesToRemove) {
                                foreach ($ace in $acesToRemove) { $acl.RemoveAccessRule($ace) | Out-Null }
                                Set-Acl -Path $pathObject.Path -AclObject $acl -ErrorAction Stop
                                Write-Host "[SUKCES] Usunięto uprawnienia z folderu: $($pathObject.Path)" -ForegroundColor Green
                                $pathsToRemoveFromPrincipal.Add($pathObject)
                            }
                        } catch {
                            Write-Error "[BŁĄD] Nie udało się usunąć uprawnień z folderu '$($pathObject.Path)'. Szczegóły: $($_.Exception.Message)"
                        }
                    } else { Write-Warning "[POMINIĘTO] Operacja dla folderu '$($pathObject.Path)' została pominięta przez użytkownika (-WhatIf)." }
                }
                
                foreach ($removedPath in $pathsToRemoveFromPrincipal) { [void]$principalInfo.Paths.Remove($removedPath) }
                if ($principalInfo.Paths.Count -eq 0) { $problematicPrincipals.Remove($sid) }
            }
            Write-Host "`n[INFO] Zakończono usuwanie uprawnień dla typu '$targetType'." -ForegroundColor Green
        }
    } while ($true)
}

# --- [KROK 6: Zakończenie] ---
Write-Host "`n--- Skrypt audytu uprawnień zakończył pracę ---" -ForegroundColor Green
