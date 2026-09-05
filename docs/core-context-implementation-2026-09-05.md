# B3 — Kalıcı Core ve ev kimliği

**5 Eylül 2026 · Kaynak: [merkezi kaynak/olay temeli](feature-expansion-plan-2026-09-05.md).**

Larenor Server artık tek mevcut ev için kalıcı `coreId` ve `homeId` üretir.
Adres değişse veya süreç yeniden başlasa kimlik korunur; bağımsız yeni bir
kurulum yeni kimlik alır. Bu, sonraki merkezi adaptörler, kaynak kimlikleri
ve Client önbellek sınırları için temeldir. Çoklu ev yönetimi, federasyon,
kaynak bazlı yetkilendirme ve Client önbellek geçişi henüz uygulanmadı.

Client'ta aynı sözleşmenin değişmez modeli ve mevcut süre/boyut/iptal sınırları
içinde salt okunur API metodu da eklendi. Bu metot henüz login/refresh akışına
veya cache anahtarlarına bağlanmadı; kayıtlı oturum biçimi değişmedi.

## Uygulanan API

`GET /api/v1/context`, ilk parolasını değiştirmiş ve oturumu hâlâ geçerli
olan `admin` veya `member` kullanıcısına yalnız şu sözleşmeyi döndürür:

```json
{
  "schemaVersion": 1,
  "coreId": "11111111111111111111111111111111",
  "homeId": "22222222222222222222222222222222"
}
```

Yukarıdaki kimlikler örnektir. Gerçek değerler kriptografik rastgele 128 bit
kimliklerdir; sunucu yolu, hostname, token veya parola içermez. Anonim, ilk
parola aşamasındaki, süresi dolmuş veya iptal edilmiş oturumlar reddedilir.
Endpoint salt okunurdur; kullanıcı keyfi ev seçemez veya kimliği değiştiremez.
Şema korumalı OpenAPI belgesinde yer alır.

## Kalıcılık ve sürüm geçişi

[context.py](../server/larenor_server/context.py) mevcut başlangıç kilidi ve
veritabanı işlemi içinde çalışır. Önce mevcut kasa anahtarı `key_check` ile
doğrulanır. Eski şema 1, mevcut şema 2 geçişinden sonra aynı işlem içinde
şema **3** olur. Bu numara ana veritabanı sürümüdür; yanıtın `schemaVersion: 1`
ve Client kasa/yedek belge sürümleri değişmez.

İki kimlik ve bağlam şeması mevcut kasa anahtarıyla HMAC üzerinden bağlanır.
Şema 3'te tablo/satır eksikse, kimlik veya HMAC bozuksa başlangıç sabit
`invalid_core_context` hatasıyla durur; yeni kimlik üreterek kaybı gizlemez.
Şema 2'de beklenmeyen bağlam kalıntısı da reddedilir. Sonraki migration
başarısız olursa kimlik ve sürüm değişikliği birlikte geri alınır. Hesaplar,
oturumlar, kasa verileri, bootstrap ve anahtar davranışı korunur.

Tam veritabanı/anahtar geri yüklemesi aynı Core kimliğini geri getirir. Aynı
yedeği iki bağımsız aktif Core'a klonlama/federasyon kararı F19'un sonraki
işidir; bu dilim kendiliğinden yeni ev yetkisi veya kimlik çatışması çözümü
sağlamaz.

## TDD ve doğrulama

- RED `c2b1758`: üç gerçek HTTP senaryosu eksik endpoint nedeniyle 404 aldı.
- GREEN `46c6f9d`: [28 bağlam testi](../server/tests/test_core_context.py) ve
  [üç eski şema migration testi](../server/tests/test_admin_migration.py) geçti.
- Odaklı komut: `python -m pytest tests/test_core_context.py tests/test_admin_migration.py`.
- Yeni modülde 41/41 statement ve 10/10 ölçülen dal, **%100 kapsam**.
- Restart, bağımsız kurulum, eşzamanlı başlangıç, eski şema, rollback,
  eksik/bozuk kayıt, anahtar bağı ve oturum/rol sınırları doğrulandı.
- Bağımsız incelemede engelleyici bulgu çıkmadı. Tam Server koşumunda gerçek
  Java/apksig dahil **1.075 test geçti**; bu bağlam testleri toplamın içindedir.

İki mimarili [Server container CI](../.github/workflows/server-build.yml)
smoke senaryosuna anonim `/context` reddi ve yeniden başlatmada aynı bağlam
parmak izi kontrolü eklendi. Yeni commit'in gerçek imaj sonucu ayrıca
doğrulandı: `e73533e` [Server Container Build](https://github.com/ersingundem/larenor/actions/runs/33969285470)
iki mimaride geçti. Bu imaj Client reader ve aşağıdaki son şema doğrulama
düzeltmesinden öncedir; güncel kodun CI sonucu ayrıca izlenir.

## İki tarafın ortak sözleşmesi

[core-context.v1.json](../contracts/core-context.v1.json) iki geçerli ve
25 geçersiz tam JSON örneğini hem Server hem Dart Client'a verir. Geçerli
örnekler gerçek Server migration/auth/GET/restart akışından geçirilir;
kimlik üretimi testte belirlenmiştir, auth veya yanıt modeli taklit edilmez.
Geçersiz örnekler eksik/fazla alan, yanlış kök türü, sürüm ve kimlik
biçimlerini kapsar.

- Server RED `604d0c1`: `true` ve `1.0`, şema tam sayısı gibi kabul ediliyordu.
  GREEN `a4caf66`: açık tam sayı doğrulamasıyla aynı iki örnek reddedildi;
  mevcut bağlam/migration ile **59 test geçti**, modülde 47/47 statement ve
  12/12 dal, %100 kapsam. Son tam Server koşumunda gerçek Java/apksig ile
  **1.103 test geçti**.
- Client RED `7858f3c`: model ve API metodu eksikti. GREEN `c1a7796`:
  [41 test](../test/features/server/server_context_test.dart) geçti. Değer
  eşitliği, aynı örnekleri ayrıştırma, reverse-proxy yolunu koruyan Bearer
  GET, ret/redirect/yanıt sınırları, timeout ve iptal kapsandı.
  Mevcut hesap regresyonlarıyla 63 test geçti; yeni model 24/24, GET metodu
  3/3 satır kapsamı aldı, bu iki ortak dosyanın toplamı %83,8. Analiz temiz.
- [Server sözleşme testi](../server/tests/test_core_context_contract.py)
  ve Dart testi mevcut CI keşfine dahildir; ayrı elle çalıştırılan bir
  doğrulama zorunluluğu eklenmedi.

Eski Server'ın 404 yanıtı mevcut `server_error` türüne dönüşür; boş/sahte
bağlam üretilmez. Sunucu mesajı, URL veya token hata metnine eklenmez.
Oturum ve cache bağlama için atomik token kaydı, geç gelen yanıtlar ve
restore hedefi [sonraki dilimler belgesinde](remaining-core-integration-slices.md)
açıkça sıralandı. Bu okuyucunun eklenmesi ev kapsamı izolasyonunun kabulü
veya çoklu ev desteği değildir.
