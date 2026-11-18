# Firebase kurulumu (telefonları birbirine bağlamak için)

Bu adımların hepsi tarayıcıdan yapılır, bilgisayara bir şey kurmanız gerekmez. Yaklaşık 30-45 dakika sürer.
Sonunda: tüm telefonlar aynı veriyi görür, görev tamamlanınca bildirim anında gelir, kilit ve gecikme kontrolü sunucuda çalışır.

## 1. Proje oluşturma
1. https://console.firebase.google.com adresine Google hesabınızla girin, "Proje ekle" deyin, ad olarak "temizlik-takip" yazın.
2. Google Analytics'i kapatabilirsiniz.

## 2. Giriş (Authentication)
1. Sol menüden Build > Authentication > "Başlayın".
2. "Sign-in method" sekmesinde **E-posta/Parola**'yı etkinleştirin (e-posta bağlantısı seçeneğini açmayın).
   Uygulama içinde çalışan kullanıcı adı + 6 haneli PIN girer; arka planda `kullaniciadi@temizlik.local` ve PIN parola olarak kullanılır.

## 3. Veritabanı (Firestore)
1. Build > Firestore Database > "Veritabanı oluştur".
2. Konum: **europe-west1 (Belçika)** ya da size en yakın Avrupa konumu. Mod: **Production**.

## 4. Faturalandırma (zamanlı görevler için)
Gecikme bildirimi ve günlük görev üretimi zamanlı çalışan fonksiyonlardır, bunun için proje **Blaze (kullandıkça öde)** planında olmalıdır.
1. Sol altta "Upgrade" > Blaze. Kart bilgisi istenir.
2. Hemen ardından Google Cloud'da **bütçe uyarısı** kurun (Billing > Budgets & alerts, örn. aylık 5 USD uyarı). Küçük bir ekipte ücretsiz kotaların içinde kalması beklenir, ama güncel kotalar için Google'ın fiyat sayfasına bakın.

## 5. Android uygulamasını ekleme
1. Proje ayarları (dişli) > "Uygulamanız yok" > Android simgesi.
2. **Android paket adı** olarak tam şunu yazın: `com.temizlik.temizlik_takip` (GitHub derleme dosyası uygulamayı bu adla üretir). Diğer alanları boş bırakın.
3. `google-services.json` dosyasını indirin ve **bana gönderin** (ya da GitHub deponuza `android/app/` altına koyun). Depo özel (private) olsun.

## 6. Kuralları ve fonksiyonları yayınlama (Cloud Shell)
1. Firebase konsolunda üst sağdaki Google Cloud simgesinden ya da https://shell.cloud.google.com adresinden **Cloud Shell**'i açın (tarayıcıda terminal).
2. Bu klasörü Cloud Shell'e alın (GitHub deponuzu `git clone` ile ya da "Upload" ile `firebase` klasörünü yükleyin) ve içine girin:

       cd firebase

3. Giriş ve proje seçimi:

       npx firebase-tools login --no-localhost
       npx firebase-tools use --add      # projenizi seçin

4. Fonksiyonların bağımlılıklarını kurup yayınlayın:

       (cd functions && npm install)
       npx firebase-tools deploy --only firestore:rules,functions

   İlk yayında "API etkinleştirilsin mi?" gibi sorulara evet deyin.

## 7. İlk yönetici hesabı
Aynı klasörde (Cloud Shell'de):

    cd functions && node ../scripts/make-manager.js yonetici 123456 "Ad Soyad"

Kullanıcı adı ve 6 haneli PIN'i kendiniz seçin. Diğer personeli bundan sonra uygulamadan (Personel sekmesi) eklersiniz.

## Veri yapısı (özet)
- `config/settings`: gecikme süresi, kilit süresi, tur aralığı
- `buildings`, `floors`, `shifts`, `tasks`: yönetici tanımları
- `staff/{uid}`: ad, telefon, rol, vardiya, katlar, bildirim jetonları
- `days/{gün}/units/{görev_tur}`: günlük görev satırları (yapıldı, kim, ne zaman, kilit)
- `notifications`, `overtime`, `awards`, `perfMonths`

## Güvenlik özeti
- Rol hesabın içinde tutulur (`role`), istemci değiştiremez.
- Kat, görev, personel tanımlama ve kilit açma yalnızca `manager`.
- Kilit sunucu saatiyle denetlenir; telefon saatini değiştirmek işe yaramaz.
- Çalışan yalnızca kendi katlarının görevlerini okur ve işaretler.

## Durum
Kurallar ve fonksiyonlar bu ortamda sözdizimi açısından kontrol edildi, ama Firebase'e karşı çalıştırılıp **denenmedi**. İlk yayından sonra küçük düzeltmeler gerekebilir; hata çıktısını bana yapıştırın.
