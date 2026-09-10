# Seerr bootstrap executor ve private worker kanıtı

Tarih: 10 Eylül 2026  
Kapsam: S06.5 içinde Seerr'ın yönetilen konteynerden ilk yönetici sonucuna
kadar worker tarafında yürütülmesi

## Teslim edilen davranış

- Core'un sabitlediği medya planından hem Seerr hem Jellyfin binding'i yeniden
  üretilir; çağrıdan adres, port, Docker seçeneği veya servis adı alınmaz.
- Seerr için tamamlanmış `start_container` journal makbuzu uzlaştırılır.
- Seerr TCP/5055 ve Jellyfin TCP/8096 uçları taze konteyner okumalarından
  kanıtlanır. İki servis aynı yönetilen ağ kimliğinde değilse bağlantı açılmaz.
- Seerr bağlantısı açıldıktan sonra her iki konteyner yeniden okunur. Drift,
  Jellyfin parolası gönderilmeden önce işlemi kapatır.
- Yalnız doğrulanmış Jellyfin private readback'i bulunan `larenor-system`
  hesabı ilk Seerr yöneticisi olarak kullanılabilir.
- İşlem sonrasında Seerr ve Jellyfin kanıtları ile retained daemon yetkisi
  tekrar kontrol edilir. Bu aşamadaki kayıp `uncertain_effect=true` olarak
  raporlanır.
- Worker isteği yalnız Jellyfin parolası ile doğrulanmış kaynak bootstrap
  kimliği/revizyonunu taşır; Jellyfin API anahtarı ve kütüphane verisi gönderilmez.
- Seerr API anahtarı yalnız UID korumalı yerel installation Unix socket sonucunda
  taşınır. Public sonuç, hata ve `repr` yüzeyleri parola ve anahtarı içermez.
- Worker capability listesi Seerr'ı ilan eder; gerçek runtime aynı resource,
  volume, container journal'larını ve aynı retained Docker daemon lease'ini
  kullanır.

## TDD ve doğrulama

- RED `d53c42e`: executor sözleşmesi eksik modülle kırmızı.
- GREEN `387ed9d`: iki yönetilen servis kanıtı ve ilk yönetici yürütücüsü.
- RED `a560c62`: private worker IPC operasyonu ve capability sözleşmesi eksik.
- GREEN `9ab1d7e`: client/server IPC, runtime ve supervisor bağlantısı.
- RED `341a983` → GREEN `8dd35a7`: yalnız gereken sırları taşıyan Seerr private modeli.
- 12 executor, 7 IPC ve 6 private-model testi geçti.
- Seerr, mevcut Jellyfin/qBittorrent/Arr IPC, runtime ve supervisor paketi:
  160 PASS / 1 mevcut macOS skip.
- Exact `8dd35a7` üzerinde tam Server paketi 5.243 testte geçti.
- Ruff, `compileall`, security policy, `git diff --check` ve Gitleaks geçti.

## Açık sınırlar

Bu dilim Seerr'ı henüz kurulabilir ilan etmez. Core tarafında şifreli kalıcı
Seerr iş kaydı ve public admin durum modeli, Sonarr/Radarr ile Jellyfin
kütüphane eşleştirmesi, `/settings/initialize` geri okuması ve gerçek
amd64/arm64 Seerr fixture kabulü tamamlanmalıdır. `installAvailable=false`
korunur.
