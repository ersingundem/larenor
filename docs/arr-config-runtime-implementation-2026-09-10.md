# S06.5 — Sonarr/Radarr installation runtime bağı

Bu dilim, Sonarr/Radarr yapılandırma etkisini Larenor installation worker'ın
aynı volume journal'ına ve retained Docker daemon supervisor'ına bağlar. Runtime
yalnız doğrulanmış stack, kapalı servis kimliği ve private API key kabul eder;
host yolu veya Docker işlemi sunmaz.

## Worker içinde yeniden bağlama

- Runtime packaged katalog ve worker policy ile volume planını yeniden üretir.
  Seçilen servis için tam bir `managed_appdata` `/config` kaynağı bulunmalıdır.
- Güncel receipt revision'ı worker-owned `VolumeCreateJournal` içinden okunur ve
  intent aynı plan/stack/catalog/policy ile yeniden bağlanır. Stale veya eksik
  kayıt helper etkisine ulaşamaz.
- API key exact 32 küçük harfli hex olmak zorundadır. Sonarr ve Radarr dışındaki
  servis kimlikleri, iptal edilmiş işler ve caller kontrollü yol/volume/image/
  endpoint alanları reddedilir.
- Internal backend 32 hex iş kimliğini doğrular. Config effect'in Docker
  transport ve stdin bağlantıları, diğer kurulum etkileriyle aynı peer verifier
  üzerinden aynı retained daemon ve native thread üzerinde çalışır.
- Supervisor etki öncesinde, iki iç gate çağrısında ve sonuçtan sonra daemon,
  socket, namespace ve worker kimliği kanıtlarını yeniden denetler. Bilinmeyen
  effect veya sonuç sapması secret-free ve belirsiz etki olarak kapanır.

## Kanıt ve açık iş

- Exact kaynak `228687da05050d4266d5e094bd61820939979edc`.
- **19 yeni test**; runtime, effect, binding, helper, owned config,
  installation runtime ve supervisor paketlerinde **251 PASS / 1 mevcut macOS
  skip**.
- Her iki servis, stale journal, kapalı girdi/imza, unpinned helper/platform,
  çapraz servis makbuzu, bilinmeyen hata, iş kimliği ve aynı peer verifier/native
  thread zinciri doğrulandı.
- `compileall`, güvenlik politikası, kuyruk, diff ve Gitleaks PASS.

Bu runtime henüz kalıcı Core işi veya IPC operasyonu sunmaz ve gerçek servis
container'ını oluşturmaz. Sıradaki adım private API key'i şifreli, no-retry bir
Core işine bağlamak; ardından config başarısından sonra Sonarr/Radarr
create/start ve authenticated status readback zincirini kurmaktır. İki mimarili
native kabul tamamlanana kadar S06.5 ve `installAvailable=false` açık kalır.
