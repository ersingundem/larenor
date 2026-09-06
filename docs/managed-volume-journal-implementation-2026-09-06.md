# Yönetilen volume için ayrı kalıcı gözlem journal'ı

6 Eylül 2026. Yerel uygulama ve sentetik test kanıtı; sonraki teslim paketi için donduruldu. Bu dilim kurulum desteği, Docker volume oluşturma veya S06.3d'nin tamamlanması değildir. Planın `installAvailable=false` sınırı korunur.

## Kaynak

- Çalışma ağacı: `/private/tmp/larenor-managed-volume-journal`.
- Dal: `codex/managed-volume-journal`.
- Başlangıç: `4baa55a4ab3022378f705f72aafe496a949b689c` — saf volume planı ve response gözlemcisi.
- Üretim: yeni `server/larenor_server/plugins/volume_journal.py`; ilk GREEN `bd696ae`.
- Son test checkpoint: `e274790`; üretim `bd696ae` sonrasında değişmedi.
- Test: yeni `server/tests/test_volume_journal.py`.
- Image/network/native appdata journal, volume observer, worker, API, installer ve ana kuyruk dosyaları değiştirilmedi.

## Kalıcı sözleşme

`VolumeJournal`, mevcut `ResourceJournal` sınıfının özel SQLite/FD/flock/transaction kabuğunu kullanır. Metadata aggregate'i `larenor-volume-journal-v1` domain'ine bağlıdır. Boş journal dahil native ve volume kayıtları birbirinin yerine açılamaz; inode kayıtları volume adı olarak yorumlanmaz. Aynı private dizinde yeni şema yaratma, reset veya migration yoktur.

Volume'a özel `prepare`, `bind`, `begin_observation`, `mark_uncertain` ve `reconcile` metotları; typed `VolumeReceipt` ve private `VolumeIntent` üretir. Miras alınan `get`/`list` volume decoder'ından geçer. Native `begin` açık `volume_effects_disabled` hatası verir. Native sınıf metotlarını unbound biçimde doğrudan çağırma ve image/network effect köprülerine volume journal verme negatif testlerle reddedilir.

Tam volume planı, stack, catalog ve policy snapshot'ı her hazırlık/bağlama/gözlem öncesinde yeniden türetilir. Kayıt, resource/operation/preparation kimliklerine, plan ve policy digest'lerine; özel binding de journal kimliği, kalıcı nonce ve resource specification digest'ine bağlıdır. Observer sonrası aynı kaynak ve revision tekrar kontrol edilir; son kayıt decoder'ı da saklanacak observation'ı yeniden doğrular. Alias veya yeniden girişle değişen durum eski başarıyla ezilmez.

| Kaynak durum | İzinli kalıcı geçiş |
| --- | --- |
| `prepared`, revision 1 | `begin_observation` → `observing`, revision 2 |
| `observing` | `uncertain` veya taze typed gözlem sonucu; revision artar |
| `uncertain` | Yalnız yeniden gözlem; `labels_observed`, `uncertain` veya `needs_attention` |
| `labels_observed` / `needs_attention` | Terminal geçmiş; aynı prepare isteği mevcut kaydı döndürür |

`begin_observation` yalnız gözlem başlangıcı kaydıdır; oluşturma yetkisi veya effect başlangıcı değildir. `labels_observed`, önceki bir anda beklenen etiketlerin eşleştiğini ifade eder. Yeni oluşturma, devam eden münhasır sahiplik, attachment güvenliği, UID yazma izni, bootstrap veya kurulum hazır anlamına gelmez. Docker yöneticisi etiketleri kopyalayabilir. Hash'ler private worker hesabına karşı güvenlik sınırı değil, bozulma/yanlış domain algılama zarfıdır.

Gözlemci private senkron bağımlılıktır. Bu modül Engine veya ağ çağırmaz; gelecekteki doğrulanmış transport response'u gerçek daemon/request'e bağlamalı ve kendi deadline/iptal denetimini uygulamalıdır. Callback öncesi iptal hiç gözlem çalıştırmaz; callback sırasında iptal `labels_observed` sonucu yayımlamaz. Daha önce başlamış bir dış işlemin durdurulduğu veya geri alındığı iddia edilmez.

## Sınırlar ve doğrulama

- En çok 1792 kayıt: 256 hazırlık × yedi private appdata target. Tam snapshot üst sınırı 98.304 byte; mevcut sentetik kaynak yaklaşık 38,8 kB'dir.
- Kalıcı dosyalar, kimlik zarfı, mode/owner/link/FD eşliği, süreç/thread lease, SQLite şeması, tam integrity doğrulaması ve transaction/fsync kabuğu korunur. Kaybolan/bozulan mevcut kayıt sessizce yeniden yaratılmaz.
- Revision gerçek integer ve CAS ile kontrol edilir. Journal reopen aynı kimlik ve nonce'u korur; başka journal, Core/ev/preparation/policy veya sahte etiket gözlemi kabul edilmez.
- Response'daki host `Mountpoint` pure observer tarafından atılır; journal'a veya receipt'e taşınmaz. API/key/token veya host dizini yetkisi eklenmez.

TDD: `678a31e` runtime RED'de 14 FAIL; import veya fixture setup hatası yoktur. `bd696ae` ilk GREEN'de 14 PASS. Son odaklı paket **54 PASS / 11,19 saniye**. Volume plan/observer ve mevcut resource journal ile birleşik paket **273 PASS / 20,64 saniye**. Yeni modülde **139/139 statement ve 8/8 branch: %100**. Bu oran tüm Server'ın kapsamı değildir. İki mevcut FastAPI/Starlette deprecation uyarısı ayrıca kaldı; test hatası değildir.

Özel kayıtlar: `/private/tmp/larenor-volume-journal-red.log`, `larenor-volume-journal-green.log`, `larenor-volume-journal-final-focused.log`, `larenor-volume-journal-final-related.log`, `larenor-volume-journal.coverage` ve `larenor-volume-journal-coverage.json` (hepsi `/private/tmp` altında).

Python 3.12 mevcut Server ortamı ve mevcut coverage helper'ı kullanıldı; yeni bağımlılık kurulmadı. Gerçek SQLite geçici özel dizinlerde çalıştı; Engine/host chown/subprocess etkileri sentetik negatif testte yasaklandı. Canlı Docker, ev host'u, kurulum route'u, worker etkinleştirme, CI/push veya imzalı APK işlemi yapılmadı. Önceki paketlerin CI/teslim kanıtına bu journal dahil değildir.
