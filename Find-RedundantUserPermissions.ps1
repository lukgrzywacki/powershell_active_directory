<#
.SYNOPSIS
    Wykrywa i opcjonalnie usuwa nadmiarowe uprawnienia, generując przy tym interaktywny raport HTML.
.DESCRIPTION
    Skrypt rekursywnie skanuje podaną ścieżkę, analizując listy kontroli dostępu (ACL) folderów,
    aby znaleźć sytuacje, w których użytkownik posiada bezpośrednie uprawnienia, mimo że jest
    członkiem grupy, która również ma dostęp do tego samego zasobu.

    Kluczowe funkcje:
    1. Porównanie konkretnych praw (FileSystemRights) użytkownika i grupy w celu identyfikacji
       identycznych lub różnych poziomów dostępu.
    2. Generowanie nowoczesnego, interaktywnego raportu HTML z funkcją wyszukiwania i estetyczną
       prezentacją danych za pomocą rozwijanych list i ikon.
    3. Możliwość interaktywnego usuwania nadmiarowych uprawnień, ale tylko w przypadkach, gdy
       prawa użytkownika i grupy są identyczne. Proces jest zabezpieczony podwójnym potwierdzeniem.

    Wersja: 1.5 (Data modyfikacji: 11.06.2025)
    Autor: Łukasz Grzywacki (SysTech Łukasz Grzywacki) & Gemini
.PARAMETER RootPath
    Opcjonalny. Pełna ścieżka UNC do folderu głównego, od którego rozpocznie się skanowanie.
.PARAMETER OutputPath
    Opcjonalny. Pełna ścieżka do zapisu pliku raportu HTML.
.EXAMPLE
    .\Find-RedundantUserPermissions.ps1 -RootPath "\\NAS01\Marketing"
    Przeskanuje udział, wyświetli wyniki w konsoli, a następnie pozwoli na zapis raportu i opcjonalne czyszczenie uprawnień.

.EXAMPLE
    .\Find-RedundantUserPermissions.ps1 -RootPath "\\NAS01\Public" -OutputPath "C:\Raporty\Public_Redundancje.html"
    Przeskanuje udział i od razu zapisze raport do podanego pliku, pomijając pytanie o zapis.
.NOTES
    - UWAGA: Operacja usuwania uprawnień jest nieodwracalna. Należy jej używać z najwyższą rozwagą.
    - Wymagany jest moduł PowerShell 'ActiveDirectory'.
    - Skrypt wymaga uprawnień do ZAPISU list ACL, jeśli planowane jest usuwanie uprawnień.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Podaj pełną ścieżkę UNC do folderu głównego, który ma być przeskanowany.")]
    [string]$RootPath,

    [Parameter(Mandatory = $false, HelpMessage = "Pełna ścieżka do zapisu pliku raportu HTML.")]
    [string]$OutputPath
)

# --- [KROK 1: Inicjalizacja i Wprowadzanie Danych] ---
Write-Host "--- Rozpoczynanie skryptu audytu nadmiarowych uprawnień użytkowników ---" -ForegroundColor Green
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) { Write-Error "[BŁĄD KRYTYCZNY] Moduł 'ActiveDirectory' nie jest dostępny..."; exit 1 }
try { Import-Module ActiveDirectory -ErrorAction Stop; Write-Host "[INFO] Moduł ActiveDirectory gotowy." -ForegroundColor Green }
catch { Write-Error "[BŁĄD KRYTYCZNY] Nie udało się zaimportować modułu...: $($_.Exception.Message)"; exit 1 }
if ([string]::IsNullOrWhiteSpace($RootPath)) { $RootPath = Read-Host "[WEJŚCIE] Podaj ścieżkę do folderu głównego" }
if ([string]::IsNullOrWhiteSpace($RootPath)) { Write-Error "[BŁĄD KRYTYCZNY] Ścieżka jest wymagana."; exit 1 }
if (-not (Test-Path -Path $RootPath -PathType Container)) { Write-Error "[BŁĄD KRYTYCZNY] Ścieżka '$RootPath' nie istnieje..."; exit 1 }
Write-Host "[INFO] Ścieżka docelowa: '$RootPath'" -ForegroundColor Cyan

# --- [KROK 2: Przygotowanie Danych z Active Directory (Optymalizacja)] ---
Write-Host "`n[INFO] Przygotowywanie danych z AD w celu optymalizacji skanowania. To może chwilę potrwać..." -ForegroundColor Yellow
$sidToNameMap = @{}
$userToGroupsMap = @{}
$nameToSidMap = @{} # Nowa mapa do wyszukiwania SID po nazwie
try {
    $allGroups = Get-ADGroup -Filter *
    $allUsers = Get-ADUser -Filter * -Properties MemberOf
    $groupDnToSidMap = @{}
    foreach ($group in $allGroups) {
        $sidToNameMap[$group.SID.Value] = $group.Name
        $nameToSidMap[$group.Name] = $group.SID.Value
        $groupDnToSidMap[$group.DistinguishedName] = $group.SID.Value
    }
    foreach ($user in $allUsers) {
        $sidToNameMap[$user.SID.Value] = $user.SamAccountName
        $nameToSidMap[$user.SamAccountName] = $user.SID.Value
        $userGroupSids = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($groupDn in $user.MemberOf) {
            if ($groupDnToSidMap.ContainsKey($groupDn)) {
                [void]$userGroupSids.Add($groupDnToSidMap[$groupDn])
            }
        }
        $userToGroupsMap[$user.SID.Value] = $userGroupSids
    }
    Write-Host "[INFO] Pomyślnie zbudowano mapę członkostw dla $($userToGroupsMap.Count) użytkowników." -ForegroundColor Green
}
catch { Write-Error "[BŁĄD KRYTYCZNY] Nie udało się przygotować danych z AD..."; exit 1 }


# --- [KROK 3: Skanowanie Folderów i Analiza ACL] ---
Write-Host "`n[INFO] Rozpoczynam rekursywne skanowanie folderów w '$RootPath'..." -ForegroundColor Yellow
$redundantFindings = [System.Collections.Generic.List[PSCustomObject]]::new()
try {
    $allFolders = Get-ChildItem -Path $RootPath -Recurse -Directory -Force -ErrorAction SilentlyContinue
    $rootFolderObject = Get-Item -Path $RootPath
    $allFolders = @($rootFolderObject) + $allFolders
    $totalFolders = $allFolders.Count; $processedFolders = 0
    Write-Host "[INFO] Znaleziono $totalFolders folderów do przeanalizowania."
    foreach ($folder in $allFolders) {
        $processedFolders++; Write-Progress -Activity "Analiza uprawnień" -Status "Skanowanie: $($folder.FullName)" -PercentComplete (($processedFolders / $totalFolders) * 100)
        try {
            $acl = Get-Acl -Path $folder.FullName -ErrorAction Stop
            $userAclsOnFolder = @{}; $groupAclsOnFolder = @{}
            foreach ($ace in $acl.Access) {
                if ($ace.AccessControlType -ne 'Allow') { continue }
                $identity = $ace.IdentityReference
                if ($identity.Value -like "BUILTIN\*" -or $identity.Value -like "NT AUTHORITY\*" -or $identity.Value -like "AUTORYTET NT\*") { continue }
                try {
                    $sidValue = $identity.Translate([System.Security.Principal.SecurityIdentifier]).Value
                    if ($userToGroupsMap.ContainsKey($sidValue)) {
                        if (-not $userAclsOnFolder.ContainsKey($sidValue)) { $userAclsOnFolder[$sidValue] = 0 }
                        $userAclsOnFolder[$sidValue] = $userAclsOnFolder[$sidValue] -bor $ace.FileSystemRights
                    } elseif ($sidToNameMap.ContainsKey($sidValue)) {
                        if (-not $groupAclsOnFolder.ContainsKey($sidValue)) { $groupAclsOnFolder[$sidValue] = 0 }
                        $groupAclsOnFolder[$sidValue] = $groupAclsOnFolder[$sidValue] -bor $ace.FileSystemRights
                    }
                } catch { }
            }
            if ($userAclsOnFolder.Count -gt 0 -and $groupAclsOnFolder.Count -gt 0) {
                foreach ($userSid in $userAclsOnFolder.Keys) {
                    $intersectingGroupSids = $userToGroupsMap[$userSid] | Where-Object { $groupAclsOnFolder.ContainsKey($_) }
                    if ($intersectingGroupSids) {
                        foreach ($groupSid in $intersectingGroupSids) {
                            $redundantFindings.Add([PSCustomObject]@{
                                Path = $folder.FullName; User = $sidToNameMap[$userSid]; UserRights = $userAclsOnFolder[$userSid].ToString()
                                RedundantViaGroup = $sidToNameMap[$groupSid]; GroupRights = $groupAclsOnFolder[$groupSid].ToString()
                            })
                        }
                    }
                }
            }
        } catch { Write-Warning "Nie udało się odczytać ACL dla folderu '$($folder.FullName)'. Błąd: $($_.Exception.Message.Split([Environment]::NewLine)[0])" }
    }
    Write-Progress -Activity "Analiza uprawnień" -Completed
} catch { Write-Error "[BŁĄD KRYTYCZNY] Wystąpił błąd podczas listowania folderów w '$RootPath'..."; exit 1 }


# --- [KROK 4: Prezentacja Wyników w Konsoli] ---
if ($redundantFindings.Count -eq 0) {
    Write-Host "`n--- [WYNIKI AUDYTU] ---" -ForegroundColor Green
    Write-Host "Gratulacje! Nie znaleziono żadnych nadmiarowych uprawnień w skanowanej lokalizacji." -ForegroundColor Green
} else {
    Write-Host "`n--- [WYNIKI AUDYTU] ---" -ForegroundColor Yellow
    Write-Host "Znaleziono $($redundantFindings.Count) przypadków nadmiarowych uprawnień. Raport poniżej:"
    $groupedFindings = $redundantFindings | Group-Object -Property Path | Sort-Object Name
    foreach ($group in $groupedFindings) {
        Write-Host "`n----------------------------------------------------------------"
        Write-Host "Folder: $($group.Name)" -ForegroundColor White
        Write-Host "----------------------------------------------------------------"
        $findingsByUser = $group.Group | Group-Object -Property User
        foreach($userFindingGroup in $findingsByUser){
            Write-Host "Użytkownik " -NoNewline; Write-Host "'$($userFindingGroup.Name)'" -ForegroundColor Magenta -NoNewline
            Write-Host " | Prawa bezpośrednie: " -NoNewline; Write-Host "$($userFindingGroup.Group[0].UserRights)" -ForegroundColor Yellow
            foreach ($finding in $userFindingGroup.Group) {
                Write-Host "  - Jest w grupie: " -NoNewline; Write-Host "'$($finding.RedundantViaGroup)'" -ForegroundColor Cyan -NoNewline
                Write-Host " | Prawa grupy: " -NoNewline; Write-Host "$($finding.GroupRights)" -ForegroundColor Yellow -NoNewline
                if ($finding.UserRights -eq $finding.GroupRights) { Write-Host " -> (UPRAWNIENIA IDENTYCZNE)" -ForegroundColor Green }
                else { Write-Host " -> (RÓŻNE UPRAWNIENIA)" -ForegroundColor Red }
            }
        }
    }
    
    # --- [KROK 5: Opcjonalny Zapis do HTML] ---
    $saveChoice = ''; if ([string]::IsNullOrWhiteSpace($OutputPath)) { $saveChoice = Read-Host "`nCzy chcesz zapisać ten raport do interaktywnego pliku HTML? [T/N]" }
    if ($saveChoice.ToUpper() -eq 'T' -or -not [string]::IsNullOrWhiteSpace($OutputPath)) {
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
             $defaultFileName = "Raport_Nadmiarowych_Uprawnien_$(Get-Date -Format 'yyyyMMdd_HHmm').html"
             $OutputPath = Join-Path -Path $env:USERPROFILE -ChildPath "Desktop\$defaultFileName"
             Write-Host "[INFO] Plik zostanie zapisany na pulpicie: $OutputPath" -ForegroundColor DarkGray
        }
        Write-Host "[INFO] Generowanie raportu HTML..." -ForegroundColor Cyan
        $jsonData = $groupedFindings | ConvertTo-Json -Depth 5 -Compress
        $escapedJsBlock = @'
<script>
    const reportData=JSON.parse(document.getElementById("jsonData").textContent);function renderReport(e){const t=document.getElementById("report-content");if(t.innerHTML="",!e||0===e.length)return void(t.innerHTML="<p>Brak wyników do wyświetlenia.</p>");e.forEach(e=>{const a=document.createElement("details"),n=document.createElement("summary");n.innerHTML=`<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"></path></svg> <span>${e.Name}</span>`;const d=document.createElement("div");d.className="details-content";const r=e.Group.reduce(((e,t)=>(e[t.User]=e[t.User]||[],e[t.User].push(t),e)),{});for(const o in r){const s=r[o],l=document.createElement("div");l.className="user-block";const c=document.createElement("div");c.className="user-header",c.innerHTML=`<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"></path><circle cx="12" cy="7" r="4"></circle></svg> Użytkownik: <span class="user-name">${o}</span><div class="rights-chip">Prawa bezpośrednie: <span class="user-rights">${s[0].UserRights}</span></div>`,l.appendChild(c),s.forEach(e=>{const t=document.createElement("div");t.className="group-info";const a=e.UserRights===e.GroupRights,n=a?"status-identical":"status-different",d=a?"(IDENTYCZNE)":"(RÓŻNE)",r=a?'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon icon-gleich"><path d="M5 12h14"></path><path d="M5 7h14"></path><path d="M5 17h14"></path></svg>':'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon icon-ungleich"><path d="M5 12h14"></path><path d="M5 7h14"></path><path d="m16 17-7-5 7-5"></path></svg>';t.innerHTML=`<div class="group-line"><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="icon"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path><circle cx="9" cy="7" r="4"></circle><path d="M23 21v-2a4 4 0 0 0-3-3.87"></path><path d="M16 3.13a4 4 0 0 1 0 7.75"></path></svg> Jest w grupie: <span class="group-name">${e.RedundantViaGroup}</span><div class="rights-chip">Prawa grupy: <span class="group-rights">${e.GroupRights}</span></div><div class="rights-status ${n}">${r} ${d}</div></div>`,l.appendChild(t)}),d.appendChild(l)}a.appendChild(n),a.appendChild(d),t.appendChild(a)})}document.getElementById("search-box").addEventListener("input",e=>{const t=e.target.value.toLowerCase();if(!t)return void renderReport(reportData);const a=reportData.filter(e=>{if(e.Name.toLowerCase().includes(t))return!0;return e.Group.some(e=>e.User.toLowerCase().includes(t)||e.RedundantViaGroup.toLowerCase().includes(t))});renderReport(a)}),renderReport(reportData);
</script>
'@
        $htmlTemplate = @"
<!DOCTYPE html>
<html lang="pl">
<head>
    <meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Raport Nadmiarowych Uprawnień</title>
    <style>
        body {{ font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; background-color: #f0f2f5; color: #1c1e21; margin: 0; padding: 20px; }}
        .container {{ max-width: 1400px; margin: auto; background: #fff; padding: 20px 40px; border-radius: 12px; box-shadow: 0 6px 18px rgba(0,0,0,0.07); }}
        h1 {{ color: #1877f2; text-align: center; border-bottom: none; padding-bottom: 20px; font-weight: 700; }}
        .summary {{ background-color: #e7f3ff; border: 1px solid #cce0ff; padding: 20px; border-radius: 8px; margin-bottom: 25px; display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 15px; }}
        .summary p {{ margin: 0; font-size: 1.1em; }} .summary strong {{ color: #1877f2; }}
        #search-box {{ width: 100%; padding: 12px 15px; margin-bottom: 25px; border-radius: 6px; border: 1px solid #dddfe2; box-sizing: border-box; font-size: 1em; transition: all 0.2s ease-in-out; }}
        #search-box:focus {{ border-color: #1877f2; box-shadow: 0 0 0 3px rgba(24, 119, 242, 0.2); }}
        details {{ border: 1px solid #e0e0e0; border-radius: 8px; margin-bottom: 12px; transition: all 0.2s ease-in-out; overflow: hidden; }}
        details[open] {{ border-color: #1877f2; box-shadow: 0 4px 12px rgba(0,0,0,0.08); }}
        summary {{ font-weight: 600; cursor: pointer; padding: 15px 20px; background-color: #f5f6f7; display: flex; align-items: center; gap: 10px; font-size: 1.2em; }}
        .icon {{ width: 20px; height: 20px; stroke: #606770; }} summary .icon {{ transition: transform 0.2s ease-in-out; }} details[open] > summary .icon {{ transform: rotate(90deg); }}
        .details-content {{ padding: 20px; background-color: #fff; }}
        .user-block {{ margin-bottom: 20px; padding: 15px; border-radius: 6px; border: 1px solid #e9eaed; background-color: #fafafa; }}
        .user-header {{ font-size: 1.1em; display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }}
        .user-name {{ font-weight: 700; color: #d63384; }}
        .rights-chip {{ background-color: #e7f3ff; color: #1877f2; padding: 5px 10px; border-radius: 15px; font-size: 0.9em; font-weight: 500; }}
        .group-info {{ padding-left: 25px; margin-top: 10px; }}
        .group-line {{ display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }}
        .group-name {{ font-weight: 700; color: #0d6efd; }}
        .rights-status {{ font-weight: 700; display: inline-flex; align-items: center; gap: 5px; }}
        .status-identical {{ color: #198754; }} .status-identical .icon {{ stroke: #198754; }}
        .status-different {{ color: #dc3545; }} .status-different .icon {{ stroke: #dc3545; }}
        .footer {{ text-align: center; margin-top: 40px; font-size: 0.9em; color: #65676b; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>Raport Nadmiarowych Uprawnień</h1>
        <div class="summary">
            <p><strong>Skanowana ścieżka:</strong> {0}</p>
            <p><strong>Data wygenerowania:</strong> {1}</p>
            <p><strong>Znaleziono folderów z problemami:</strong> {2}</p>
        </div>
        <input type="text" id="search-box" placeholder="Filtruj wg folderu, użytkownika lub grupy...">
        <div id="report-content"></div>
    </div>
    <script id="jsonData" type="application/json">{3}</script>
    {4}
    <div class="footer">Raport wygenerowany przez skrypt PowerShell by SysTech & Gemini</div>
</body>
</html>
"@
        $htmlContent = $htmlTemplate -f $RootPath, (Get-Date), $groupedFindings.Count, $jsonData, $escapedJsBlock

        try {
            $htmlContent | Out-File -FilePath $OutputPath -Encoding UTF8
            Write-Host "[SUKCES] Raport HTML został pomyślnie zapisany do: $OutputPath" -ForegroundColor Green
            try { Invoke-Item $OutputPath } catch { Write-Warning "Nie udało się automatycznie otworzyć raportu. Znajdziesz go pod ścieżką: $OutputPath" }
        } catch { Write-Error "[BŁĄD] Nie udało się zapisać pliku HTML. Szczegóły: $($_.Exception.Message)" }
    }

    # --- [KROK 6: Interaktywne Usuwanie Nadmiarowych Uprawnień] ---
    $removableFindings = $redundantFindings | Where-Object { $_.UserRights -eq $_.GroupRights }
    if ($removableFindings.Count -gt 0) {
        Write-Host "`n`n--- [AKCJA] Czyszczenie Nadmiarowych Uprawnień ---" -ForegroundColor Cyan
        Write-Host "Znaleziono $($removableFindings.Count) przypadków, gdzie uprawnienia użytkownika i grupy są IDENTYCZNE." -ForegroundColor Yellow
        
        $firstConfirm = Read-Host "Czy zapoznałeś się z wynikami (np. w raporcie HTML) i chcesz kontynuować? [T/N]"
        if ($firstConfirm.ToUpper() -eq 'T') {
            $secondConfirm = Read-Host "JESTEŚ PEWIEN, że chcesz usunąć $($removableFindings.Count) nadmiarowych wpisów ACL? Ta operacja jest nieodwracalna. [TAK/NIE]"
            if ($secondConfirm -eq 'TAK') {
                Write-Host "[INFO] Rozpoczynanie usuwania nadmiarowych uprawnień..." -ForegroundColor Yellow
                foreach ($finding in $removableFindings) {
                    $userSid = $nameToSidMap[$finding.User]
                    if (-not $userSid) { Write-Warning "Nie udało się znaleźć SID dla '$($finding.User)'. Pomijam."; continue }

                    if ($PSCmdlet.ShouldProcess($finding.Path, "Usunięcie uprawnień dla '$($finding.User)' (ponieważ są identyczne jak w grupie '$($finding.RedundantViaGroup)')")) {
                        try {
                            $acl = Get-Acl -Path $finding.Path -ErrorAction Stop
                            # Znajdź wszystkie JAWNE wpisy dla tego użytkownika
                            $acesToRemove = $acl.Access | Where-Object { (-not $_.IsInherited) -and ($_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $userSid) }
                            if ($acesToRemove.Count -gt 0) {
                                foreach($ace in $acesToRemove) {
                                    $acl.RemoveAccessRule($ace) | Out-Null
                                }
                                Set-Acl -Path $finding.Path -AclObject $acl -ErrorAction Stop
                                Write-Host "[SUKCES] Usunięto nadmiarowe uprawnienia dla '$($finding.User)' z folderu: $($finding.Path)" -ForegroundColor Green
                            } else {
                                Write-Warning "[INFO] Nie znaleziono jawnego wpisu ACL dla '$($finding.User)' w folderze '$($finding.Path)' do usunięcia."
                            }
                        } catch {
                             Write-Error "[BŁĄD] Nie udało się usunąć uprawnień dla '$($finding.User)' z folderu '$($finding.Path)'. Szczegóły: $($_.Exception.Message)"
                        }
                    } else { Write-Warning "[POMINIĘTO] Usunięcie uprawnień dla '$($finding.User)' w '$($finding.Path)' (WhatIf)." }
                }
            } else { Write-Host "[INFO] Operacja usuwania anulowana. Nic nie zostało zmienione." -ForegroundColor Yellow }
        } else { Write-Host "[INFO] Operacja usuwania anulowana. Nic nie zostało zmienione." -ForegroundColor Yellow }
    }
}

# --- [KROK 7: Zakończenie] ---
Write-Host "`n--- Skrypt audytu uprawnień zakończył pracę ---" -ForegroundColor Green
