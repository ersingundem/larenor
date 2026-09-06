# Android kişi listesi için isteğe bağlı yerel test sunucusu

Yeni `SyntheticCorePeopleAccount`, mevcut hesap fixture'ının ayrı alt sınıfıdır.
Eski `SyntheticCoreAccount`, AppHarness ve on Android yolculuğu değiştirilmedi.
Yalnız bu sınıf açıkça seçilirse üye aktör ve kişi listesi endpoint'i etkinleşir.
Henüz Android yolculuğuna bağlanmadı; bu belge native kabul değildir.

`home_people_contract_fixture.dart` gerçek Server'ın `contracts/home-people.v1.json`
yanıtlarını Android test APK'sı için içerir. Host test bütün JSON değerlerini
karşılaştırır. Sunulan üye sayfaları ve boş görünüm gerçek HTTP sözleşmesiyle
aynıdır; `HomePeoplePage` bunları üretim parser'ıyla okur. Başka Core/ev için
izin üretilmez ve önceki evin etiketleri dönmez.

Yalnız fixture login'inden sonraki tek beklenen Authorization başlığı, tam
GET yolu ve sınırlı cursor/snapshot/limit sorguları kabul edilir. Tekrarlanan
başlık/sorgu, hatalı sayı, newline son eki, eski snapshot ve olmayan cursor
reddedilir. Admin, metadata değişimi, grants ve item endpoint'leri yoktur.
Var olan boş resource sayfası çalışır. Bu sentetik hesap fixture'ının genel
auth davranışı gerçek Server yetki/kurtarma uygulamasının yerini tutmaz.

- Runtime RED `9a2a429`:2 PASS/20 FAIL; derlenen account-only fixture.
- GREEN `6706888`:aynı22 PASS.
- Son ilgili `test/integration_support`: **113 PASS/9sn**.
- Üç dosyada analiz0; format işlemi yalnız bu dosyalara uygulandı.
- Gerçek HTTP testleri `FixtureNetwork` ile yalnız disposable loopback porta
  gider; her test HA requests0 ve acceptedActions boş olduğunu doğrular.
- Eski fixture/account/10journey/üretim/CI ağaçları bu dalda değişmez.

Loglar `/private/tmp/larenor-people-fixture-{red,green,analyze,all-support}.log`.
README, ürün API'si veya kullanıcı hesabı değiştirilmedi; cihaz kurulumu,
CI tetikleme ve ev sistemlerine ağ isteği yapılmadı. Sonraki gerçek Android
kişi ekranı yolculuğu bu fixture'ı açıkça seçerek kullanabilir.

Bağımsız son kaynak incelemesi `4da7e52405591f019b0e7667b82767dc398e15bb`
için CLEAR: auth, görünür sayfalama ve gerçek sözleşme birebirliği ayrıca
incelendi. Redakte gitleaks taraması geçti. Makbuz
`/private/tmp/larenor-core-people-read-fixture-delivery-evidence.json`.
