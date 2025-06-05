# 📂 PowerShell Scripts by SysTech

Zestaw profesjonalnych, modularnych i gotowych do użycia skryptów PowerShell stworzonych przez SysTech do zarządzania środowiskiem Active Directory, GPO oraz uprawnieniami do zasobów sieciowych (NAS, ACL itp.).

Każdy skrypt przestrzega konwencji nazewnictwa `Czynność-Co.ps1`, co ułatwia porządkowanie i zrozumienie ich funkcji.

## 🧰 Zawartość repozytorium

### ✅ `Audit-ADGroupPermissions.ps1`
Przeszukuje wszystkie GPO w domenie AD w celu identyfikacji, gdzie dana grupa jest używana. Uwzględnia m.in. Security Filtering, Restricted Groups, User Rights Assignment oraz Item-Level Targeting w GPP. Wyniki są czytelnie przedstawione i oznaczone, jeśli wymagają weryfikacji.

### ✅ `Export-ADGroupMembers.ps1`
Eksportuje członków wybranej grupy AD do pliku CSV. Obsługuje grupy uniwersalne, globalne i lokalne. Idealny do raportowania i dokumentacji.

### ✅ `Import-ADGroupMembers.ps1`
Importuje użytkowników z pliku CSV do wskazanej grupy AD. Automatycznie pomija duplikaty i błędne wpisy. Obsługuje walidację przed dodaniem.

### ✅ `Copy-NASGroupPermissions.ps1`
Kopiuje uprawnienia ACL z jednej grupy do drugiej na wszystkich folderach w określonej lokalizacji NAS (np. QNAP). Pomocne przy migracjach lub zmianach uprawnień.

### ✅ `Remove-GroupPermissions.ps1`
Usuwa wpisy ACL wskazanej grupy z wszystkich folderów w określonej lokalizacji sieciowej. Działa wyłącznie na folderach. Wymaga odpowiednich uprawnień.

### ✅ `Clean-DisabledUsersFromGroups.ps1`
Identyfikuje i opcjonalnie usuwa użytkowników z wyłączonymi kontami z grup zabezpieczeń AD. Zawiera pasek postępu i mechanizm potwierdzenia usunięcia.

---

## 🛠️ Wymagania

- PowerShell 5.1+ (zalecane: PowerShell 7+)
- Uprawnienia administracyjne (szczególnie dla operacji ACL i AD)
- Moduły:
  - `ActiveDirectory`
  - `GroupPolicy` (dla audytu GPO)

## 📦 Sposób użycia

Każdy skrypt jest interaktywny i prowadzi użytkownika przez potrzebne kroki. Uruchamiaj je bezpośrednio z PowerShell, np.:

```powershell
.\Audit-ADGroupPermissions.ps1 -GroupName "Dzial_IT"
