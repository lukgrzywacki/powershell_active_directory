# Skrypt PowerShell usuwający użytkowników z wyłączonymi kontami z grup zabezpieczeń AD (zoptymalizowany z paskiem postępu)

# Zaimportuj moduł Active Directory
Import-Module ActiveDirectory

# Pobierz wszystkie wyłączone konta użytkowników tylko raz
Write-Host "Pobieram listę wyłączonych kont użytkowników..." -ForegroundColor Cyan
$disabledUsers = Get-ADUser -Filter 'Enabled -eq $false' | Select-Object -ExpandProperty SamAccountName

# Pobierz wszystkie grupy zabezpieczeń
Write-Host "Pobieram listę grup zabezpieczeń..." -ForegroundColor Cyan
$groups = Get-ADGroup -Filter 'GroupCategory -eq "Security"'

# Utwórz listę użytkowników z wyłączonymi kontami w grupach
$disabledUsersInGroups = @()

$totalGroups = $groups.Count
$currentGroup = 0

foreach ($group in $groups) {
    $currentGroup++
    Write-Progress -Activity "Skanowanie grup..." -Status "Przetwarzanie grupy: $($group.Name) ($currentGroup z $totalGroups)" -PercentComplete (($currentGroup / $totalGroups) * 100)

    # Pobierz członków grupy (tylko użytkowników)
    $groupMembers = Get-ADGroupMember -Identity $group -Recursive | Where-Object { $_.ObjectClass -eq 'user' }

    foreach ($member in $groupMembers) {
        if ($disabledUsers -contains $member.SamAccountName) {
            $disabledUsersInGroups += [PSCustomObject]@{
                UserName = $member.SamAccountName
                GroupName = $group.Name
            }
        }
    }
}

if ($disabledUsersInGroups.Count -eq 0) {
    Write-Host "Brak użytkowników z wyłączonymi kontami w grupach." -ForegroundColor Cyan
} else {
    Write-Host "Użytkownicy z wyłączonymi kontami znalezieni w grupach:" -ForegroundColor Yellow
    $disabledUsersInGroups | Format-Table -AutoSize

    $confirmation = Read-Host "Czy na pewno chcesz usunąć tych użytkowników z grup? (T/N)"

    if ($confirmation -eq 'T') {
        foreach ($entry in $disabledUsersInGroups) {
            Remove-ADGroupMember -Identity $entry.GroupName -Members $entry.UserName -Confirm:$false
            Write-Host "Usunięto użytkownika $($entry.UserName) z grupy $($entry.GroupName)" -ForegroundColor Green
        }
        Write-Host "Zakończono czyszczenie grup z wyłączonych kont." -ForegroundColor Cyan
    } else {
        Write-Host "Operacja anulowana przez użytkownika." -ForegroundColor Red
    }
}