import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const TemizlikApp());

// Örnek numara; gerçek yönetici numarasıyla değiştirin.
const managerPhone = '0532 000 00 00';

/// Arama ekranını numarayla açar (tek dokunuşla arama).
Future<void> callPhone(BuildContext context, String phone) async {
  final uri = Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'[^0-9+]'), ''));
  final ok = await launchUrl(uri);
  if (!ok && context.mounted) toast(context, 'Arama başlatılamadı: $phone');
}

// ---------------------------------------------------------------------------
// Yardımcılar
// ---------------------------------------------------------------------------
String fmtTime(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
TimeOfDay parseTime(String s) {
  final p = s.split(':');
  return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
}

String nowStr() => fmtTime(TimeOfDay.now());
String minutesToStr(int m) =>
    '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

/// Güçlü bildirim sesi: 4 notalı uyarı + titreşim. Ses dosyası kodla üretilir, ek dosya gerekmez.
Uint8List? _alertWav;
final AudioPlayer _alertPlayer = AudioPlayer();

Uint8List _buildAlertWav() {
  const rate = 22050;
  const notes = [(880.0, 0.20), (1320.0, 0.20), (880.0, 0.20), (1320.0, 0.40)];
  const gap = 0.06;
  final pcm = <int>[];
  for (final (freq, dur) in notes) {
    final n = (rate * dur).round();
    for (var i = 0; i < n; i++) {
      final t = i / rate;
      // Kare dalgaya yakın (güçlü) ses; başta ve sonda kısa geçiş, tıklama olmasın.
      final env = math.min(1.0, math.min(i / 200, (n - i) / 200));
      final v = (math.sin(2 * math.pi * freq * t) + math.sin(6 * math.pi * freq * t) / 3 +
              math.sin(10 * math.pi * freq * t) / 5) *
          0.85;
      pcm.add((v.clamp(-1.0, 1.0) * env * 32767).round());
    }
    pcm.addAll(List.filled((rate * gap).round(), 0));
  }
  final data = ByteData(44 + pcm.length * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + pcm.length * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, pcm.length * 2, Endian.little);
  for (var i = 0; i < pcm.length; i++) {
    data.setInt16(44 + i * 2, pcm[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

void playAlert() {
  HapticFeedback.heavyImpact();
  try {
    _alertPlayer
        .play(BytesSource(_alertWav ??= _buildAlertWav()), volume: 1.0)
        .catchError((_) => SystemSound.play(SystemSoundType.alert));
  } catch (_) {
    SystemSound.play(SystemSoundType.alert);
  }
}

/// Verilen saat (SS:DD) şu andan önce mi? Yapılmamış turlar için "gecikti" kararında kullanılır.
bool isLate(String time) {
  final t = parseTime(time), n = TimeOfDay.now();
  return t.hour * 60 + t.minute < n.hour * 60 + n.minute;
}

void toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
}

// ---------------------------------------------------------------------------
// Modeller
// ---------------------------------------------------------------------------
class Building {
  final String id, name, short;
  const Building(this.id, this.name, this.short);
}

// Yönetici yeni bina ekleyebilir.
final List<Building> buildings = [Building('A', 'Ana Bina', 'Ana'), Building('E', 'Ek Bina', 'Ek')];

class Floor {
  final String id, buildingId;
  String name;
  Floor(this.id, this.buildingId, this.name);
  Building get building => buildings.firstWhere((b) => b.id == buildingId);
  String get label => '${building.name} · $name';
  String get short => '${building.short} $name';
}

/// Günde birden fazla yapılan görevin tek bir turu (örn. WC 14:00 turu).
class TaskSlot {
  final String time;
  bool done = false, lateSent = false, unlocked = false; // unlocked: yönetici kilidi açtı
  String? doneAt, doneBy;
  TaskSlot(this.time);
}

/// Günde birden fazla yapılan görevlerin tur aralığı (yönetici Ayarlar'dan değiştirir).
String slotFrom = '08:00', slotTo = '18:00';

int _toMin(String t) {
  final p = parseTime(t);
  return p.hour * 60 + p.minute;
}

/// Günde [n] kez yapılacak görev için saatler: [slotFrom]–[slotTo] arasına eşit dağıtılır.
List<String> slotTimes(int n) {
  if (n <= 1) return [];
  final a = _toMin(slotFrom);
  final span = (_toMin(slotTo) - a).clamp(0, 1440).toInt();
  final step = ((span / (n - 1)) / 5).round() * 5;
  return [for (var i = 0; i < n; i++) minutesToStr(a + i * step)];
}

/// Vardiya tanımı (örn. Sabah vardiyası 07:00–15:00). Saati değişince vardiyadaki herkes güncellenir.
class Shift {
  final int id;
  String name, from, to;
  Shift(this.id, this.name, this.from, this.to);
}

class Task {
  final int id;
  String floorId, area, title, time;
  final List<String> items;
  late List<bool> checked;
  List<TaskSlot>? slots; // null: günde 1 kez
  bool done = false, lateSent = false, unlocked = false; // unlocked: yönetici kilidi açtı
  String? doneAt, doneBy;
  Task({
    required this.id,
    required this.floorId,
    required this.area,
    required this.title,
    required this.time,
    required this.items,
    int perDay = 1,
  }) {
    checked = List<bool>.filled(items.length, false);
    if (perDay > 1) {
      slots = [for (final t in slotTimes(perDay)) TaskSlot(t)];
      time = slots!.first.time;
    }
  }

  int get total => slots?.length ?? 1;
  int get doneCount => slots != null ? slots!.where((s) => s.done).length : (done ? 1 : 0);
}

int unitsDone(Iterable<Task> l) => l.fold(0, (a, t) => a + t.doneCount);
int unitsTotal(Iterable<Task> l) => l.fold(0, (a, t) => a + t.total);

class Staff {
  String name, from, to, phone, role; // role: 'Çalışan' | 'Şef'
  int shift = 0; // vardiya numarası, 0: özel saat
  Set<String> floors;
  Staff(this.name, this.from, this.to, this.floors,
      [this.phone = '', this.role = 'Çalışan']);
  bool get isChief => role == 'Şef';
}

/// Aylık başarı özeti (örnek geçmiş veri). Bugünün verisi görevlerden canlı hesaplanır.
class PerfMonth {
  final int year, month, assigned, onTime, late;
  final String name;
  const PerfMonth(this.year, this.month, this.name, this.assigned, this.onTime, this.late);
}

/// Sıralama satırı. Puan = (zamanında + geç x 0,5) / atanan x 100.
class RankRow {
  final String name;
  final int assigned, onTime, late;
  const RankRow(this.name, this.assigned, this.onTime, this.late);
  int get done => onTime + late;
  int get score => assigned == 0 ? 0 : ((onTime + 0.5 * late) / assigned * 100).round();
}

class Award {
  final String name, label;
  final int rank;
  final DateTime date;
  const Award(this.name, this.label, this.rank, this.date);
}

class Notif {
  final String to, text, time;
  final Map<String, bool> read = {'worker': false, 'manager': false, 'chief': false};
  Notif(this.to, this.text, this.time);
}

const monthNames = [
  'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
  'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık'
];
const dayNames = ['Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi', 'Pazar'];

String dateLabel(DateTime d) =>
    '${d.day} ${monthNames[d.month - 1]} ${d.year} ${dayNames[d.weekday - 1]}';

/// Mesai yalnızca gün olarak sayılır (her kayıt 1 gün).
String fmtHours(double h) => '${h.round()} gün';

/// Hafta sonu mesaisi kaydı.
class Overtime {
  final int id;
  final String name;
  final DateTime date;
  bool done;
  Overtime(this.id, this.name, this.date, this.done);

  /// Her mesai kaydı 1 gündür.
  double get hours => 1;
}

class OtRow {
  final String name;
  final double done, planned;
  final int days;
  const OtRow(this.name, this.done, this.days, this.planned);
}

// ---------------------------------------------------------------------------
// Durum (şimdilik bellekte; sonraki adımda Firestore'a bağlanacak)
// ---------------------------------------------------------------------------
class AppState extends ChangeNotifier {
  final List<Floor> floors = [];
  final List<Task> tasks = [];
  final List<Staff> staff = [];
  final List<Notif> notifs = [];
  int _taskSeq = 0;
  int _floorSeq = 10;
  final List<Overtime> overtime = [];
  final List<Shift> shifts = [];
  final List<PerfMonth> history = [];
  final List<Award> awards = [];
  int _otSeq = 0, _shiftSeq = 2, _bldSeq = 0;

  AppState() {
    shifts.addAll([
      Shift(1, 'Sabah vardiyası', '07:00', '15:00'),
      Shift(2, 'Öğlen vardiyası', '12:00', '20:00'),
    ]);
    for (var i = 0; i < 5; i++) {
      floors.add(Floor('A$i', 'A', i == 0 ? 'Zemin Kat' : '$i. Kat'));
    }
    for (var i = 0; i < 4; i++) {
      floors.add(Floor('E$i', 'E', i == 0 ? 'Zemin Kat' : '$i. Kat'));
    }
    _task('A0', 'Giriş holü', 'Zemin silme ve cam yüzeyler', '08:00',
        ['Zemini süpür', 'Paspas yap', 'Giriş camlarını sil']);
    _task('A0', 'Resepsiyon', 'Tozları al, çöpleri boşalt', '08:45',
        ['Tezgâhı sil', 'Çöpü boşalt', 'Zemini temizle']);
    _task('A0', 'Asansör', 'İç yüzey ve düğmeler', '09:15',
        ['Düğmeleri dezenfekte et', 'Aynayı sil', 'Zemini sil']);
    _task('A0', 'WC', 'Tam temizlik ve sarf kontrolü', '09:45',
        ['Klozet ve lavabo', 'Zemini dezenfekte et', 'Kâğıt ve sabun doldur'],
        perDay: 6); // WC günde 6 kez
    for (var i = 1; i < floors.length; i++) {
      final base = 8 * 60 + i * 40;
      _task(floors[i].id, 'Koridor ve merdiven', 'Zemin ve korkuluklar',
          minutesToStr(base), ['Zemini süpür', 'Paspas yap', 'Korkulukları sil']);
      _task(floors[i].id, 'WC', 'Tam temizlik ve sarf kontrolü',
          minutesToStr(base + 30),
          ['Klozet ve lavabo', 'Zemini dezenfekte et', 'Kâğıt ve sabun doldur'],
        perDay: 6); // WC günde 6 kez
    }
    tasks.sort((a, b) => a.time.compareTo(b.time));
    // Örnek ilerleme: bazı görevler yapılmış, kimin yaptığı kayıtlı
    for (final t in tasks) {
      void d(String at, String by) {
        t.done = true;
        t.doneAt = at;
        t.doneBy = by;
      }

      if (t.floorId == 'A0' && t.area == 'Giriş holü') d('08:20', 'Ayşe Demir');
      if (t.floorId == 'A0' && t.area == 'Resepsiyon') d('09:05', 'Ayşe Demir');
      if (t.floorId == 'A3' && t.area == 'Koridor ve merdiven') d('10:05', 'Murat Kaya');
      if (t.floorId == 'E0' && t.area == 'Koridor ve merdiven') d('12:40', 'Elif Yıldız');
      if (t.slots != null && (t.floorId == 'A0' || t.floorId == 'A3')) {
        final by = t.floorId == 'A0' ? 'Ayşe Demir' : 'Murat Kaya';
        for (var i = 0; i < 2; i++) {
          final sl = t.slots![i];
          sl.done = true;
          sl.doneAt = i == 0 ? '08:05' : '10:10';
          sl.doneBy = by;
        }
      }
    }
    staff.addAll([
      Staff('Hasan Çelik', '07:00', '17:00', <String>{}, '0532 000 00 04', 'Şef'),
      Staff('Ayşe Demir', '07:00', '15:00', {'A0', 'A1'}, '0532 000 00 01'),
      Staff('Murat Kaya', '07:00', '15:00', {'A3', 'A4'}, '0532 000 00 02'),
      Staff('Elif Yıldız', '12:00', '20:00', {'E0', 'E1'}, '0532 000 00 03'),
      Staff('Zeynep Arslan', '07:00', '15:00', {'A2'}, '0532 000 00 05'),
      Staff('Can Öztürk', '12:00', '20:00', {'E2', 'E3'}, '0532 000 00 06'),
    ]);
    staff[1].shift = 1;
    staff[2].shift = 1;
    staff[3].shift = 2;
    staff[4].shift = 1;
    staff[5].shift = 2;
    notifs.add(Notif('Tüm çalışanlar', 'Hoş geldiniz. Görev listeniz hazır.', '07:45'));
    notifs.first.read['manager'] = true;
    // Örnek mesai kayıtları
    _ot('Ayşe Demir', 2026, 3, 7, true);
    _ot('Ayşe Demir', 2026, 3, 8, true);
    _ot('Ayşe Demir', 2026, 6, 13, true);
    _ot('Ayşe Demir', 2026, 9, 12, true);
    _ot('Ayşe Demir', 2026, 10, 24, true);
    _ot('Ayşe Demir', 2026, 11, 1, true);
    _ot('Ayşe Demir', 2026, 11, 14, false);
    _ot('Murat Kaya', 2026, 1, 10, true);
    _ot('Murat Kaya', 2026, 4, 18, true);
    _ot('Murat Kaya', 2026, 7, 25, true);
    _ot('Murat Kaya', 2026, 10, 25, true);
    _ot('Murat Kaya', 2026, 11, 7, true);
    _ot('Murat Kaya', 2026, 11, 15, false);
    _ot('Elif Yıldız', 2026, 2, 14, true);
    _ot('Elif Yıldız', 2026, 5, 23, true);
    _ot('Elif Yıldız', 2026, 8, 9, true);
    _ot('Elif Yıldız', 2026, 9, 13, true);
    _ot('Elif Yıldız', 2026, 10, 24, true);
    _ot('Elif Yıldız', 2026, 11, 8, true);
    _seedHistory();
    checkLate(initial: true);
    _lateTimer = Timer.periodic(const Duration(minutes: 1), (_) => checkLate());
  }

  // --- Başarı sıralaması ---------------------------------------------------
  static const periodLabels = {'today': 'Bugün', 'month': 'Bu ay', 'year': 'Bu yıl'};

  void _seedHistory() {
    const perf = <String, (double, double)>{
      'Ayşe Demir': (0.96, 0.90),
      'Murat Kaya': (0.90, 0.80),
      'Elif Yıldız': (0.86, 0.72),
      'Zeynep Arslan': (0.93, 0.85),
      'Can Öztürk': (0.80, 0.60),
    };
    final now = DateTime.now();
    final names = perf.keys.toList();
    for (var m = 1; m <= now.month; m++) {
      final mi = m - 1;
      for (var i = 0; i < names.length; i++) {
        final assigned = m < now.month ? 170 + (mi % 3) * 5 : 6 * (now.day - 1);
        if (assigned == 0) continue;
        final v = math.min(1.0, perf[names[i]]!.$1 * (1 + ((mi * 3 + i) % 5 - 2) * 0.01));
        final done = (assigned * v).round();
        final ont = (done * perf[names[i]]!.$2).round();
        history.add(PerfMonth(now.year, m, names[i], assigned, ont, done - ont));
      }
    }
  }

  /// Bugünün sayıları: [atanan, zamanında, geç]. Atanan: sorumlu olduğu katlarda yapılmış ya da saati geçmiş turlar.
  Map<String, List<int>> _liveCounts() {
    final c = {for (final p in staff.where((p) => !p.isChief)) p.name: [0, 0, 0]};
    for (final t in tasks) {
      final own = ownersOf(t.floorId);
      void unit(bool done, String time, String? doneAt, String? doneBy, bool unlocked) {
        if (!done && !isLateFor(t, time)) return; // vakti henüz gelmedi
        for (final p in own) {
          final r = c[p.name]!;
          r[0]++;
          if (done && doneBy == p.name) {
            if (unlocked || _toMin(doneAt ?? time) <= dueMin(t, time) + lateGraceMin) {
              r[1]++;
            } else {
              r[2]++;
            }
          }
        }
      }

      if (t.slots != null) {
        for (final s in t.slots!) {
          unit(s.done, s.time, s.doneAt, s.doneBy, s.unlocked);
        }
      } else {
        unit(t.done, t.time, t.doneAt, t.doneBy, t.unlocked);
      }
    }
    return c;
  }

  /// [period]: 'today' | 'month' | 'year'. Çalışanlar puana göre sıralı döner (şef hariç).
  List<RankRow> rankings(String period) {
    final now = DateTime.now();
    final rows = <RankRow>[];
    _liveCounts().forEach((name, v) {
      var a = v[0], o = v[1], l = v[2];
      if (period != 'today') {
        for (final h in history.where((h) =>
            h.name == name && h.year == now.year && (period == 'year' || h.month == now.month))) {
          a += h.assigned;
          o += h.onTime;
          l += h.late;
        }
      }
      rows.add(RankRow(name, a, o, l));
    });
    rows.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      final d = b.onTime.compareTo(a.onTime);
      return d != 0 ? d : a.name.compareTo(b.name);
    });
    return rows;
  }

  void giveAward(String name, String period, int rank) {
    final label = periodLabels[period]!;
    awards.insert(0, Award(name, label, rank, DateTime.now()));
    send(name, 'Tebrikler! $label görev başarı sıralamasında $rank. oldun ve ödül kazandın.',
        from: 'manager');
    notifyListeners();
  }

  // --- Geciken görev uyarısı ----------------------------------------------
  /// Saati geçip bu kadar dakika içinde yapılmayan tur için bildirim gider.
  int lateGraceMin = 15;
  int lockMin = 60; // 0: kilit yok
  Timer? _lateTimer;

  /// Son teslim dakikası: görev saati ya da sorumlu personelin vardiya başlangıcı, hangisi sonraysa.
  int dueMin(Task t, String time) {
    var m = _toMin(time);
    final own = ownersOf(t.floorId);
    if (own.isNotEmpty) {
      final st = own.map((o) => _toMin(o.from)).reduce((a, b) => a < b ? a : b);
      if (st > m) m = st;
    }
    return m;
  }

  // --- Kilit: son teslimden [lockMin] dk sonra çalışan işaretleyemez; yalnızca yönetici açar ---
  bool _locked(Task t, String time, bool done, bool unlocked) {
    if (done || unlocked || lockMin <= 0) return false;
    final n = TimeOfDay.now();
    return dueMin(t, time) + lockMin <= n.hour * 60 + n.minute;
  }

  bool taskLocked(Task t) => _locked(t, t.time, t.done, t.unlocked);
  bool slotLocked(Task t, TaskSlot s) => _locked(t, s.time, s.done, s.unlocked);

  int lockedCount(String floorId) {
    var n = 0;
    for (final t in tasks.where((t) => t.floorId == floorId)) {
      if (t.slots != null) {
        n += t.slots!.where((s) => slotLocked(t, s)).length;
      } else if (taskLocked(t)) {
        n++;
      }
    }
    return n;
  }

  void _notifyUnlock(String floorId, String what) {
    for (final p in ownersOf(floorId)) {
      send(p.name, 'Yönetici kilidi açtı: $what Şimdi tamamlayabilirsin.', from: 'manager');
    }
  }

  void unlockTask(Task t) {
    t.unlocked = true;
    _notifyUnlock(t.floorId, '${floorLabel(t.floorId)} ${t.area} (${t.time}).');
    notifyListeners();
  }

  void unlockSlot(Task t, TaskSlot s) {
    s.unlocked = true;
    _notifyUnlock(t.floorId, '${floorLabel(t.floorId)} ${t.area} (${s.time}).');
    notifyListeners();
  }

  /// Bir katın kilitli tüm görev ve turlarını açar.
  void unlockFloor(String floorId) {
    final n = lockedCount(floorId);
    if (n == 0) return;
    for (final t in tasks.where((t) => t.floorId == floorId)) {
      if (t.slots != null) {
        for (final s in t.slots!) {
          if (slotLocked(t, s)) s.unlocked = true;
        }
      } else if (taskLocked(t)) {
        t.unlocked = true;
      }
    }
    _notifyUnlock(floorId, '${floorLabel(floorId)}: $n görev.');
    notifyListeners();
  }

  bool isLateFor(Task t, String time) {
    final n = TimeOfDay.now();
    return dueMin(t, time) < n.hour * 60 + n.minute;
  }

  List<Staff> ownersOf(String floorId) =>
      staff.where((p) => !p.isChief && p.floors.contains(floorId)).toList();

  /// Zamanında yapılmayan turları bulur; yönetici ve şefe (ikisi de "Yönetici" bildirimlerini görür)
  /// sorumlu personelin adıyla bildirim gönderir. Her tur için yalnızca bir kez.
  void checkLate({bool initial = false}) {
    final now = TimeOfDay.now();
    final nowMin = now.hour * 60 + now.minute;
    bool due(Task t, String time) => dueMin(t, time) + lateGraceMin <= nowMin;

    final found = <(Task, String)>[];
    for (final t in tasks) {
      if (t.slots != null) {
        for (final s in t.slots!) {
          if (!s.done && !s.lateSent && due(t, s.time)) {
            s.lateSent = true;
            found.add((t, s.time));
          }
        }
      } else if (!t.done && !t.lateSent && due(t, t.time)) {
        t.lateSent = true;
        found.add((t, t.time));
      }
    }
    if (found.isEmpty) return;

    String who(Task t) {
      final o = ownersOf(t.floorId);
      return o.isEmpty ? 'atanmamış' : o.map((p) => p.name).join(', ');
    }

    if (found.length > 3) {
      final counts = <String, int>{};
      for (final (t, _) in found) {
        final o = ownersOf(t.floorId);
        for (final name in o.isEmpty ? ['Sorumlusuz'] : o.map((p) => p.name)) {
          counts[name] = (counts[name] ?? 0) + 1;
        }
      }
      send(
          'Yönetici',
          '${found.length} görev zamanında yapılmadı: '
          '${counts.entries.map((e) => '${e.key} (${e.value})').join(', ')}.',
          from: 'system',
          sound: !initial);
    } else {
      for (final (t, time) in found) {
        send('Yönetici',
            'Gecikti: ${floorLabel(t.floorId)} ${t.area} ($time) yapılmadı. Sorumlu: ${who(t)}.',
            from: 'system', sound: !initial);
      }
    }
    notifyListeners();
  }

  void _ot(String name, int y, int m, int d, bool done) {
    overtime.add(Overtime(++_otSeq, name, DateTime(y, m, d), done));
  }

  Task _task(String floorId, String area, String title, String time, List<String> items,
      {int perDay = 1}) {
    final t = Task(
        id: ++_taskSeq,
        floorId: floorId,
        area: area,
        title: title,
        time: time,
        items: items,
        perDay: perDay);
    tasks.add(t);
    return t;
  }

  Floor? floorById(String id) {
    for (final f in floors) {
      if (f.id == id) return f;
    }
    return null;
  }

  String floorLabel(String id) => floorById(id)?.label ?? 'Silinmiş kat';
  String floorShort(String id) => floorById(id)?.short ?? 'Silinmiş kat';

  List<Task> tasksOf(Set<String> floorIds) =>
      tasks.where((t) => floorIds.contains(t.floorId)).toList();

  Floor addFloor(String buildingId, String name) {
    final f = Floor('$buildingId${_floorSeq++}', buildingId, name);
    final last = floors.lastIndexWhere((x) => x.buildingId == buildingId);
    floors.insert(last >= 0 ? last + 1 : floors.length, f);
    notifyListeners();
    return f;
  }

  // --- Yönetici tanımları: vardiya, ayar, düzenleme -----------------------
  Shift? shiftById(int id) {
    for (final s in shifts) {
      if (s.id == id) return s;
    }
    return null;
  }

  void addShift(String name, String from, String to) {
    shifts.add(Shift(++_shiftSeq, name, from, to));
    notifyListeners();
  }

  /// Vardiya saati değişince o vardiyadaki herkesin saati güncellenir ve bildirim gider.
  void updateShift(Shift s, String name, String from, String to) {
    s.name = name;
    s.from = from;
    s.to = to;
    for (final p in staff.where((p) => p.shift == s.id)) {
      p.from = from;
      p.to = to;
      send(p.name, 'Vardiya güncellendi: $name $from–$to.', from: 'manager');
    }
    notifyListeners();
  }

  void removeShift(Shift s) {
    for (final p in staff.where((p) => p.shift == s.id)) {
      p.shift = 0; // saati korunur, "özel saat" olur
    }
    shifts.remove(s);
    notifyListeners();
  }

  void saveSettings(int grace, int lock, String from, String to) {
    lateGraceMin = grace.clamp(0, 120).toInt();
    lockMin = lock.clamp(0, 720).toInt();
    if (_toMin(to) > _toMin(from)) {
      slotFrom = from;
      slotTo = to;
    }
    notifyListeners();
  }

  void renameFloor(Floor f, String name) {
    final old = f.label;
    f.name = name;
    for (final p in staff.where((p) => p.floors.contains(f.id))) {
      send(p.name, 'Kat adı güncellendi: $old → ${f.label}.', from: 'manager');
    }
    notifyListeners();
  }

  void addBuilding(String name) {
    buildings.add(Building('N${++_bldSeq}', name, name.split(' ').first));
    notifyListeners();
  }

  void updateTask(Task t, String area, String time, int perDay) {
    final changes = <String>[];
    if (area != t.area) {
      t.area = area;
      changes.add('alan adı $area');
    }
    if (perDay != t.total) {
      if (perDay > 1) {
        t.slots = [for (final x in slotTimes(perDay)) TaskSlot(x)];
        t.time = t.slots!.first.time;
      } else {
        t.slots = null;
        t.time = time;
      }
      t.done = false;
      t.doneAt = null;
      t.doneBy = null;
      t.lateSent = false;
      changes.add(perDay > 1
          ? 'günde $perDay kez (${slotTimes(perDay).join(', ')})'
          : 'günde 1 kez, saat $time');
    } else if (t.slots == null && time != t.time) {
      t.time = time;
      t.lateSent = false;
      changes.add('saat $time');
    }
    tasks.sort((a, b) => a.time.compareTo(b.time));
    if (changes.isNotEmpty) {
      final msg = 'Görev güncellendi: ${floorLabel(t.floorId)} ${t.area} — ${changes.join('; ')}.';
      for (final p in staff.where((p) => p.floors.contains(t.floorId))) {
        send(p.name, msg, from: 'manager');
      }
    }
    notifyListeners();
  }

  void removeFloor(String id) {
    floors.removeWhere((f) => f.id == id);
    for (final p in staff) {
      p.floors.remove(id);
    }
    notifyListeners();
  }

  void addTask(String floorId, String area, String time, [int perDay = 1]) {
    _task(floorId, area, 'Genel temizlik', time,
        ['Zemini temizle', 'Yüzeyleri sil', 'Çöpü boşalt'],
        perDay: perDay);
    tasks.sort((a, b) => a.time.compareTo(b.time));
    final msg = perDay > 1
        ? 'Yeni görev: ${floorLabel(floorId)} $area, günde $perDay kez (${slotTimes(perDay).join(', ')}).'
        : 'Yeni görev: ${floorLabel(floorId)} $area, saat $time.';
    for (final p in staff.where((p) => p.floors.contains(floorId))) {
      send(p.name, msg, from: 'manager');
    }
    notifyListeners();
  }

  void removeTask(int id) {
    tasks.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  void toggleItem(Task t, int i, bool v) {
    if (taskLocked(t)) return;
    t.checked[i] = v;
    notifyListeners();
  }

  void complete(Task t, Staff who) {
    if (t.done || taskLocked(t)) return;
    t.done = true;
    t.doneAt = nowStr();
    t.doneBy = who.name;
    send('Yönetici', '${who.name}, ${floorLabel(t.floorId)} ${t.area} temizliğini tamamladı.',
        from: 'worker');
    notifyListeners();
  }

  /// Günde birden fazla yapılan görevin bir turunu tamamlar.
  void completeSlot(Task t, int i, Staff who) {
    final s = t.slots![i];
    if (s.done || slotLocked(t, s)) return;
    s.done = true;
    s.doneAt = nowStr();
    s.doneBy = who.name;
    final n = t.doneCount;
    if (n == t.total) {
      t.done = true;
      t.doneAt = s.doneAt;
      t.doneBy = who.name;
    }
    send(
        'Yönetici',
        '${who.name}, ${floorLabel(t.floorId)} ${t.area} temizliğini tamamladı ($n/${t.total}, ${s.time} turu).',
        from: 'worker');
    notifyListeners();
  }

  void addStaff(String name, String phone, String from, String to, Set<String> floors,
      String role, [int shiftId = 0]) {
    final np = Staff(name, from, to, floors, phone, role)..shift = shiftId;
    staff.add(np);
    send(
        name,
        role == 'Şef'
            ? 'Şef olarak ekibe eklendin. Tüm katları ve ekibi görebilirsin. Vardiyan $from–$to.'
            : 'Ekibe eklendin. Vardiyan $from–$to, sorumlu kat sayın ${floors.length}.',
        from: 'manager');
    notifyListeners();
  }

  void updateStaff(
      Staff p, String phone, String from, String to, Set<String> floors, String role,
      [int shiftId = 0]) {
    p.phone = phone;
    final changes = <String>[];
    if (role != p.role) changes.add('rolün $role olarak güncellendi');
    if (from != p.from || to != p.to) changes.add('vardiyan $from–$to olarak güncellendi');
    final a = (p.floors.toList()..sort()).join(',');
    final b = (floors.toList()..sort()).join(',');
    if (role != 'Şef' && a != b) {
      changes.add(
          'sorumlu katların: ${floors.isEmpty ? 'yok' : floors.map(floorShort).join(', ')}');
    }
    p.shift = shiftId;
    p.from = from;
    p.to = to;
    p.floors = floors;
    p.role = role;
    if (changes.isNotEmpty) send(p.name, 'Değişiklik: ${changes.join('; ')}.', from: 'manager');
    notifyListeners();
  }

  void send(String to, String text, {required String from, bool sound = true}) {
    final n = Notif(to, text, nowStr());
    n.read[from] = true;
    notifs.insert(0, n);
    if (sound) playAlert();
    notifyListeners();
  }

  List<Notif> visible(String role, Staff? me) {
    if (role == 'manager') return notifs.where((n) => n.to == 'Yönetici').toList();
    if (role == 'chief') {
      return notifs
          .where((n) => n.to == 'Yönetici' || n.to == 'Tüm çalışanlar' || n.to == me?.name)
          .toList();
    }
    return notifs.where((n) => n.to == 'Tüm çalışanlar' || n.to == me?.name).toList();
  }

  int unread(String role, Staff? me) => visible(role, me).where((n) => !n.read[role]!).length;

  void markRead(String role, Staff? me) {
    for (final n in visible(role, me)) {
      n.read[role] = true;
    }
    notifyListeners();
  }

  // --- Roller -------------------------------------------------------------
  List<Staff> get workers => staff.where((p) => !p.isChief).toList();
  List<Staff> get chiefs => staff.where((p) => p.isChief).toList();

  // --- Hafta sonu mesaisi -------------------------------------------------
  List<Overtime> overtimeOf(String name) => overtime.where((o) => o.name == name).toList();

  void assignOvertime(String name, DateTime date) {
    final o = Overtime(++_otSeq, name, date, false);
    overtime.add(o);
    send(name, 'Hafta sonu mesaisi: ${dateLabel(date)} (${fmtHours(o.hours)}).',
        from: 'manager');
    notifyListeners();
  }

  void cancelOvertime(int id) {
    overtime.removeWhere((o) => o.id == id);
    notifyListeners();
  }

  void completeOvertime(Overtime o) {
    o.done = true;
    send('Yönetici',
        '${o.name}, ${dateLabel(o.date)} mesaisini tamamladı (${fmtHours(o.hours)}).',
        from: 'worker');
    notifyListeners();
  }

  List<int> overtimeYears() {
    final years = <int>{DateTime.now().year, ...overtime.map((o) => o.date.year)};
    return years.toList()..sort();
  }

  /// [month] null ise yıllık rapor.
  List<OtRow> overtimeReport(int year, int? month) {
    return staff.map((p) {
      final l = overtime
          .where((o) =>
              o.name == p.name && o.date.year == year && (month == null || o.date.month == month))
          .toList();
      final done = l.where((o) => o.done);
      final plan = l.where((o) => !o.done);
      return OtRow(p.name, done.fold(0.0, (a, o) => a + o.hours), done.length,
          plan.fold(0.0, (a, o) => a + o.hours));
    }).toList();
  }

  double monthlyDoneHours(int year, int month) => overtime
      .where((o) => o.done && o.date.year == year && o.date.month == month)
      .fold(0.0, (a, o) => a + o.hours);
}

// ---------------------------------------------------------------------------
// Uygulama
// ---------------------------------------------------------------------------
class TemizlikApp extends StatelessWidget {
  const TemizlikApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Temizlik Takip',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0B7A75), useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF0B7A75),
          brightness: Brightness.dark,
          useMaterial3: true),
      home: const RoleScreen(),
    );
  }
}

final AppState app = AppState();

class RoleScreen extends StatefulWidget {
  const RoleScreen({super.key});
  @override
  State<RoleScreen> createState() => _RoleScreenState();
}

class _RoleScreenState extends State<RoleScreen> {
  Staff? worker, chief;

  Widget _personCard(
    BuildContext context, {
    required String title,
    required String empty,
    required List<Staff> people,
    required Staff? value,
    required ValueChanged<Staff?> onChanged,
    required String button,
    required Widget Function(Staff) screen,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            if (people.isEmpty)
              Text(empty)
            else ...[
              DropdownButtonFormField<Staff>(
                key: ValueKey(value?.name),
                initialValue: value,
                decoration: const InputDecoration(labelText: 'Kişi'),
                items: [for (final p in people) DropdownMenuItem(value: p, child: Text(p.name))],
                onChanged: onChanged,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: value == null
                    ? null
                    : () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => screen(value))),
                child: Text(button),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: app,
          builder: (context, _) {
            final workers = app.workers, chiefs = app.chiefs;
            final w = workers.contains(worker) ? worker : (workers.isEmpty ? null : workers.first);
            final c = chiefs.contains(chief) ? chief : (chiefs.isEmpty ? null : chiefs.first);
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const SizedBox(height: 24),
                Text('Temizlik Takip', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 6),
                const Text('Ana bina 5 kat, ek bina 4 kat. Görev, vardiya, mesai ve bildirim takibi.'),
                const SizedBox(height: 28),
                Card(
                  child: ListTile(
                    title: const Text('Yönetici olarak gir'),
                    subtitle: const Text('Kat, görev, personel, rol, vardiya ve mesai yönetimi'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => const ManagerScreen())),
                  ),
                ),
                _personCard(
                  context,
                  title: 'Şef olarak gir',
                  empty: 'Şef tanımlı değil. Yönetici bir personele Şef rolü verebilir.',
                  people: chiefs,
                  value: c,
                  onChanged: (p) => setState(() => chief = p),
                  button: 'Tüm katları gör',
                  screen: (p) => ChiefScreen(staff: p),
                ),
                _personCard(
                  context,
                  title: 'Çalışan olarak gir',
                  empty: 'Çalışan tanımlı değil.',
                  people: workers,
                  value: w,
                  onChanged: (p) => setState(() => worker = p),
                  button: 'Görevlerimi aç',
                  screen: (p) => WorkerScreen(staff: p),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Bu sürümde veriler telefonda bellekte tutulur. Sonraki adımda Firebase ile '
                  'bağlanınca tüm cihazlarda ortak olacak.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Çalışan ekranı
// ---------------------------------------------------------------------------
class WorkerScreen extends StatefulWidget {
  final Staff staff;
  const WorkerScreen({super.key, required this.staff});
  @override
  State<WorkerScreen> createState() => _WorkerScreenState();
}

class _WorkerScreenState extends State<WorkerScreen> {
  int tab = 0;
  @override
  Widget build(BuildContext context) {
    final me = widget.staff;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final unread = app.unread('worker', me);
        return Scaffold(
          appBar: AppBar(
            title: Text(const ['Bugünkü görevlerim', 'Bildirimler', 'Hafta sonu mesaim'][tab]),
            actions: [
              IconButton(
                icon: const Icon(Icons.call),
                tooltip: 'Yöneticiyi ara',
                onPressed: () => callPhone(context, managerPhone),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(28),
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('${me.name} · ${me.from}–${me.to}')),
              ),
            ),
          ),
          body: tab == 0
              ? _today(context, me)
              : tab == 1
                  ? _notifs(me)
                  : WorkerOvertimeView(me: me),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) {
              setState(() => tab = i);
              if (i == 1) app.markRead('worker', me);
            },
            destinations: [
              const NavigationDestination(icon: Icon(Icons.checklist), label: 'Bugün'),
              NavigationDestination(
                icon: Badge(
                    isLabelVisible: unread > 0,
                    label: Text('$unread'),
                    child: const Icon(Icons.notifications_outlined)),
                label: 'Bildirimler',
              ),
              const NavigationDestination(icon: Icon(Icons.event_available), label: 'Mesai'),
            ],
          ),
        );
      },
    );
  }

  Widget _today(BuildContext context, Staff me) {
    final mine = app.tasksOf(me.floors);
    final done = unitsDone(mine);
    final total = unitsTotal(mine);
    if (mine.isEmpty) {
      return const Center(
          child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('Sana henüz kat atanmadı. Yönetici sorumlu kat ekleyebilir.',
            textAlign: TextAlign.center),
      ));
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const QuoteCard(),
        TopThreeCard(me: me),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Tamamlanan görevler: $done/$total',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: done / total),
            ]),
          ),
        ),
        for (final f in app.floors.where((f) => me.floors.contains(f.id))) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
            child: Text(f.label.toUpperCase(), style: Theme.of(context).textTheme.labelMedium),
          ),
          for (final t in mine.where((t) => t.floorId == f.id)) _taskCard(context, t, me),
        ],
      ],
    );
  }

  Widget _slotCard(BuildContext context, Task t, Staff me) {
    final slots = t.slots!;
    final next = slots.indexWhere((s) => !s.done);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.area, style: Theme.of(context).textTheme.titleMedium),
                Text('${t.title} · günde ${slots.length} kez'),
              ]),
            ),
            Chip(label: Text('${t.doneCount}/${t.total}'), visualDensity: VisualDensity.compact),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var i = 0; i < slots.length; i++)
              if (slots[i].done)
                Chip(
                    avatar: const Icon(Icons.check, size: 16),
                    label: Text(slots[i].time),
                    visualDensity: VisualDensity.compact)
              else if (app.slotLocked(t, slots[i]))
                Chip(
                    avatar: const Icon(Icons.lock, size: 16),
                    label: Text(slots[i].time),
                    visualDensity: VisualDensity.compact)
              else if (i == next)
                FilledButton(
                    onPressed: () => _doSlot(context, t, i, me), child: Text(slots[i].time))
              else
                OutlinedButton(
                    onPressed: () => _doSlot(context, t, i, me), child: Text(slots[i].time)),
          ]),
          const SizedBox(height: 8),
          Text(
              'Temizleyince saate dokun. Saatinden ${app.lockMin} dk sonra tur kilitlenir, kilidi yalnızca yönetici açar. Kontrol: ${t.items.join(', ')}.',
              style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }

  void _doSlot(BuildContext context, Task t, int i, Staff me) {
    if (app.slotLocked(t, t.slots![i])) {
      toast(context, 'Süre doldu, bu bölüm kilitlendi. Yöneticiyle görüşün.');
      return;
    }
    app.completeSlot(t, i, me);
    toast(context, 'Yönetici ve şefe bildirim gönderildi.');
  }

  Widget _taskCard(BuildContext context, Task t, Staff me) {
    if (t.slots != null) return _slotCard(context, t, me);
    if (t.done) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.check_circle, color: Colors.green),
          title: Text(t.area, style: const TextStyle(decoration: TextDecoration.lineThrough)),
          subtitle: Text('Tamamlandı · ${t.doneAt}'),
        ),
      );
    }
    if (app.taskLocked(t)) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.lock, color: Colors.red),
          title: Text(t.area),
          subtitle: Text(
              '${t.time} · Süre doldu, bu bölüm kilitlendi. Kilidi yalnızca yönetici açar; yöneticiyle görüşün.'),
        ),
      );
    }
    final all = t.checked.every((c) => c);
    return Card(
      child: ExpansionTile(
        key: PageStorageKey('task${t.id}'),
        leading: Text(t.time, style: const TextStyle(fontWeight: FontWeight.w600)),
        title: Text(t.area),
        subtitle: Text(t.title),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        children: [
          for (var i = 0; i < t.items.length; i++)
            CheckboxListTile(
              dense: true,
              value: t.checked[i],
              title: Text(t.items[i]),
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (v) => app.toggleItem(t, i, v ?? false),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: all
                    ? () {
                        app.complete(t, me);
                        toast(context, 'Yönetici ve şefe bildirim gönderildi.');
                      }
                    : null,
                child: const Text('Tamamlandı'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _notifs(Staff me) {
    final list = app.visible('worker', me);
    if (list.isEmpty) return const Center(child: Text('Henüz bildirim yok.'));
    return ListView(
      children: [
        for (final n in list)
          ListTile(
            title: Text(n.text),
            trailing: Text(n.time),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Yönetici ekranı (tam yetki)
// ---------------------------------------------------------------------------
class ManagerScreen extends StatefulWidget {
  const ManagerScreen({super.key});
  @override
  State<ManagerScreen> createState() => _ManagerScreenState();
}

class _ManagerScreenState extends State<ManagerScreen> {
  int tab = 0;
  String defFilter = 'all'; // all | open | done
  static const titles = [
    'Genel durum',
    'Kat ve görev tanımları',
    'Personel ve vardiya',
    'Bildirimler',
    'Mesai ve rapor',
    'Başarı raporu'
  ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final unread = app.unread('manager', null);
        return Scaffold(
          appBar: AppBar(
            title: Text(titles[tab]),
            actions: const [
              Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: Chip(label: Text('Tam yetki'), visualDensity: VisualDensity.compact)),
            ],
          ),
          body: [_board, _defs, _people, _notifs, _mesai, _report][tab](context),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) {
              setState(() => tab = i);
              if (i == 3) app.markRead('manager', null);
            },
            destinations: [
              const NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Pano'),
              const NavigationDestination(icon: Icon(Icons.apartment), label: 'Görevler'),
              const NavigationDestination(icon: Icon(Icons.groups_outlined), label: 'Personel'),
              NavigationDestination(
                icon: Badge(
                    isLabelVisible: unread > 0,
                    label: Text('$unread'),
                    child: const Icon(Icons.notifications_outlined)),
                label: 'Bildirim',
              ),
              const NavigationDestination(icon: Icon(Icons.event_available), label: 'Mesai'),
              const NavigationDestination(icon: Icon(Icons.emoji_events_outlined), label: 'Rapor'),
            ],
          ),
        );
      },
    );
  }

  // Pano, mesai ve bildirimler şef ekranıyla ortak görünümlerdir.
  Widget _board(BuildContext context) => const BoardView();
  Widget _mesai(BuildContext context) => const OvertimeManagerView();
  Widget _report(BuildContext context) => const ReportView(canAward: true);
  Widget _notifs(BuildContext context) => const NotifsPanel(role: 'manager');

  // Görevler: kim hangi görevi yaptı, hangisi yapılmadı + kat ve görev tanımları
  Widget _statusChip(String label, Color c) => Chip(
        label: Text(label, style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 12)),
        backgroundColor: c.withValues(alpha: 0.12),
        side: BorderSide.none,
        visualDensity: VisualDensity.compact,
      );

  Widget _slotChip(Task t, TaskSlot s) {
    if (s.done) {
      final who = (s.doneBy ?? '').split(' ').first;
      return _statusChip('${s.time} ✓ $who', Colors.green);
    }
    if (app.slotLocked(t, s)) {
      return ActionChip(
        avatar: const Icon(Icons.lock_open, size: 16),
        label: Text('${s.time} · kilidi aç'),
        visualDensity: VisualDensity.compact,
        onPressed: () {
          app.unlockSlot(t, s);
          toast(context, 'Kilit açıldı, sorumlu personele bildirim gitti.');
        },
      );
    }
    if (s.unlocked) return _statusChip('${s.time} · açık', Colors.orange);
    return _statusChip(s.time, app.isLateFor(t, s.time) ? Colors.red : Colors.grey);
  }

  Widget _taskStatusTile(BuildContext context, Task t) {
    final Widget status;
    if (t.slots != null) {
      status = Wrap(spacing: 6, runSpacing: 4, children: [
        for (final s in t.slots!) _slotChip(t, s),
      ]);
    } else {
      final late = !t.done && app.isLateFor(t, t.time);
      final label = t.done ? 'Yapıldı' : (late ? 'Gecikti' : 'Bekliyor');
      final color = t.done ? Colors.green : (late ? Colors.red : Colors.orange);
      final detail = t.done ? '${t.doneBy ?? ''} · ${t.doneAt ?? ''}' : t.time;
      final locked = app.taskLocked(t);
      status = Row(children: [
        _statusChip(label, color),
        const SizedBox(width: 8),
        Flexible(child: Text(detail, style: const TextStyle(fontSize: 12))),
        if (locked)
          TextButton.icon(
            onPressed: () {
              app.unlockTask(t);
              toast(context, 'Kilit açıldı, sorumlu personele bildirim gitti.');
            },
            icon: const Icon(Icons.lock_open, size: 16),
            label: const Text('Kilidi aç'),
          )
        else if (t.unlocked && !t.done)
          _statusChip('Kilidi açık', Colors.orange),
      ]);
    }
    return ListTile(
      title: Text(t.area),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.slots != null ? '${t.title} · günde ${t.total} kez' : t.title),
        const SizedBox(height: 4),
        status,
      ]),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'Görevi düzenle',
          onPressed: () => _taskEditDialog(context, t),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Görevi sil',
          onPressed: () => app.removeTask(t.id),
        ),
      ]),
    );
  }

  List<Widget> _floorSection(BuildContext context, Floor f) {
    final all = app.tasks.where((t) => t.floorId == f.id).toList();
    final shown = all.where((t) {
      if (defFilter == 'all') return true;
      return defFilter == 'open' ? t.doneCount < t.total : t.doneCount == t.total;
    }).toList();
    if (defFilter != 'all' && shown.isEmpty) return const [];
    final owners = app.staff
        .where((p) => p.floors.contains(f.id))
        .map((p) => p.name.split(' ').first)
        .join(', ');
    final progress = all.isEmpty ? '' : ' · ${unitsDone(all)}/${unitsTotal(all)}';
    final ownerText = owners.isEmpty ? 'atanmamış' : owners;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 0, 0),
        child: Row(children: [
          Expanded(
            child: Text('${f.label.toUpperCase()}$progress',
                style: Theme.of(context).textTheme.labelMedium),
          ),
          if (app.lockedCount(f.id) > 0)
            TextButton.icon(
              onPressed: () {
                final n = app.lockedCount(f.id);
                app.unlockFloor(f.id);
                toast(context, '$n görevin kilidi açıldı, sorumlu personele bildirim gitti.');
              },
              icon: const Icon(Icons.lock_open, size: 16),
              label: Text('Kilitleri aç (${app.lockedCount(f.id)})'),
            ),
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: 'Kat adını değiştir',
            onPressed: () => _floorRenameDialog(context, f),
          ),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
        child: Text('Sorumlu: $ownerText', style: const TextStyle(fontSize: 12)),
      ),
      Card(
        child: Column(children: [
          for (final t in shown) _taskStatusTile(context, t),
          if (all.isEmpty)
            ListTile(
              title: const Text('Bu katta görev yok.'),
              trailing: TextButton(
                  onPressed: () => app.removeFloor(f.id), child: const Text('Katı sil')),
            ),
        ]),
      ),
    ];
  }

  Widget _defs(BuildContext context) {
    var done = 0, late = 0, wait = 0;
    for (final t in app.tasks) {
      final turns = t.slots != null
          ? [for (final s in t.slots!) (s.done, s.time)]
          : [(t.done, t.time)];
      for (final (d, time) in turns) {
        if (d) {
          done++;
        } else if (app.isLateFor(t, time)) {
          late++;
        } else {
          wait++;
        }
      }
    }
    final all = done + late + wait;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Bugün yapılan: $done/$all', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: all == 0 ? 0 : done / all),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                _statusChip('$done yapıldı', Colors.green),
                _statusChip('$late gecikti', Colors.red),
                _statusChip('$wait bekliyor', Colors.orange),
              ]),
            ]),
          ),
        ),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'all', label: Text('Tümü')),
            ButtonSegment(value: 'open', label: Text('Yapılmayan')),
            ButtonSegment(value: 'done', label: Text('Yapılan')),
          ],
          selected: {defFilter},
          onSelectionChanged: (v) => setState(() => defFilter = v.first),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
              child: FilledButton.icon(
                  onPressed: () => _floorDialog(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Kat tanımla'))),
          const SizedBox(width: 8),
          Expanded(
              child: FilledButton.tonalIcon(
                  onPressed: app.floors.isEmpty ? null : () => _taskDialog(context),
                  icon: const Icon(Icons.add_task),
                  label: const Text('Görev ekle'))),
        ]),
        const SizedBox(height: 8),
        OutlinedButton.icon(
            onPressed: () => _buildingDialog(context),
            icon: const Icon(Icons.domain_add),
            label: const Text('Bina ekle')),
        for (final f in app.floors) ..._floorSection(context, f),
      ],
    );
  }

  Future<void> _floorDialog(BuildContext context) async {
    var bid = buildings.first.id;
    final nameC = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Kat tanımla'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: bid,
              decoration: const InputDecoration(labelText: 'Bina'),
              items: [for (final b in buildings) DropdownMenuItem(value: b.id, child: Text(b.name))],
              onChanged: (v) => setS(() => bid = v ?? bid),
            ),
            TextField(
                controller: nameC,
                decoration: const InputDecoration(labelText: 'Kat adı', hintText: 'Örn. 5. Kat')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
            FilledButton(
              onPressed: () {
                final n = nameC.text.trim();
                if (n.isEmpty) return;
                final f = app.addFloor(bid, n);
                Navigator.pop(ctx);
                toast(context, '${f.label} eklendi.');
              },
              child: const Text('Kat ekle'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _taskDialog(BuildContext context) async {
    var floorId = app.floors.first.id;
    var time = '15:00';
    var perDay = 1;
    final areaC = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Yeni görev'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: areaC,
                decoration: const InputDecoration(labelText: 'Alan', hintText: 'Örn. Arşiv odası')),
            DropdownButtonFormField<String>(
              initialValue: floorId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Kat'),
              items: [for (final f in app.floors) DropdownMenuItem(value: f.id, child: Text(f.label))],
              onChanged: (v) => setS(() => floorId = v ?? floorId),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () async {
                final t = await showTimePicker(context: ctx, initialTime: parseTime(time));
                if (t != null) setS(() => time = fmtTime(t));
              },
              child: Text(perDay > 1 ? 'Saat: otomatik' : 'Saat: $time'),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: perDay,
              decoration: InputDecoration(
                  labelText: 'Günde kaç kez',
                  helperText: 'Birden fazlaysa saatler $slotFrom–$slotTo arasına eşit dağıtılır'),
              items: [for (var n = 1; n <= 12; n++) DropdownMenuItem(value: n, child: Text('$n'))],
              onChanged: (v) => setS(() => perDay = v ?? perDay),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
            FilledButton(
              onPressed: () {
                final a = areaC.text.trim();
                if (a.isEmpty) return;
                app.addTask(floorId, a, time, perDay);
                Navigator.pop(ctx);
                toast(context, 'Görev eklendi, sorumlu personele bildirim gitti.');
              },
              child: const Text('Ekle ve ata'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _shiftDialog(BuildContext context, {Shift? edit}) async {
    final nameC = TextEditingController(text: edit?.name ?? '');
    var from = edit?.from ?? '08:00';
    var to = edit?.to ?? '16:00';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(edit == null ? 'Yeni vardiya' : 'Vardiyayı düzenle'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: nameC,
                decoration:
                    const InputDecoration(labelText: 'Vardiya adı', hintText: 'Örn. Akşam vardiyası')),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final t = await showTimePicker(context: ctx, initialTime: parseTime(from));
                    if (t != null) setS(() => from = fmtTime(t));
                  },
                  child: Text('İşe başlama $from'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final t = await showTimePicker(context: ctx, initialTime: parseTime(to));
                    if (t != null) setS(() => to = fmtTime(t));
                  },
                  child: Text('Bitiş $to'),
                ),
              ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
            FilledButton(
              onPressed: () {
                final n = nameC.text.trim();
                if (n.isEmpty) return;
                if (edit == null) {
                  app.addShift(n, from, to);
                  toast(context, '$n eklendi.');
                } else {
                  app.updateShift(edit, n, from, to);
                  toast(context, 'Vardiya güncellendi, vardiyadaki personele bildirim gitti.');
                }
                Navigator.pop(ctx);
              },
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _settingsDialog(BuildContext context) async {
    final graceC = TextEditingController(text: '${app.lateGraceMin}');
    final lockC = TextEditingController(text: '${app.lockMin}');
    var from = slotFrom;
    var to = slotTo;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Ayarlar'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: graceC,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Gecikme bildirimi (dk)',
                    helperText: 'Görev saatinden kaç dakika sonra yöneticiye ve şefe bildirim gitsin (0–120)')),
            const SizedBox(height: 12),
            TextField(
                controller: lockC,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Kilit süresi (dk)',
                    helperText: 'Görev saatinden kaç dakika sonra çalışan işaretleyemesin (0 = kilit yok, 0–720)')),
            const SizedBox(height: 12),
            const Align(
                alignment: Alignment.centerLeft,
                child: Text('Günde birden fazla görev: tur aralığı')),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final t = await showTimePicker(context: ctx, initialTime: parseTime(from));
                    if (t != null) setS(() => from = fmtTime(t));
                  },
                  child: Text('İlk tur $from'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () async {
                    final t = await showTimePicker(context: ctx, initialTime: parseTime(to));
                    if (t != null) setS(() => to = fmtTime(t));
                  },
                  child: Text('Son tur $to'),
                ),
              ),
            ]),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Tur aralığı yalnızca bundan sonra eklenen görevlerde geçerlidir.',
                  style: TextStyle(fontSize: 12)),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
            FilledButton(
              onPressed: () {
                app.saveSettings(int.tryParse(graceC.text.trim()) ?? app.lateGraceMin,
                    int.tryParse(lockC.text.trim()) ?? app.lockMin, from, to);
                Navigator.pop(ctx);
                toast(context, 'Ayarlar kaydedildi.');
              },
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _taskEditDialog(BuildContext context, Task t) async {
    final areaC = TextEditingController(text: t.area);
    var time = t.slots?.first.time ?? t.time;
    var perDay = t.total;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Görevi düzenle'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: areaC, decoration: const InputDecoration(labelText: 'Alan')),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () async {
                final x = await showTimePicker(context: ctx, initialTime: parseTime(time));
                if (x != null) setS(() => time = fmtTime(x));
              },
              child: Text(perDay > 1 ? 'Saat: otomatik' : 'Saat: $time'),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: perDay,
              decoration: const InputDecoration(
                  labelText: 'Günde kaç kez',
                  helperText: 'Tur sayısı değişirse bugünün işaretleri sıfırlanır'),
              items: [for (var n = 1; n <= 12; n++) DropdownMenuItem(value: n, child: Text('$n'))],
              onChanged: (v) => setS(() => perDay = v ?? perDay),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
            FilledButton(
              onPressed: () {
                final a = areaC.text.trim();
                if (a.isEmpty) return;
                app.updateTask(t, a, time, perDay);
                Navigator.pop(ctx);
                toast(context, 'Görev güncellendi, sorumlu personele bildirim gitti.');
              },
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _floorRenameDialog(BuildContext context, Floor f) async {
    final nameC = TextEditingController(text: f.name);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(f.label),
        content: TextField(controller: nameC, decoration: const InputDecoration(labelText: 'Kat adı')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(
            onPressed: () {
              final n = nameC.text.trim();
              if (n.isEmpty) return;
              app.renameFloor(f, n);
              Navigator.pop(ctx);
              toast(context, 'Kat adı güncellendi.');
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
  }

  Future<void> _buildingDialog(BuildContext context) async {
    final nameC = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bina ekle'),
        content: TextField(
            controller: nameC,
            decoration: const InputDecoration(labelText: 'Bina adı', hintText: 'Örn. Depo Binası')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(
            onPressed: () {
              final n = nameC.text.trim();
              if (n.isEmpty) return;
              app.addBuilding(n);
              Navigator.pop(ctx);
              toast(context, '$n eklendi. Kat tanımla ile kat ekleyebilirsiniz.');
            },
            child: const Text('Ekle'),
          ),
        ],
      ),
    );
  }

  // Personel
  Widget _people(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        FilledButton.icon(
            onPressed: () => _staffDialog(context),
            icon: const Icon(Icons.person_add_alt),
            label: const Text('Personel ekle')),
        for (final p in app.staff)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                      child: Text(p.name, style: Theme.of(context).textTheme.titleMedium)),
                  OutlinedButton(
                      onPressed: () => _staffDialog(context, edit: p),
                      child: const Text('Düzenle')),
                ]),
                const SizedBox(height: 4),
                Text('${p.role} · ${app.shiftById(p.shift)?.name ?? 'Özel saat'} · ${p.from}–${p.to}'),
                if (p.phone.isNotEmpty)
                  Row(children: [
                    Expanded(child: SelectableText(p.phone)),
                    FilledButton.tonalIcon(
                      onPressed: () => callPhone(context, p.phone),
                      icon: const Icon(Icons.call),
                      label: const Text('Ara'),
                    ),
                  ]),
                const SizedBox(height: 6),
                if (p.isChief)
                  const Text('Tüm katları görür')
                else if (p.floors.isEmpty)
                  const Text('Sorumlu kat yok')
                else
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final id in p.floors)
                      Chip(
                          label: Text(app.floorShort(id)),
                          visualDensity: VisualDensity.compact),
                  ]),
              ]),
            ),
          ),
        const Padding(padding: EdgeInsets.fromLTRB(4, 16, 4, 6), child: Text('Vardiyalar')),
        for (final sh in app.shifts)
          Card(
            child: ListTile(
              title: Text(sh.name),
              subtitle: Text(
                  '${sh.from}–${sh.to} · ${app.staff.where((p) => p.shift == sh.id).length} kişi'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: 'Düzenle',
                    onPressed: () => _shiftDialog(context, edit: sh)),
                IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Sil',
                    onPressed: () => app.removeShift(sh)),
              ]),
            ),
          ),
        OutlinedButton.icon(
            onPressed: () => _shiftDialog(context),
            icon: const Icon(Icons.add),
            label: const Text('Vardiya ekle')),
        const Padding(padding: EdgeInsets.fromLTRB(4, 16, 4, 6), child: Text('Ayarlar')),
        Card(
          child: ListTile(
            title: const Text('Gecikme bildirimi ve tur aralığı'),
            subtitle: Text(
                'Görev saatinden ${app.lateGraceMin} dk sonra bildirim · ${app.lockMin == 0 ? 'Kilit yok' : '${app.lockMin} dk sonra kilit'} · Günde birden fazla görev: $slotFrom–$slotTo'),
            trailing: IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Düzenle',
                onPressed: () => _settingsDialog(context)),
          ),
        ),
        const Padding(
            padding: EdgeInsets.fromLTRB(4, 16, 4, 6), child: Text('Rol yetkileri')),
        const Card(
          child: Column(children: [
            ListTile(
              title: Text('Çalışan'),
              subtitle: Text(
                  'Yalnızca kendi sorumlu katlarının görevlerini, kendi mesaisini ve bildirimlerini görür. Görevi tamamlar, mesaiyi onaylar.'),
            ),
            ListTile(
              title: Text('Şef'),
              subtitle: Text(
                  'Tüm katları, tüm personeli, görev durumlarını ve mesai raporunu görür. Personeli arar, mesaj gönderir. Kat, görev, personel ve mesai ataması yapamaz.'),
            ),
            ListTile(
              title: Text('Yönetici'),
              subtitle:
                  Text('Her şeyi görür. Kat, görev, personel, vardiya, rol ve mesai tanımlar.'),
            ),
          ]),
        ),
      ],
    );
  }

  Future<void> _staffDialog(BuildContext context, {Staff? edit}) async {
    final nameC = TextEditingController(text: edit?.name ?? '');
    final phoneC = TextEditingController(text: edit?.phone ?? '');
    var shiftId = edit?.shift ?? (app.shifts.isEmpty ? 0 : app.shifts.first.id);
    var from = edit?.from ?? app.shiftById(shiftId)?.from ?? '08:00';
    var to = edit?.to ?? app.shiftById(shiftId)?.to ?? '16:00';
    var role = edit?.role ?? 'Çalışan';
    final sel = <String>{...(edit?.floors ?? <String>{})};
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(edit == null ? 'Yeni personel' : edit.name),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (edit == null)
                TextField(controller: nameC, decoration: const InputDecoration(labelText: 'Ad soyad')),
              TextField(
                  controller: phoneC,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Telefon', hintText: '05xx xxx xx xx')),
              DropdownButtonFormField<String>(
                initialValue: role,
                decoration: const InputDecoration(labelText: 'Rol'),
                items: const [
                  DropdownMenuItem(value: 'Çalışan', child: Text('Çalışan')),
                  DropdownMenuItem(value: 'Şef', child: Text('Şef')),
                ],
                onChanged: (v) => setS(() => role = v ?? role),
              ),
              if (role == 'Şef')
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Şef tüm katları ve tüm personeli görür; kat seçmeye gerek yok.',
                      style: TextStyle(fontSize: 12)),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: shiftId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Vardiya'),
                items: [
                  for (final sh in app.shifts)
                    DropdownMenuItem(value: sh.id, child: Text('${sh.name} (${sh.from}–${sh.to})')),
                  const DropdownMenuItem(value: 0, child: Text('Özel saat')),
                ],
                onChanged: (v) => setS(() {
                  shiftId = v ?? shiftId;
                  final sh = app.shiftById(shiftId);
                  if (sh != null) {
                    from = sh.from;
                    to = sh.to;
                  }
                }),
              ),
              if (shiftId == 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final t =
                              await showTimePicker(context: ctx, initialTime: parseTime(from));
                          if (t != null) setS(() => from = fmtTime(t));
                        },
                        child: Text('Başlama $from'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final t = await showTimePicker(context: ctx, initialTime: parseTime(to));
                          if (t != null) setS(() => to = fmtTime(t));
                        },
                        child: Text('Bitiş $to'),
                      ),
                    ),
                  ]),
                ),
              const SizedBox(height: 12),
              if (role != 'Şef') const Text('Sorumlu katlar'),
              if (role != 'Şef')
              for (final b in buildings) ...[
                Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(b.name, style: Theme.of(ctx).textTheme.labelMedium)),
                Wrap(spacing: 6, children: [
                  for (final f in app.floors.where((f) => f.buildingId == b.id))
                    FilterChip(
                      label: Text(f.name),
                      selected: sel.contains(f.id),
                      onSelected: (v) => setS(() => v ? sel.add(f.id) : sel.remove(f.id)),
                    ),
                ]),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
            FilledButton(
              onPressed: () {
                if (edit == null) {
                  final n = nameC.text.trim();
                  if (n.isEmpty) return;
                  app.addStaff(n, phoneC.text.trim(), from, to, role == 'Şef' ? <String>{} : sel, role, shiftId);
                  toast(context, '$n ekibe eklendi.');
                } else {
                  app.updateStaff(
                      edit, phoneC.text.trim(), from, to, role == 'Şef' ? <String>{} : sel, role, shiftId);
                  toast(context, '${edit.name} için güncelleme gönderildi.');
                }
                Navigator.pop(ctx);
              },
              child: Text(edit == null ? 'Personel ekle' : 'Kaydet'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Şef ekranı: tüm katları, tüm personeli ve mesai raporunu görür (düzenleme yok)
// ---------------------------------------------------------------------------
class ChiefScreen extends StatefulWidget {
  final Staff staff;
  const ChiefScreen({super.key, required this.staff});
  @override
  State<ChiefScreen> createState() => _ChiefScreenState();
}

class _ChiefScreenState extends State<ChiefScreen> {
  int tab = 0;
  static const titles = [
    'Genel durum',
    'Ekip ve görev durumu',
    'Bildirimler',
    'Mesai raporu',
    'Başarı raporu'
  ];

  @override
  Widget build(BuildContext context) {
    final me = widget.staff;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final unread = app.unread('chief', me);
        return Scaffold(
          appBar: AppBar(
            title: Text(titles[tab]),
            actions: [
              IconButton(
                icon: const Icon(Icons.call),
                tooltip: 'Yöneticiyi ara',
                onPressed: () => callPhone(context, managerPhone),
              ),
              const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: Chip(label: Text('Tüm katlar'), visualDensity: VisualDensity.compact)),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(28),
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('${me.name} · Şef · ${me.from}–${me.to}')),
              ),
            ),
          ),
          body: switch (tab) {
            0 => const BoardView(),
            1 => TeamView(self: me),
            2 => NotifsPanel(role: 'chief', me: me),
            3 => ListView(
                padding: const EdgeInsets.all(12), children: const [OvertimeReportView()]),
            _ => const ReportView(canAward: false),
          },
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) {
              setState(() => tab = i);
              if (i == 2) app.markRead('chief', me);
            },
            destinations: [
              const NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Pano'),
              const NavigationDestination(icon: Icon(Icons.groups_outlined), label: 'Ekip'),
              NavigationDestination(
                icon: Badge(
                    isLabelVisible: unread > 0,
                    label: Text('$unread'),
                    child: const Icon(Icons.notifications_outlined)),
                label: 'Bildirim',
              ),
              const NavigationDestination(icon: Icon(Icons.event_available), label: 'Mesai'),
              const NavigationDestination(icon: Icon(Icons.emoji_events_outlined), label: 'Rapor'),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Ortak görünümler (yönetici ve şef kullanır)
// ---------------------------------------------------------------------------
/// Günün sözü: yılın gününe göre her gün farklı.
const dailyQuotes = [
  'Temiz bir yer, temiz bir zihnin aynasıdır.',
  'Düzen küçük başlar: bir masa, bir raf, bir köşe.',
  'Temizlik imandandır.',
  'İyi iş, kimse bakmazken de aynı özenle yapılan iştir.',
  'Her parlayan yüzey, birinin emeğini anlatır.',
  'Önce hijyen, sonra güven.',
  'Bugün temizlediğin yer, yarın birinin güvenle bastığı yerdir.',
  'Küçük ayrıntılar büyük farkı yaratır.',
  'Temizlik bir görev değil, saygıdır.',
  'Sabırla silinen leke, acelecilikle yayılandan iyidir.',
  'Temiz ortam, verimli gün demektir.',
  'Emeğin görünmez olduğu yerde bile fark edilir.',
  'Bir köşeyi temizleyen, binayı değiştirir.',
  'Düzenli yapılan iş, yorulmadan biter.',
  'Temizlik bir alışkanlıktır, bir kez edinilince kolaylaşır.',
  'Herkesin geçtiği yolu en çok sen bilirsin; onu en güzel sen yaparsın.',
  'Hijyen görünmez, eksikliği hemen görünür.',
  'Güzel bir gün, temiz bir başlangıçla açılır.',
  'Ekip olarak temizlik, tek başına yorgunluktur.',
  'Titizlik, işin sessiz imzasıdır.',
  'Bugünün işini yarına bırakma; kir birikir, yük büyür.',
  'Parlayan her cam, özenle çalışan bir elin işidir.',
  'Temiz bir bina, içindekilere iyi gelir.',
  'Önce kendine saygı, sonra çalıştığın yere.',
  'Doğru ürün, doğru yöntem, doğru zaman.',
  'Az ama sık temizlemek, çok ama seyrek temizlemekten iyidir.',
  'Her gün biraz daha iyi, her gün biraz daha temiz.',
  'Dikkatli çalışan, iki kez çalışmaz.',
  'Sağlık temizlikle başlar.',
  'Takım ruhu, ortak bir alanı birlikte güzelleştirmektir.',
  'Emek ve özen: temizliğin iki anahtarı.',
];

String quoteOfTheDay() {
  final n = DateTime.now();
  final day = DateTime(n.year, n.month, n.day).difference(DateTime(n.year, 1, 1)).inDays;
  return dailyQuotes[day % dailyQuotes.length];
}

class QuoteCard extends StatelessWidget {
  const QuoteCard({super.key});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Günün sözü',
              style: Theme.of(context)
                  .textTheme
                  .labelMedium
                  ?.copyWith(color: cs.onSecondaryContainer)),
          const SizedBox(height: 4),
          Text('“${quoteOfTheDay()}”',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: cs.onSecondaryContainer)),
        ]),
      ),
    );
  }
}

/// Görevini yapmayanlar: saati geçip yapılmayan turlar, sorumlu kişiye göre gruplu (yönetici ve şef Panosu).
class LateBoard extends StatelessWidget {
  const LateBoard({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final by = <String, List<String>>{};
        final phones = <String, String>{};
        var total = 0;
        for (final t in app.tasks) {
          final owners = app.ownersOf(t.floorId);
          final units = t.slots != null
              ? [for (final s in t.slots!) (s.done, s.time)]
              : [(t.done, t.time)];
          for (final (done, time) in units) {
            if (done || !app.isLateFor(t, time)) continue;
            total++;
            final label = '${app.floorLabel(t.floorId)} ${t.area} ($time)';
            if (owners.isEmpty) {
              by.putIfAbsent('Sorumlusuz', () => []).add(label);
            }
            for (final p in owners) {
              by.putIfAbsent(p.name, () => []).add(label);
              phones[p.name] = p.phone;
            }
          }
        }
        final red = Colors.red;
        Widget chip(int n) => Chip(
              label: Text('$n', style: TextStyle(color: red, fontWeight: FontWeight.w700)),
              backgroundColor: red.withValues(alpha: 0.12),
              side: BorderSide.none,
              visualDensity: VisualDensity.compact,
            );
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('Görevini yapmayanlar', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                if (total > 0) chip(total),
              ]),
              if (by.isEmpty)
                const Padding(
                    padding: EdgeInsets.only(top: 6), child: Text('Şu an geciken görev yok.')),
              for (final e in by.entries)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Row(children: [
                    Flexible(child: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w600))),
                    const SizedBox(width: 6),
                    chip(e.value.length),
                  ]),
                  subtitle: Text(e.value.take(3).join('\n') +
                      (e.value.length > 3 ? '\n+${e.value.length - 3} görev daha' : '')),
                  trailing: (phones[e.key] ?? '').isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.call),
                          tooltip: 'Ara',
                          onPressed: () => callPhone(context, phones[e.key]!),
                        ),
                ),
            ]),
          ),
        );
      },
    );
  }
}

Color medalColor(int i) => switch (i) {
      0 => Colors.amber.shade700,
      1 => Colors.blueGrey.shade400,
      2 => Colors.brown.shade400,
      _ => Colors.grey.shade500,
    };

/// Çalışanın kendi sayfasında: bu ayın ilk üçü (ve kendi sırası).
class TopThreeCard extends StatelessWidget {
  final Staff me;
  const TopThreeCard({super.key, required this.me});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final rows = app.rankings('month');
        final idx = rows.indexWhere((r) => r.name == me.name);
        final prizes = app.awards.where((a) => a.name == me.name).length;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Bu ayın en iyi üçü', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              for (var i = 0; i < rows.length && i < 3; i++)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                      radius: 14,
                      backgroundColor: medalColor(i),
                      foregroundColor: Colors.white,
                      child: Text('${i + 1}')),
                  title: Text(rows[i].name + (rows[i].name == me.name ? ' (sen)' : ''),
                      style: TextStyle(
                          fontWeight: rows[i].name == me.name ? FontWeight.w700 : FontWeight.w400)),
                  trailing: Text('${rows[i].score} puan',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              if (idx > 2) Text('Sıran: ${idx + 1}. · ${rows[idx].score} puan'),
              if (prizes > 0) Text('Kazandığın ödül: $prizes'),
              const SizedBox(height: 4),
              const Text('Puan: zamanında yapılan görev tam, geç yapılan yarım sayılır.',
                  style: TextStyle(fontSize: 12)),
            ]),
          ),
        );
      },
    );
  }
}

/// Yönetici ve şef: görev başarı sıralaması. Yönetici en iyi personele ödül verebilir.
class ReportView extends StatefulWidget {
  final bool canAward;
  const ReportView({super.key, required this.canAward});
  @override
  State<ReportView> createState() => _ReportViewState();
}

class _ReportViewState extends State<ReportView> {
  String period = 'month';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final rows = app.rankings(period);
        return ListView(padding: const EdgeInsets.all(12), children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'today', label: Text('Bugün')),
              ButtonSegment(value: 'month', label: Text('Bu ay')),
              ButtonSegment(value: 'year', label: Text('Bu yıl')),
            ],
            selected: {period},
            onSelectionChanged: (v) => setState(() => period = v.first),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Görev başarı sıralaması · ${AppState.periodLabels[period]}',
                    style: Theme.of(context).textTheme.titleMedium),
                for (var i = 0; i < rows.length; i++)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                        radius: 14,
                        backgroundColor: medalColor(i),
                        foregroundColor: Colors.white,
                        child: Text('${i + 1}')),
                    title: Text(rows[i].name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        'Yapılan ${rows[i].done}/${rows[i].assigned} · zamanında %${rows[i].done == 0 ? 0 : (rows[i].onTime / rows[i].done * 100).round()}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text('${rows[i].score}',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      if (widget.canAward)
                        TextButton(
                          onPressed: () {
                            app.giveAward(rows[i].name, period, i + 1);
                            toast(context, '${rows[i].name} için ödül verildi, bildirim gitti.');
                          },
                          child: const Text('Ödül ver'),
                        ),
                    ]),
                  ),
                const SizedBox(height: 6),
                const Text(
                    'Puan = (zamanında yapılan + geç yapılan × 0,5) ÷ atanan görev × 100. Atanan: sorumlu olduğu katlarda yapılmış ya da saati geçmiş görevler. Çalışanlar kendi sayfasında bu ayın ilk üçünü görür.',
                    style: TextStyle(fontSize: 12)),
              ]),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Verilen ödüller', style: Theme.of(context).textTheme.titleMedium),
                if (app.awards.isEmpty)
                  const Padding(padding: EdgeInsets.only(top: 6), child: Text('Henüz ödül verilmedi.')),
                for (final a in app.awards)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(a.name),
                    subtitle: Text('${a.label} · ${a.rank}. sıra · ${dateLabel(a.date)}'),
                    trailing: const Icon(Icons.emoji_events, color: Colors.amber),
                  ),
              ]),
            ),
          ),
        ]);
      },
    );
  }
}

class BoardView extends StatelessWidget {
  const BoardView({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final done = unitsDone(app.tasks);
        final total = unitsTotal(app.tasks);
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            const QuoteCard(),
            const LateBoard(),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Bugün tamamlanan: $done/$total',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: total == 0 ? 0 : done / total),
                ]),
              ),
            ),
            for (final b in buildings)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                        '${b.name} · ${app.floors.where((f) => f.buildingId == b.id).length} kat',
                        style: Theme.of(context).textTheme.titleMedium),
                    for (final f in app.floors.where((f) => f.buildingId == b.id))
                      _floorRow(f),
                  ]),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _floorRow(Floor f) {
    final l = app.tasks.where((t) => t.floorId == f.id).toList();
    final d = unitsDone(l);
    final owners = app.staff
        .where((p) => p.floors.contains(f.id))
        .map((p) => p.name.split(' ').first)
        .join(', ');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(f.name),
      subtitle: Text(owners.isEmpty ? 'Atanmamış' : owners),
      trailing: Chip(label: Text('$d/${unitsTotal(l)}'), visualDensity: VisualDensity.compact),
    );
  }
}

/// Şef için: tüm personelin vardiyası, katları, görev ilerlemesi ve telefonu.
class TeamView extends StatelessWidget {
  final Staff self;
  const TeamView({super.key, required this.self});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final others = app.staff.where((p) => p != self).toList();
        if (others.isEmpty) return const Center(child: Text('Ekipte başka personel yok.'));
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final p in others)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                          child: Text(p.name, style: Theme.of(context).textTheme.titleMedium)),
                      if (!p.isChief) _progressChip(p),
                    ]),
                    Text('${p.role} · ${app.shiftById(p.shift)?.name ?? 'Özel saat'} · ${p.from}–${p.to}'),
                    const SizedBox(height: 6),
                    if (p.isChief)
                      const Text('Tüm katları görür')
                    else ...[
                      Wrap(spacing: 6, runSpacing: 4, children: [
                        if (p.floors.isEmpty) const Text('Sorumlu kat yok'),
                        for (final id in p.floors)
                          Chip(
                              label: Text(app.floorShort(id)),
                              visualDensity: VisualDensity.compact),
                      ]),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: _ratio(p)),
                    ],
                    if (p.phone.isNotEmpty)
                      Row(children: [
                        Expanded(child: SelectableText(p.phone)),
                        FilledButton.tonalIcon(
                          onPressed: () => callPhone(context, p.phone),
                          icon: const Icon(Icons.call),
                          label: const Text('Ara'),
                        ),
                      ]),
                  ]),
                ),
              ),
          ],
        );
      },
    );
  }

  double _ratio(Staff p) {
    final l = app.tasksOf(p.floors);
    final tot = unitsTotal(l);
    return tot == 0 ? 0 : unitsDone(l) / tot;
  }

  Widget _progressChip(Staff p) {
    final l = app.tasksOf(p.floors);
    final d = unitsDone(l);
    return Chip(label: Text('$d/${unitsTotal(l)} görev'), visualDensity: VisualDensity.compact);
  }
}

/// Anlık mesaj gönderme ve gelen bildirimler. role: 'manager' veya 'chief'.
class NotifsPanel extends StatefulWidget {
  final String role;
  final Staff? me;
  const NotifsPanel({super.key, required this.role, this.me});
  @override
  State<NotifsPanel> createState() => _NotifsPanelState();
}

class _NotifsPanelState extends State<NotifsPanel> {
  final _msgC = TextEditingController();
  String _to = 'Tüm çalışanlar';

  @override
  void dispose() {
    _msgC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final list = app.visible(widget.role, widget.me);
        final names = ['Tüm çalışanlar', ...app.staff.where((p) => p != widget.me).map((p) => p.name)];
        final to = names.contains(_to) ? _to : 'Tüm çalışanlar';
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Anlık mesaj', style: Theme.of(context).textTheme.titleMedium),
                  DropdownButtonFormField<String>(
                    initialValue: to,
                    decoration: const InputDecoration(labelText: 'Kime'),
                    items: [for (final n in names) DropdownMenuItem(value: n, child: Text(n))],
                    onChanged: (v) => setState(() => _to = v ?? _to),
                  ),
                  TextField(
                    controller: _msgC,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                        labelText: 'Mesaj', hintText: 'Örn. Ana Bina 3. kat WC acil temizlensin'),
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: () {
                      final text = _msgC.text.trim();
                      if (text.isEmpty) return;
                      app.send(to, text, from: widget.role);
                      _msgC.clear();
                      toast(context, 'Gönderildi: $to');
                    },
                    child: const Text('Gönder'),
                  ),
                ]),
              ),
            ),
            const Padding(
                padding: EdgeInsets.fromLTRB(4, 14, 4, 6), child: Text('Gelen bildirimler')),
            if (list.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('Çalışan bir görevi tamamlayınca burada görünür.'))
            else
              for (final n in list) ListTile(title: Text(n.text), trailing: Text(n.time)),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Hafta sonu mesaisi
// ---------------------------------------------------------------------------

/// Çalışan: yalnızca kendi mesaisini görür.
class WorkerOvertimeView extends StatelessWidget {
  final Staff me;
  const WorkerOvertimeView({super.key, required this.me});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final mine = app.overtimeOf(me.name)..sort((a, b) => b.date.compareTo(a.date));
        final now = DateTime.now();
        final done = mine.where((o) => o.done).toList();
        final inYear = done.where((o) => o.date.year == now.year).toList();
        final inMonth = inYear.where((o) => o.date.month == now.month).toList();
        final plan = mine.where((o) => !o.done).toList();
        double sum(List<Overtime> l) => l.fold(0.0, (a, o) => a + o.hours);
        final head = Theme.of(context).textTheme.titleMedium;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('${monthNames[now.month - 1]} ayı mesaim'),
                    Text(fmtHours(sum(inMonth)), style: head),
                  ]),
                  const SizedBox(height: 6),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    Text('${now.year} yılı toplam'),
                    Text(fmtHours(sum(inYear)), style: head),
                  ]),
                ]),
              ),
            ),
            const Padding(
                padding: EdgeInsets.fromLTRB(4, 14, 4, 6), child: Text('Planlı mesailer')),
            if (plan.isEmpty)
              const Padding(padding: EdgeInsets.all(12), child: Text('Planlı mesai yok.'))
            else
              for (final o in plan)
                Card(
                  child: ListTile(
                    title: Text(dateLabel(o.date)),
                    subtitle: Text(fmtHours(o.hours)),
                    trailing: FilledButton(
                      onPressed: () {
                        app.completeOvertime(o);
                        toast(context, 'Yönetici ve şefe bildirim gönderildi.');
                      },
                      child: const Text('Yaptım'),
                    ),
                  ),
                ),
            const Padding(padding: EdgeInsets.fromLTRB(4, 14, 4, 6), child: Text('Tamamlanan')),
            if (done.isEmpty)
              const Padding(
                  padding: EdgeInsets.all(12), child: Text('Henüz tamamlanan mesai yok.'))
            else
              for (final o in done)
                Card(
                  child: ListTile(
                    title: Text(dateLabel(o.date)),
                    subtitle: Text(fmtHours(o.hours)),
                    trailing: const Icon(Icons.check_circle, color: Colors.green),
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// Yönetici: mesai atar, iptal eder ve raporu görür.
class OvertimeManagerView extends StatefulWidget {
  const OvertimeManagerView({super.key});
  @override
  State<OvertimeManagerView> createState() => _OvertimeManagerViewState();
}

class _OvertimeManagerViewState extends State<OvertimeManagerView> {
  bool report = false;
  Staff? who;
  DateTime date = _nextSaturday();

  static DateTime _nextSaturday() {
    final n = DateTime.now();
    final d = DateTime(n.year, n.month, n.day);
    return d.add(Duration(days: (6 - d.weekday) % 7));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final p = app.staff.contains(who) ? who : (app.staff.isEmpty ? null : app.staff.first);
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Atama')),
                ButtonSegment(value: true, label: Text('Rapor')),
              ],
              selected: {report},
              onSelectionChanged: (s) => setState(() => report = s.first),
            ),
            const SizedBox(height: 12),
            if (report) const OvertimeReportView() else ..._assign(context, p),
          ],
        );
      },
    );
  }

  List<Widget> _assign(BuildContext context, Staff? p) {
    final recent = [...app.overtime]..sort((a, b) => b.date.compareTo(a.date));
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Hafta sonu mesaisi ata', style: Theme.of(context).textTheme.titleMedium),
            DropdownButton<Staff>(
              isExpanded: true,
              value: p,
              items: [for (final s in app.staff) DropdownMenuItem(value: s, child: Text(s.name))],
              onChanged: (s) => setState(() => who = s),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () async {
                final now = DateTime.now();
                final d = await showDatePicker(
                  context: context,
                  initialDate: date,
                  firstDate: DateTime(now.year - 1),
                  lastDate: DateTime(now.year + 1, 12, 31),
                  selectableDayPredicate: (d) => d.weekday >= 6, // yalnızca cumartesi, pazar
                );
                if (d != null) setState(() => date = d);
              },
              child: Text('Tarih: ${dateLabel(date)}'),
            ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: p == null
                  ? null
                  : () {
                      app.assignOvertime(p.name, date);
                      toast(context, '${p.name} için mesai atandı.');
                    },
              child: const Text('Mesai günü ata'),
            ),
          ]),
        ),
      ),
      const Padding(padding: EdgeInsets.fromLTRB(4, 14, 4, 6), child: Text('Son atamalar')),
      for (final o in recent.take(12))
        Card(
          child: ListTile(
            title: Text(o.name),
            subtitle: Text('${dateLabel(o.date)} · ${fmtHours(o.hours)}'),
            trailing: o.done
                ? const Chip(label: Text('Tamamlandı'), visualDensity: VisualDensity.compact)
                : TextButton(
                    onPressed: () => app.cancelOvertime(o.id), child: const Text('İptal')),
          ),
        ),
    ];
  }
}

/// Aylık / yıllık mesai raporu: herkesin tamamlanan ve planlı saatleri.
class OvertimeReportView extends StatefulWidget {
  const OvertimeReportView({super.key});
  @override
  State<OvertimeReportView> createState() => _OvertimeReportViewState();
}

class _OvertimeReportViewState extends State<OvertimeReportView> {
  bool yearly = false;
  int year = DateTime.now().year;
  int month = DateTime.now().month;

  String get _label => yearly ? '$year yılı' : '${monthNames[month - 1]} $year';

  String _text(List<OtRow> rows, double total) {
    final b = StringBuffer('Mesai raporu: $_label\nPersonel\tTamamlanan (gün)\tPlanlı (gün)\n');
    for (final r in rows) {
      b.writeln('${r.name}\t${r.done.round()}\t${r.planned.round()}');
    }
    b.write('Toplam\t${total.round()}');
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final years = app.overtimeYears();
        final y = years.contains(year) ? year : years.last;
        final rows = app.overtimeReport(y, yearly ? null : month);
        final totDone = rows.fold(0.0, (a, r) => a + r.done);
        final totPlan = rows.fold(0.0, (a, r) => a + r.planned);
        const bold = TextStyle(fontWeight: FontWeight.w700);
        final monthly = [for (var m = 1; m <= 12; m++) app.monthlyDoneHours(y, m)];
        final maxH = monthly.fold(1.0, (a, h) => a > h ? a : h);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Aylık')),
              ButtonSegment(value: true, label: Text('Yıllık')),
            ],
            selected: {yearly},
            onSelectionChanged: (s) => setState(() => yearly = s.first),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: DropdownButton<int>(
                isExpanded: true,
                value: month,
                items: [
                  for (var m = 1; m <= 12; m++)
                    DropdownMenuItem(value: m, child: Text(monthNames[m - 1]))
                ],
                onChanged: yearly ? null : (v) => setState(() => month = v ?? month),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButton<int>(
                isExpanded: true,
                value: y,
                items: [for (final v in years) DropdownMenuItem(value: v, child: Text('$v'))],
                onChanged: (v) => setState(() => year = v ?? year),
              ),
            ),
          ]),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$_label mesai raporu', style: Theme.of(context).textTheme.titleMedium),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 20,
                    headingRowHeight: 36,
                    dataRowMinHeight: 36,
                    dataRowMaxHeight: 40,
                    columns: const [
                      DataColumn(label: Text('Personel')),
                      DataColumn(label: Text('Tamamlanan'), numeric: true),
                                      DataColumn(label: Text('Planlı'), numeric: true),
                    ],
                    rows: [
                      for (final r in rows)
                        DataRow(cells: [
                          DataCell(Text(r.name)),
                          DataCell(Text(fmtHours(r.done))),
                          DataCell(Text(fmtHours(r.planned))),
                        ]),
                      DataRow(cells: [
                        const DataCell(Text('Toplam', style: bold)),
                        DataCell(Text(fmtHours(totDone), style: bold)),
                        DataCell(Text(fmtHours(totPlan), style: bold)),
                      ]),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _text(rows, totDone)));
                    toast(context, 'Rapor panoya kopyalandı.');
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Raporu kopyala'),
                ),
              ]),
            ),
          ),
          if (yearly)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Aylara göre toplam', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  for (var m = 1; m <= 12; m++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        SizedBox(width: 40, child: Text(monthNames[m - 1].substring(0, 3))),
                        Expanded(child: LinearProgressIndicator(value: monthly[m - 1] / maxH)),
                        SizedBox(
                            width: 64,
                            child: Text(fmtHours(monthly[m - 1]), textAlign: TextAlign.right)),
                      ]),
                    ),
                ]),
              ),
            ),
        ]);
      },
    );
  }
}
