# Server Vault: hazırlanmış geri yükleme devri

Bu dilim Server Vault ekranını ortak `PreparedBackupRestore` ve `ConfigurationScope.restorePrepared` akışına bağlar. Vault için ikinci bir restore engine veya ham `repository.restore` fallback'i yoktur. S08.5'in bütünü, gerçek cihaz ve yeni CI kabulü bu belgenin sonucu değildir.

Çalışma dalı `codex/server-vault-prepared-restore`, çalışma ağacı `/private/tmp/larenor-server-vault-prepared-restore`; başlangıç checkpoint'i `379696d`. Ortak engine/access/ConfigurationScope/BackupScreen ve EN/TR kaynakları diğer sahibin checkpoint'lerinden merge ile alınmıştır; bu dilimin üretim sahipliği yalnız `server_vault_controller.dart` ve `server_vault_screen.dart` dosyalarıdır. Root kuyruk ve PROGRESS dosyaları değiştirilmedi.

## Davranış

- Restore incelemesi, seçili uzak belgenin doğrulanmış kopyasıyla yerel hedefin readset'ini ve kaynak/PIN/oturum erişimini önceden bağlar. İnceleme alan değerlerini veya sırları UI'ya taşımaz.
- Onaydan sonra mevcut uzak Vault revision'ı tekrar okunur. Account generation, görünür route, onay süresi ve hazırlanmış hedefler geçerliyse yalnız aynı tek kullanımlık capability devredilir.
- ConfigurationScope claim yapar, eski provider/route ağacını kaldırır, sonra ortak engine kalıcı v2 journal üzerinden çalışır. Screen/controller disposal sonrası eski Ref üzerinden yazma veya ham closure çalıştırılmaz.
- Account, HomeSessionController, repository ve ProviderContainer kimlikleri yakalanır. State yabancı scope'a taşınırsa eski inceleme kapanır; geri taşıma eski callback'i canlandırmaz. Açık modal yalnız kendi route'u için frame sonrasında kaldırılır.
- Emekli preview/final GET ve süresi dolmuş final GET'in gecikmiş 401'i güncel hesabı silemez. Aktif ve süresi geçmemiş 401 için normal account rejection korunur. Upload protocol/authorization değiştirilmedi; bu düzeltmenin hata sınırı restore/preview GET'leridir.
- Core'da Direct grupları için ortak `backupRestoreDirectTarget` metni kullanılır. Bu reddetme yerel Direct credential okuma/yazması başlatmaz.

## RED → GREEN checkpoint'leri

| Garanti | RED kanıtı | GREEN checkpoint / kanıt |
|---|---|---|
| Onay altında değişen hedef/source üzerine yazmama; gerçek Scope ile v2 journal | `2021cc3`: 3 FAIL; eski akış v1 journal yazdı ve iki değişik hedefi üzerine yazdı | `c09e795`: 3 PASS |
| Başka account container'ına taşınan aynı State eski incelemeyi göstermez | `b8f411a`: 1 FAIL | `b8b3d9a`: 14 yeni runtime PASS |
| Aynı account/home ile farklı repository/container ve açık modal; emekli GET 401 | `6abc4b9`: scope 1 PASS/3 FAIL; GET 1 PASS/2 FAIL | `519bd13`: 37 controller/runtime PASS |
| Core Direct-target hatası doğru ve sır okumadan görünür | `9274881`: 1 FAIL | `f356010`: 55 odaklı PASS |
| Final GET cevabı 5 dakikalık inceleme süresini aşarsa geç401 hesabı silemez | `09c2822`: 1 FAIL | `54549d7`: 21 controller PASS |

Sonraki ortak recovery bağlama API'si, Core fixture'ındaki ayrı backup ve session depolarını doğru biçimde reddetti: `dbeeb23` birleşiminde 13 PASS/5 FAIL. Test-only `5caebae`, repository'nin `recoverySourceStore` ve `recoverySessionStore` parametrelerine captured access ile aynı store nesnelerini geçirir; yeni birleşimde 56 PASS. Bu fixture uyumu üretim güvencesini gevşetmez; eski 55 PASS yeni engine'in kanıtı olarak kullanılmaz.

## Gerçek test sınırları

Yeni 18 widget testi gerçek `ServerVaultScreen`, `ServerAccountController`, `HomeSessionController`, `SettingsGateScreen`, `IdleGate`, `ConfigurationScope` ve prepared engine'i kullanır. Core senaryolarında gerçek PIN girişiyle account ekranından Vault'a girilir; restore sonrası yeni provider ağacı ve yeniden PIN kilidi doğrulanır. EN/TR, 600/1200 genişlik ve 2x metin durumlarında framework overflow/exception yoktur. SharedPreferences ve secure storage platformları test backend'i, Vault transport'u sentetik API fixture'ıdır; bu sonuç native Keystore, işletim sistemi process restart veya Android emulator çalıştırma kanıtı değildir.

Testler ayrıca uzak revision drift, kalıcı PIN/source/session değişimi, final GET sırasında logout, cancel sonrası eski onay, native view focus kaybı, aktif401 ile stale401 ayrımı, before/after handoff tek kullanımı, mevcut privacy/certificate review, PIN ve unrelated session kayıtlarının korunmasını kapsar. Provider lifetime testleri eski container/account'u canlı tutar; yalnız widget gizlenmesini storage yetkisi saymaz.

## Doğrulama

Bütün Flutter/Dart komutları `python3 /private/tmp/larenor-flutter-check.py` ortak kilidi üzerinden çalıştırıldı. Ana kaynakta commit, push, CI çalıştırma, canlı endpoint, ev veya cihaz işlemi yapılmadı.

- Odaklı son seam koşusu: 56 PASS / 5 saniye, `/private/tmp/larenor-vault-prepared-final-seam.log`.
- İlgili ilk geniş koşu: 382 PASS / 3 FAIL / 12 saniye, `/private/tmp/larenor-vault-prepared-related.log`. Üç başarısızlık diğer sahibin eski Core session/scope ve legacy panel fixture'larıydı; gizlenmedi ve o sahibin `5e5f3fe` checkpoint'inde düzeltildi.
- Nihai ilgili koşu: 387 PASS / 13 saniye; ortak engine `1fa12a1` ve fixture `5e5f3fe` dahil; `/private/tmp/larenor-vault-final-related.log`.
- Nihai analiz/format ve satır kapsamı: 6 owned Dart dosyasında analiz 0 sorun ve format 6 dosya/0 değişiklik. Loglar `/private/tmp/larenor-vault-final-analyze.log` ve `/private/tmp/larenor-vault-final-format-check.log`. Son ilgili koşunun satır kapsamı controller 117/118, screen 353/364; toplam 470/482 (%97,51). LCOV: `/private/tmp/larenor-vault-final-related-coverage.info`.

İlgili komut, tüm `test/features/backup`, üç Vault test dosyası, `server_connection_screen_test.dart`, `settings_gate_screen_test.dart`, `configuration_scope_test.dart` ve `prepared_configuration_scope_test.dart` dosyalarını çalıştırır. Kapsam satır ölçümüdür; branch/cihaz kapsaması iddiası değildir. Özel receipt: `/private/tmp/larenor-server-vault-prepared-delivery-evidence.json`.

## Ayrı modal erişilebilirlik deltası

Önceki `79f313b` freeze ve 387 PASS kaydı yukarıdaki engine/oturum tesliminin kanıtıdır. Sonraki dar modal düzeltmesi o sonuca dahil değildir.

Gerçek `ServerVaultScreen` onay penceresinde EN/TR × 320/600/1280 genişlik × 2x metin matrisi, altı eksik button rolü ve altı Tab/Enter iptal hatasını yeniden üretti: RED `2b8e81f`, 2 mevcut koruma testi PASS / 12 yeni FAIL; `/private/tmp/larenor-vault-modal-a11y-red.log`. Yalnız ekran içindeki `_VaultDialogAction`, mevcut `CupertinoDialogAction` görünümünü/destructive niteliğini ve eylem key'ini koruyarak açık button semantiği, Enter/Space aktivasyonu ve görünür klavye odağı ekler. Onay/iptalin `routeIsCurrent(epoch)` callback'leri, controller, deadline, shared engine ve handoff sırası değişmez.

Minimal GREEN `01bb288`: aynı seçimde 14 PASS / 2 saniye; `/private/tmp/larenor-vault-modal-a11y-green-final.log`. İlk ara çalışmadaki test finder'ı aynı birleşik semantics node'una bakan iki widget'ı saymıştı; tek etiket artık yayımlanan semantics ağacındaki node üzerinden ölçülür. SemanticsHandle test sonunda explicit finally ile bırakılır.

Son testler gerçek bundled Inter/CupertinoIcons ile 48px veya daha büyük eylem hedeflerini, tek etiket/button rolünü, 2x taşmasız yerleşimi, Tab/Shift-Tab ve Enter/Space iptalini doğrular. Light/dark odak görünürlüğü, semantics tap ile sıfır etkili iptal, klavye onayıyla mevcut typed handoff ve native view odağı kaybolduktan sonra yakalanmış keyboard action'ın yazamaması da kapsamdadır. Değişen ekran semantiği için yerel testler kullanılmıştır; Android erişilebilirlik servisi veya fiziksel klavye kabulü iddia edilmez.

- Üç Vault dosyası: 73 PASS / 7 saniye; `/private/tmp/larenor-vault-modal-final-focused.log`.
- Son test-only public `ActionDispatcher` ve format düzeltmesi ardından bütün prepared ekran dosyası: 35 PASS / 4 saniye; `/private/tmp/larenor-vault-modal-final-delta.log`.
- İki owned Dart dosyası: analiz 0 sorun, format 2 dosya/0 değişiklik; `/private/tmp/larenor-vault-modal-analyze-final.log`, `/private/tmp/larenor-vault-modal-format-final.log`.
- 73 testlik koşu satır kapsamı: controller 117/118, screen 376/387, toplam 493/505 (%97,62); `/private/tmp/larenor-vault-modal-final-coverage.info`.
- Ayrı özel makbuz: `/private/tmp/larenor-vault-modal-a11y-delivery-evidence.json`.
