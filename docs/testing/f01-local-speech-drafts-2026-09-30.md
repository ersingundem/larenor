# F01 — gerçek Android yerel ses ve onaylı taslak

30 Eylül 2026; çalışma dalı `codex/project-completion-100`. Bu belge yazılım
kanıtını ve henüz doğrulanmayan model/cihaz koşulunu ayırır.

Android API 31+ üzerindeki gerçek `createOnDeviceSpeechRecognizer` kullanılır.
API 33+ ayrıca istenen `en-US` veya `tr-TR` dilinin kurulu on-device dil
listesinde olmasını ister. Genel ağ recognizerına geçiş yoktur. Ses dosyası
kaydedilmez veya Core’a yüklenmez. TTS kurulu, ağ gerektirmeyen aynı dilde
bir voice seçer; eksik provider/model/voice görünür unavailable sonucudur.

İzin verme kayıt başlatmaz; kullanıcı ikinci kez dokunur. Foreground/focus,
route, hesap, PIN geçerliliği, iptal, 30 saniye deadline, geç callback ve
provider exception yaşam döngüleri korunur. Son metin düzenlenebilir alana
gelir; preview veya activation kendiliğinden çalışmaz. Desteklenen katalog
yalnız açık turn-on/turn-off ifadeleridir; serbest model talimatı veya ek
metin reddedilir. Kullanıcı güncel yetkili HA anahtarını açıkça seçer; ilk
cihaz otomatik seçilmez. Düzenleme eski taslağı kaldırır. Boş hedefler
açıklanır, başarısız okuma açık bir Retry dokunuşuyla güncel yetkiyi yeniden
yükler. Activation yalnız inert kural saklar, cihazı çalıştırmaz.

## Çalıştırılmış kanıt

- Native Android derlemesi geçti. Robolectric platform speech paketi 10/10:
  gerçek Android host sınıfı, on-device support, offline voice, izin/iptal,
  geç callback ve async recognizer/TTS exception. Framework shadow
  providerı fiziksel mikrofon/model kabulü değildir.
- Flutter channel + gerçek screen/controller/API parsing + loopback API:
  11/11. Açık ikinci hedef, düzenleme, ayrı izin/recognize gesture, no auto
  POST, boş liste ve Retry sınırları. Scoped analyze temiz.
- `test_f01_f03_automation_final.py`: 3 Server testi geçti.
- `server/tests/support/f01_flutter_acceptance.py`: 1 gerçek Flutter →
  normal TCP Core → gerçek TCP HA state read kabulü geçti. Onaylı inert
  kural SQLite’ta saklandı, HA command sayısı sıfır. Core snapshot cache’i
  tekrar okuma sayısını azaltabilir; runner kurulumdan sonraki actual
  upstream okumayı ve sıfır device effect’i ayrı doğrular.

Yerel geçici API35 AOSP emulator açılıp gerçek service inventory okundu:
RecognitionService ve TTS service yok, varsayılanları null. Emulator ve
geçici AVD temizlendi; model veya image indirilmedi. Dolayısıyla gerçek
EN/TR recognition/TTS engine ve mikrofon kabulü uygun model taşıyan cihaz
veya emulator üzerinde MANUAL kapısında açıktır. Android dışındaki
platformlar eksik native providerı saklamaz, metin girişi kullanılabilir.
Exact commit geniş CI ve manual platform kabulü tamamlandı sayılmaz.

Resmi sözleşmeler: [SpeechRecognizer](https://developer.android.com/reference/android/speech/SpeechRecognizer),
[RecognizerIntent](https://developer.android.com/reference/android/speech/RecognizerIntent),
[Voice](https://developer.android.com/reference/android/speech/tts/Voice),
[TextToSpeech](https://developer.android.com/reference/android/speech/tts/TextToSpeech).
On-device factory ve kurulu offline voice koşulları yalnız offline intent
tercihine güvenmekten daha kesin bir provider sınırı sağlar.
