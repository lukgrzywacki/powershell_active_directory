<#
.SYNOPSIS
    Wyszukuje i raportuje historię logowań użytkownika domenowego z dzienników zdarzeń kontrolera domeny.
.DESCRIPTION
    Skrypt interaktywnie lub za pomocą parametrów pozwala na szczegółowe przeszukanie dziennika zdarzeń 'Security'
    na lokalnym komputerze (docelowo na kontrolerze domeny) w poszukiwaniu udanych logowań (Event ID 4624)
    dla określonego użytkownika.

    Kluczowe funkcje:
    - Możliwość zdefiniowania okresu wyszukiwania w dniach, godzinach lub minutach.
    - Szczegółowy pasek postępu, który pokazuje postęp analizy krok po kroku (dzień po dniu, godzina po godzinie itd.),
      co jest przydatne przy długich operacjach.
    - Po zakończeniu skanowania, skrypt zbiera wszystkie znalezione zdarzenia.
    - Użytkownik ma możliwość wyboru, czy chce zobaczyć pełne, "surowe" wyniki (wliczając duplikaty
      i zdarzenia bez nazwy komputera), czy przefiltrowane, "czyste" wyniki, które pokazują tylko
      unikalne logowania do konkretnych maszyn.
.PARAMETER UserName
    Opcjonalny. Nazwa (login) użytkownika Active Directory, którego logowania mają być sprawdzone.
    Jeśli nie zostanie podany, skrypt zapyta o niego interaktywnie.
.PARAMETER SearchMode
    Opcjonalny. Określa jednostkę czasu dla wyszukiwania. Dopuszczalne wartości: 'Days', 'Hours', 'Minutes'.
    Jeśli nie zostanie podany, skrypt zapyta o niego interaktywnie.
.PARAMETER TimeValue
    Opcjonalny. Liczba dni, godzin lub minut (zależnie od wybranego SearchMode), z których mają być
    analizowane logi. Jeśli nie zostanie podany, skrypt zapyta o tę wartość.
.EXAMPLE
    .\Get-ADUserLogonHistory.ps1
    Uruchamia skrypt w pełni interaktywnym trybie. Skrypt poprosi o nazwę użytkownika, tryb wyszukiwania
    i wartość czasu.

.EXAMPLE
    .\Get-ADUserLogonHistory.ps1 -UserName "jkowalski" -SearchMode Days -TimeValue 7
    Wyszukuje logowania użytkownika "jkowalski" z ostatnich 7 dni.

.EXAMPLE
    .\Get-ADUserLogonHistory.ps1 -UserName "anowak" -SearchMode Hours -TimeValue 24
    Wyszukuje logowania użytkownika "anowak" z ostatnich 24 godzin.
.NOTES
    Wersja: 1.0 (Data modyfikacji: 09.07.2025)
    Autor: Łukasz Grzywacki (SysTech Łukasz Grzywacki)

    Wymagania:
    - Skrypt powinien być uruchamiany na kontrolerze domeny lub maszynie z dostępem do jego dzienników zdarzeń.
    - Wymagane są uprawnienia administratora do odczytu dziennika zdarzeń 'Security'.
    - Skuteczność skryptu zależy od włączonych zasad inspekcji logowania (Audit Logon Events) w domenie
      oraz od rozmiaru i retencji dziennika 'Security'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$UserName,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Days', 'Hours', 'Minutes')]
    [string]$SearchMode,

    [Parameter(Mandatory = $false)]
    [int]$TimeValue
)

# --- [KROK 1: Pobieranie i Walidacja Danych Wejściowych] ---

if ([string]::IsNullOrWhiteSpace($UserName)) {
    $UserName = Read-Host -Prompt "[WEJŚCIE] Krok 1/3: Wpisz nazwę użytkownika (login), którego chcesz sprawdzić"
    if ([string]::IsNullOrWhiteSpace($UserName)) { Write-Error "[BŁĄD KRYTYCZNY] Nazwa użytkownika jest wymagana."; return }
}

if ([string]::IsNullOrWhiteSpace($SearchMode)) {
    Write-Host "`n[WEJŚCIE] Krok 2/3: Wybierz, jak szczegółowo chcesz przeszukać dziennik:"
    Write-Host "1. Według Dni (wolniej, dla długich okresów)"
    Write-Host "2. Według Godzin (bardzo wolno)"
    Write-Host "3. Według Minut (ekstremalnie wolno, dla krótkich okresów)"
    $choice = Read-Host "Wybierz opcję [1, 2, lub 3]"
    switch ($choice) {
        '1' { $SearchMode = "Days" }
        '2' { $SearchMode = "Hours" }
        '3' { $SearchMode = "Minutes" }
        default { Write-Error "[BŁĄD KRYTYCZNY] Nieprawidłowy wybór."; return }
    }
}

# Definicje na podstawie trybu wyszukiwania
$timeUnitLabel, $timeUnitLabelPlural, $inputPrompt = "", "", ""
switch ($SearchMode) {
    'Days'    { $timeUnitLabel = "dniu"; $timeUnitLabelPlural = "dni"; $inputPrompt = "Podaj, z ilu ostatnich dni chcesz zobaczyć logowania" }
    'Hours'   { $timeUnitLabel = "godzinie"; $timeUnitLabelPlural = "godzin"; $inputPrompt = "Podaj, z ilu ostatnich godzin chcesz zobaczyć logowania" }
    'Minutes' { $timeUnitLabel = "minucie"; $timeUnitLabelPlural = "minut"; $inputPrompt = "Podaj, z ilu ostatnich minut chcesz zobaczyć logowania" }
}

if (-not $TimeValue -or $TimeValue -le 0) {
    $iterationsInput = Read-Host "`n[WEJŚCIE] Krok 3/3: $inputPrompt"
    if ($iterationsInput -notmatch '^\d+' -or [int]$iterationsInput -le 0) {
        Write-Error "[BŁĄD KRYTYCZNY] Wprowadzono nieprawidłową wartość. Proszę podać dodatnią liczbę."
        return
    }
    $TimeValue = [int]$iterationsInput
}


# --- [KROK 2: Szczegółowe Przeszukiwanie Dziennika Zdarzeń] ---

$foundEvents = [System.Collections.Generic.List[psobject]]::new()
Write-Host "`n[INFO] Rozpoczynam szczegółowe przeszukiwanie z ostatnich $TimeValue $($timeUnitLabelPlural)..." -ForegroundColor Green

# Główna pętla iterująca krok po kroku, aby zapewnić płynny pasek postępu
for ($i = 0; $i -lt $TimeValue; $i++) {
    $currentIterationNumber = $i + 1
    Write-Progress -Activity "Przeszukuję dziennik zdarzeń" -Status "Analizuję $($timeUnitLabel) $currentIterationNumber z $TimeValue" -PercentComplete (($currentIterationNumber / $TimeValue) * 100)

    # Dynamiczne ustalanie okna czasowego na podstawie wybranego trybu
    $startDate, $endDate = switch ($SearchMode) {
        "Days"    { (Get-Date).Date.AddDays(-$i).AddDays(-1); (Get-Date).Date.AddDays(-$i) }
        "Hours"   { (Get-Date).AddHours(-$i).AddHours(-1); (Get-Date).AddHours(-$i) }
        "Minutes" { (Get-Date).AddMinutes(-$i).AddMinutes(-1); (Get-Date).AddMinutes(-$i) }
    }

    # Filtr dla Get-WinEvent
    $filter = @{
        LogName   = 'Security'
        ID        = 4624
        StartTime = $startDate
        EndTime   = $endDate
    }

    # Pobieranie zdarzeń z bieżącego, małego okna czasowego
    $eventsInPeriod = Get-WinEvent -FilterHashtable $filter -ErrorAction SilentlyContinue
    foreach ($event in $eventsInPeriod) {
        try {
            $eventXml = [xml]$event.ToXml()
            $eventUser = $eventXml.Event.EventData.Data | Where-Object { $_.Name -eq 'TargetUserName' }

            if ($eventUser.InnerText -eq $UserName) {
                $workstation = $eventXml.Event.EventData.Data | Where-Object { $_.Name -eq 'WorkstationName' }
                # Zbieranie wyników, zachowując datę jako obiekt [datetime] dla poprawnego sortowania
                $foundEvents.Add([PSCustomObject]@{
                    Data       = $event.TimeCreated
                    Uzytkownik = $eventUser.InnerText
                    Komputer   = $workstation.InnerText
                })
            }
        }
        catch {
            # Ignoruj błędy parsowania pojedynczych, uszkodzonych zdarzeń
        }
    }
}
Write-Progress -Activity "Przeszukuję dziennik zdarzeń" -Completed


# --- [KROK 3: Wyświetlanie Wyników z Możliwością Wyboru Trybu] ---

if ($foundEvents.Count -eq 0) {
    Write-Host "`n[INFO] Nie znaleziono absolutnie żadnych zdarzeń logowania dla użytkownika '$UserName' w podanym okresie." -ForegroundColor Yellow
    return
}

Write-Host "`n[INFO] Znaleziono łącznie $($foundEvents.Count) zdarzeń (wliczając duplikaty i wpisy bez nazwy komputera)." -ForegroundColor Cyan
$showClean = Read-Host -Prompt "Czy chcesz wyświetlić tylko 'czyste' wyniki (unikalne logowania do konkretnych komputerów)? [t/n]"

if ($showClean -eq 't') {
    # Tryb "czysty": filtrowanie i usuwanie duplikatów
    Write-Host "[INFO] Wybrano tryb 'czysty'. Trwa filtrowanie..." -ForegroundColor Green
    
    # Krok 1: Filtrowanie, aby pokazać tylko wpisy z nazwą komputera
    $filteredEvents = $foundEvents | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Komputer) -and $_.Komputer.Trim() -ne '-' }
    
    # Krok 2: Użycie Sort-Object -Unique do usunięcia duplikatów (do poziomu sekundy)
    # Tworzymy unikalny klucz na podstawie sformatowanej daty, użytkownika i komputera.
    $uniqueEvents = $filteredEvents | Sort-Object -Property @{E={$_.Data.ToString("yyyyMMddHHmmss")}}, Uzytkownik, Komputer -Unique

    if ($uniqueEvents.Count -gt 0) {
        Write-Host "`n--- Wyniki (przefiltrowane i unikalne) ---" -ForegroundColor Yellow
        # Sortowanie po prawdziwej dacie (malejąco) i wyświetlenie
        $uniqueEvents | Sort-Object Data -Descending | Format-Table -AutoSize
    } else {
        Write-Host "`n[INFO] Po odfiltrowaniu nie zostało żadnych logowań do konkretnych komputerów." -ForegroundColor Yellow
    }
}
else {
    # Tryb "surowy": pokazanie wszystkiego, co znaleziono
    Write-Host "[INFO] Wybrano tryb 'surowy'. Wyświetlam wszystkie znalezione zdarzenia..." -ForegroundColor Green
    Write-Host "`n--- Wyniki (surowe dane) ---" -ForegroundColor Yellow
    $foundEvents | Sort-Object Data -Descending | Format-Table -AutoSize
}

Write-Host "`n--- Skrypt zakończył działanie ---" -ForegroundColor Green
