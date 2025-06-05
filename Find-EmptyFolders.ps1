<#
.SYNOPSIS
    Wyszukuje, listuje i opcjonalnie usuwa "najwyższego poziomu" puste foldery w podanej ścieżce lub ścieżkach.
.DESCRIPTION
    Skrypt rekursywnie przeszukuje podane ścieżki (lokalne lub UNC). Folder jest uznawany za "efektywnie pusty",
    jeśli nie zawiera żadnych plików bezpośrednio, a wszystkie jego podfoldery są również "efektywnie puste".
    Skrypt listuje tylko te "efektywnie puste" foldery, które nie są podfolderami innych znalezionych
    "efektywnie pustych" folderów. Wyniki są wyświetlane w konsoli z numeracją.
    Po wylistowaniu, użytkownik ma opcję wyboru folderów do usunięcia. Każda operacja usunięcia
    wymaga indywidualnego potwierdzenia.
.PARAMETER Path
    OBOWIĄZKOWY. Jedna lub więcej ścieżek do folderów głównych, które mają być przeszukane.
    Jeśli podajesz więcej niż jedną ścieżkę, oddziel je przecinkami.
    Przykład: -Path "C:\Temp\ProjektA", "\\SERVER01\Share\Archiwum"
.EXAMPLE
    .\Find-EmptyFolders.ps1 -Path "C:\Users\TwojaNazwa\Documents"
    Przeszukuje folder "Dokumenty" i jego podfoldery, listuje "najwyższego poziomu" puste foldery,
    a następnie pyta o ich ewentualne usunięcie.

.EXAMPLE
    .\Find-EmptyFolders.ps1 -Path "\\SERWER\UdziałPubliczny\Projekty2020", "D:\StareDane"
    Przeszukuje dwie podane lokalizacje i oferuje opcję usunięcia znalezionych pustych folderów.
.NOTES
    Wersja: 1.2
    Autor: Łukasz Grzywacki (SysTech Łukasz Grzywacki) przy pomocy Asystenta AI

    - Skrypt wymaga uprawnień do odczytu dla wszystkich przeszukiwanych lokalizacji.
    - Do usunięcia folderów wymagane są uprawnienia do zapisu/modyfikacji w tych lokalizacjach.
    - OPERACJA USUWANIA JEST NIEODWRACALNA! Należy zachować szczególną ostrożność.
    - Skanowanie bardzo dużych i głębokich struktur folderów może być czasochłonne.
#>
[CmdletBinding(SupportsShouldProcess = $true)] # Dodano SupportsShouldProcess dla Remove-Item
param(
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true,
               HelpMessage = "Podaj jedną lub więcej ścieżek do folderów do przeskanowania, oddzielonych przecinkami.")]
    [string[]]$Path
)

# --- [FUNKCJA POMOCNICZA DO REKURSYWNEGO SPRAWDZANIA PUSTYCH FOLDERÓW] ---
function Test-FolderEffectivelyEmpty {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FolderToCheck,
        [Parameter(Mandatory = $true)]
        [System.Collections.Hashtable]$Cache 
    )

    if ($Cache.ContainsKey($FolderToCheck)) {
        return $Cache[$FolderToCheck]
    }

    if (-not (Test-Path -Path $FolderToCheck -PathType Container -ErrorAction SilentlyContinue)) {
        $Cache[$FolderToCheck] = $false 
        return $false
    }
    
    if ((Get-ChildItem -Path $FolderToCheck -File -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        $Cache[$FolderToCheck] = $false 
        return $false
    }

    $SubFolders = Get-ChildItem -Path $FolderToCheck -Directory -Force -ErrorAction SilentlyContinue
    if ($SubFolders.Count -eq 0) {
        $Cache[$FolderToCheck] = $true 
        return $true
    }

    foreach ($SubFolder in $SubFolders) {
        if (-not (Test-FolderEffectivelyEmpty -FolderToCheck $SubFolder.FullName -Cache $Cache)) {
            $Cache[$FolderToCheck] = $false 
            return $false
        }
    }

    $Cache[$FolderToCheck] = $true
    return $true
}


# --- [POCZĄTEK SKRYPTU] ---
Write-Host "--- Rozpoczynanie skryptu wyszukiwania 'efektywnie pustych' folderów ---" -ForegroundColor Green

$AllEffectivelyEmptyFolders = [System.Collections.Generic.List[string]]::new()
$TotalFoldersProcessedForEmptinessCheck = 0 
$FolderCache = [System.Collections.Hashtable]::new() 

foreach ($BasePath in $Path) {
    $BasePath = $BasePath.Trim()
    Write-Host "`n[INFO] Przetwarzanie ścieżki głównej: $BasePath" -ForegroundColor Cyan
    if (-not (Test-Path -Path $BasePath -PathType Container)) {
        Write-Warning "[OSTRZEŻENIE] Ścieżka '$BasePath' nie istnieje lub nie jest folderem. Pomijam."
        continue
    }

    try {
        $FoldersToCheckInThisBasePath = @($BasePath) 
        $SubFoldersUnderBasePath = Get-ChildItem -Path $BasePath -Recurse -Directory -Force -ErrorAction SilentlyContinue
        if ($SubFoldersUnderBasePath) {
            $FoldersToCheckInThisBasePath += ($SubFoldersUnderBasePath.FullName | Where-Object {$_ -ne $null})
        }
        $FoldersToCheckInThisBasePath = $FoldersToCheckInThisBasePath | Sort-Object -Unique 

        Write-Host "[INFO] Znaleziono $($FoldersToCheckInThisBasePath.Count) unikalnych folderów do analizy w obrębie '$BasePath'."
        
        foreach ($FolderFullPath in $FoldersToCheckInThisBasePath) {
            $TotalFoldersProcessedForEmptinessCheck++
            Write-Progress -Activity "Analiza folderów" -Status "Sprawdzanie efektywnej pustki: $FolderFullPath" -PercentComplete (($TotalFoldersProcessedForEmptinessCheck % 300) * 0.33)

            if (Test-FolderEffectivelyEmpty -FolderToCheck $FolderFullPath -Cache $FolderCache) {
                if (-not $AllEffectivelyEmptyFolders.Contains($FolderFullPath)) {
                    $AllEffectivelyEmptyFolders.Add($FolderFullPath)
                }
            }
        }
    }
    catch {
        Write-Warning "[OSTRZEŻENIE] Wystąpił błąd podczas przetwarzania ścieżki '$BasePath': $($_.Exception.Message)"
    }
}

Write-Progress -Activity "Analiza folderów" -Completed

# --- [PODSUMOWANIE I FILTROWANIE] ---
Write-Host "`n--- Podsumowanie Skanowania ---" -ForegroundColor Green
Write-Host "[INFO] Przeanalizowano pod kątem 'efektywnej pustki': $TotalFoldersProcessedForEmptinessCheck folderów."

$FinalDisplayFolders = [System.Collections.Generic.List[string]]::new()

if ($AllEffectivelyEmptyFolders.Count -gt 0) {
    Write-Host "[INFO] Znaleziono łącznie 'efektywnie pustych' folderów (w tym zagnieżdżonych): $($AllEffectivelyEmptyFolders.Count)" -ForegroundColor Yellow
    
    $AllEffectivelyEmptyFoldersSorted = $AllEffectivelyEmptyFolders | Sort-Object 

    foreach ($candidateFolder in $AllEffectivelyEmptyFoldersSorted) {
        $isSubfolderOfAnotherEmptyOneInList = $false
        foreach ($potentialParent in $AllEffectivelyEmptyFoldersSorted) {
            if ($candidateFolder -ne $potentialParent -and $candidateFolder.StartsWith($potentialParent + [System.IO.Path]::DirectorySeparatorChar)) {
                $isSubfolderOfAnotherEmptyOneInList = $true
                break
            }
        }
        if (-not $isSubfolderOfAnotherEmptyOneInList) {
            if (-not $FinalDisplayFolders.Contains($candidateFolder)){ 
                 $FinalDisplayFolders.Add($candidateFolder)
            }
        }
    }
    $EffectivelyEmptyFoldersFoundCount = $FinalDisplayFolders.Count

    if ($EffectivelyEmptyFoldersFoundCount -gt 0) {
        Write-Host "`nLista 'najwyższego poziomu' efektywnie pustych folderów:" -ForegroundColor Yellow
        $SortedFinalList = $FinalDisplayFolders | Sort-Object
        for ($i = 0; $i -lt $SortedFinalList.Count; $i++) {
            Write-Host ("{0,3}. {1}" -f ($i + 1), $SortedFinalList[$i]) -ForegroundColor Magenta
        }
        Write-Host "[INFO] Łącznie znaleziono '$EffectivelyEmptyFoldersFoundCount' takich folderów." -ForegroundColor Yellow

        # --- [OPCJONALNE USUWANIE] ---
        $deleteChoice = Read-Host "`nCzy chcesz spróbować usunąć któreś z powyższych folderów? [T/N]"
        if ($deleteChoice -eq 't' -or $deleteChoice -eq 'T') {
            $numbersToDeleteInput = Read-Host "Podaj numery folderów do usunięcia (oddzielone przecinkami, np. 1,3,5), 'wszystkie' aby usunąć wszystkie wylistowane, lub 'anuluj' aby pominąć:"
            
            if ($numbersToDeleteInput -eq 'anuluj' -or [string]::IsNullOrWhiteSpace($numbersToDeleteInput)) {
                Write-Host "[INFO] Anulowano operację usuwania."
            } else {
                $FoldersToDeletePaths = [System.Collections.Generic.List[string]]::new()
                if ($numbersToDeleteInput -eq 'wszystkie') {
                    $FoldersToDeletePaths.AddRange($SortedFinalList)
                } else {
                    $numberStrings = $numbersToDeleteInput.Split(',') | ForEach-Object {$_.Trim()}
                    foreach ($numStr in $numberStrings) {
                        if ($numStr -match "^\d+$") {
                            $idx = [int]$numStr - 1
                            if ($idx -ge 0 -and $idx -lt $SortedFinalList.Count) {
                                if (-not $FoldersToDeletePaths.Contains($SortedFinalList[$idx])) {
                                    $FoldersToDeletePaths.Add($SortedFinalList[$idx])
                                }
                            } else {
                                Write-Warning "[OSTRZEŻENIE] Numer '$numStr' jest poza zakresem. Pomijam."
                            }
                        } else {
                            Write-Warning "[OSTRZEŻENIE] Wpis '$numStr' nie jest prawidłowym numerem. Pomijam."
                        }
                    }
                }

                if ($FoldersToDeletePaths.Count -gt 0) {
                    Write-Warning "`nZostaną podjęte próby usunięcia następujących folderów:"
                    $FoldersToDeletePaths | ForEach-Object { Write-Warning "- $_" }
                    
                    $confirmGlobalDelete = Read-Host "Czy na pewno chcesz kontynuować z usuwaniem tych $($FoldersToDeletePaths.Count) folderów? [T/N]"
                    if ($confirmGlobalDelete -eq 't' -or $confirmGlobalDelete -eq 'T') {
                        foreach ($folderPathToDelete in $FoldersToDeletePaths) {
                            if ($PSCmdlet.ShouldProcess($folderPathToDelete, "Usunięcie folderu (operacja NIEODWRACALNA!)")) {
                                try {
                                    Remove-Item -Path $folderPathToDelete -Recurse -Force -ErrorAction Stop
                                    Write-Host "[SUKCES] Pomyślnie usunięto folder: $folderPathToDelete" -ForegroundColor Green
                                }
                                catch {
                                    Write-Error "[BŁĄD] Nie udało się usunąć folderu '$folderPathToDelete'. Szczegóły: $($_.Exception.Message)"
                                }
                            } else {
                                Write-Host "[INFO] Pominięto usunięcie folderu '$folderPathToDelete' (WhatIf lub brak potwierdzenia)."
                            }
                        }
                    } else {
                        Write-Host "[INFO] Anulowano operację usuwania."
                    }
                } else {
                    Write-Host "[INFO] Nie wybrano żadnych folderów do usunięcia."
                }
            }
        }

    } else {
        Write-Host "[INFO] Nie zidentyfikowano 'najwyższego poziomu' efektywnie pustych folderów do wyświetlenia." -ForegroundColor Yellow
    }

} else {
    Write-Host "[INFO] Nie znaleziono żadnych 'efektywnie pustych' folderów w podanych ścieżkach." -ForegroundColor Green
}

Write-Host "`n--- Skrypt zakończył działanie ---" -ForegroundColor Green