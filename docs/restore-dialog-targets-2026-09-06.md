# Restore onay modalları: etkin hedef ve normal metin boyutu

Bu ayrı B5.1 düzeltmesi `BackupScreen`, `ServerVaultScreen` ve `CoreLayoutArchiveScreen` içindeki mevcut üç özel dialog eylemini kapsar. Jobs diliminin test/CI kanıtına eklenmez. Çalışma ağacı `/private/tmp/larenor-restore-dialog-targets`, dal `codex/restore-dialog-targets`, taban `455dce5755650ca3636ac2e67865fba032285c9c`. Üretim checkpoint'i `ed4cf5a`; son test checkpoint'i `31b67e12110e7bab34d1a9c8d81870966e5aac52`.

## Sorun ve dar düzeltme

Normal1x Cupertino dialog sizing, `Container(alignment: center)` içeriğini geniş intrinsic kutu olarak ölçüyor ve `FittedBox` ile kısa Cancel/İptal etiketini bile yaklaşık0,59524 ölçeğe indiriyordu. Aynı normal modda etkin ekran okuyucu düğmesi45px yükseklikte kalıyordu. Bu iki sorun her üç gerçek ekranda EN/TR600/1280 varyantında yeniden üretildi;2x varyantları geçiyordu.

Her mevcut native `CupertinoDialogAction` dışına `ConstrainedBox(minHeight:48)` eklendi. İç `alignment:center` yerine `Center(widthFactor:1,heightFactor:1)` doğal etiket genişliğini korur. Mevcut iç minimumlar (Backup/Vault32, Archive48), native stil, renk, action key, `onPressed`, klavye/semantik callback'leri değişmez. TextScaler clamp, yeni küresel UI helper veya modal lifecycle tasarımı yoktur.

Üç üretim dosyasında private dialog State sınıfından önceki bütün kaynak tabanla byte-equivalenttir. Restore engine, hedef/scope/account/PIN/epoch/revision kontrolü, ConfigurationScope handoff ve tek kullanım davranışı değiştirilmedi.

## Ölçüm ve TDD

`test/support/restore_dialog_geometry.dart` yalnız test yardımcısıdır. Gerçek kök semantik ağacından `!isMergedIntoParent` düğümlerini alır; label, button flag ve tap action için `getSemanticsData()` kullanır. Etkin düğme alanı en az48×48, iki eylem için toplam iki etkin tap button ve her eylem adı için tek button aranır. Dialog başlığının eylemle aynı metni taşıması ikinci button sayılmaz.1e-9 toleransı sadece kayan nokta geometrisi içindir.

Kısa iptal etiketinin gerçekten çizilen boyutu `MatrixUtils.transformRect(RenderParagraph.getTransformTo(null), rect)` ile ölçülür; çizilen/layout yüksekliği oranı1 olmalıdır. Bu normal metni veya2x ölçek tercihini zorla değiştirmez. Her ölçüm gerçek UI açılışından sonra yapılır. Ölçüm hataları toplansa bile gerçek klavye iptal yolu çalışır; değişmezlik assertion'ları ayrıca doğrulanır.

- RED `5c90061`: **12 PASS / 12 FAIL /31s**, her üç ekranda EN/TR600/1280@1x için etkin45px ve kısa etiket0,5952380952; bütün2x varyantları PASS.
- GREEN `ed4cf5a`: aynı **24 PASS /26s**.
- Son test-only Tab/Shift-Tab/capture genişletmesiyle **9 ilgili dosya,152 PASS /1:20**. Yeni24 test bu sayıya dahildir;24 ve152 toplanmaz. Son iki brace düzenlemesi yalnız test yardımcısında, davranışı değiştirmez.
- Son analiz **7 item /0 issue**; format **7 dosya /0 değişiklik**.

İlk tanısal koşuda Archive'ın primary eylemi ve dialog başlığı aynı ada sahip olduğundan helper ikisini saymıştı (8PASS/16FAIL). Button filtresiyle düzeltilen ölçüm yukarıdaki gerçek12/12 RED'dir; başlık/eylem aynı metninin kendisi ürün kusuru sayılmaz.

Yeni testler gerçek PreparedBackupScreen/VaultPrepared/ArchiveScreen harness'lerini, üretim restore repository/controller/ConfigurationScope yollarını, Core arşivi için gerçek codec/PIN/home scope'u kullanır. Tab iptalden diğer eyleme geçer; Shift-Tab geri döner, Enter ile iptal olur. Backup/Vault için yazı ve runtime disposal yok; Vault upload yok. Core arşivi için scope revision değişmez, file save/HA connection read yok. Mevcut ilgili testler onaylı başarı, hedef/scope/PIN/native focus/root route/provider değişimi, tutulan callback, source-roundtrip, geç dosya cevabı ve gerçek restore/iptal davranışlarını korur.

## Son kaynak kapsamı ve görseller

Satır kapsamı; branch veya tüm uygulama kapsamı değildir:

| Üretim dosyası | Hit/found | Satır kapsamı |
| --- | --- | --- |
| backup_screen.dart |567/606|%93,56|
| server_vault_screen.dart |378/389|%97,17|
| core_layout_archive_screen.dart |503/523|%96,18|

Gerçek bundled Inter/CupertinoIcons ile EN6001x, TR6002x ve EN1280 2x görüntüleri `/private/tmp/larenor-restore-dialog-preview/` altında `{backup,vault,archive}-{en,tr}-{600,1280}-{1,2}x.png` adlarıyla seçilen dokuz varyant olarak üretildi. Her ekranın EN6001x ve TR6002x görüntüsü `view_image` ile açıldı: kısa iptal metni normal boyutta,2x metin wrap ve odak çizgisi görünür. Root ayrıca BackupEN6001x, ArchiveTR6002x ve VaultEN12802x görsellerini açarak onayladı. Archive harness debug ribbon'u özel test görüntüsünün parçasıdır; ürün taşması değildir.

Root `ed4cf5a` üretim ve son test-only traversal/capture farkını bağımsız inceleyip CLEAR verdi; yeni somut P1/P2 bulunmadı. Bu genel tasarım, bütün normal tint metin kontrastı, README galerisi, TalkBack veya fiziksel tablet/DeX kabulü değildir.

Özel kanıtlar `/private/tmp/larenor-restore-dialog-{corrected-red,runtime-green,related,analyze-final,format-final}.log`, `larenor-restore-dialog-coverage.info` ve `/private/tmp/larenor-restore-dialog-targets-delivery-evidence.json` içindedir. SDK komutlarının tamamı `/private/tmp/larenor-flutter-check.py` kilidini kullandı; son test66453 ve analiz/format62794 exit0 ile toplandı. Ek fullClient/Server/CI çalıştırılmadı. Push, main/queue/progress değişimi, gerçek ev/Server/HA erişimi veya cihaz kurulumu yapılmadı; sonraki birleşik fullClient ve yayın kabulü root'a aittir.
