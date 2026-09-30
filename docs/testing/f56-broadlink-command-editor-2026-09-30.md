# F56 Broadlink tuş düzenleyici ve gerçek öğrenme isteği

30 Eylül 2026, `codex/project-completion-100`. Bu kayıt yazılım davranışının
kanıtıdır; fiziksel IR alımı veya cihaz durumunun değiştiği iddiası değildir.

Normal Core, doğrulanmış Home Assistant servisinin gerçek entity/device
registry kayıtlarını okur. Broadlink kaynağı yalnız öğrenilmiş cihaz ve tuş
adlarını şifreli saklar; raw `b64:` sinyali kabul etmez. Admin ekranındaki
düzenleyici 19 mantıksal tuşu ekler, değiştirir veya kaldırır. Kaynak revizyonu
ve configuration tag ile CAS uygulanır; düzenleme IR göndermez.

Home Assistant'ın [Broadlink dokümanı](https://www.home-assistant.io/integrations/broadlink/)
ve [2026.9.2 adapter kaynağı](https://raw.githubusercontent.com/home-assistant/core/2026.9.2/homeassistant/components/broadlink/remote.py)
`remote.send_command` ve `remote.learn_command` yollarını doğrular.
Öğrenme ancak gerçek `supported_features` bitinde destek bildirildiğinde,
mevcut tuş adına sabit IR kontratıyla istenir. Öğrenme girişiminden önce kaynak
revizyonu kalıcı artırılır; önceki gönderim preview'ları geçersizleşir.
HA adapterı bazı donanım hatalarını yutar ve öğrenilmiş kodu public API'den
okutmaz. Bu nedenle HTTP 200 sonucu dahi `uncertain` kalır;
`deliveryVerified`, `deviceStateVerified` ve `learningVerified` uydurulmaz.

Client belirsiz gönderim sonucunu gösterir ve aynı kayıtlı intent'i tekrar
okuyabilir. Tekrarlanan confirm ikinci HA çağrısı üretmez. Ekran yeni
gönderim için açık yenileme ister; otomatik tekrar gönderim yapmaz.

Geçen kapılar:

- `PYTHONPATH=server server/.venv/bin/python -m pytest
  server/tests/test_f56_home_assistant_provider.py
  server/tests/test_f56_legacy_remote_runtime.py
  server/tests/test_f56_legacy_remote_api.py
  server/tests/test_f56_legacy_smart_remote_core.py -q`: 18 geçti.
- F50/F56 odaklı Flutter koşusu: 47 geçti; bunun F56 kısmı 19 testtir.
  Ayrı runner gerektiren iki test bu genel koşuda açık gerekçeyle atlandı.
- `PYTHONPATH=server server/.venv/bin/python
  server/tests/support/f56_flutter_acceptance.py`: gerçek Flutter Client →
  normal Core → authenticated HA TCP/WebSocket kabulü, 1 geçti. Fixture,
  gerçek registry auth/close frame'lerini ve sırasıyla bir `send_command`
  ile bir `learn_command` POST'unu exact body ile doğruladı. Tekrar confirm
  yeniden göndermedi; öğrenme sonrası eski profile revision reddedildi.
- Odaklı `flutter analyze`: sorun yok. Son provider kontrolü 9/9 geçti.

Geniş exact HEAD CI ve MANUAL fiziksel IR kapısı açıktır. Bu dilim F56'yı
kanıtla tamamlandı olarak yükseltmez; kuyruk 37/126, özellik sayacı 3/63 kalır.
