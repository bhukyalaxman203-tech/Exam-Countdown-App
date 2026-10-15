import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

late SharedPreferences prefs;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  final sid = prefs.getString('session');
  final users = jsonDecode(prefs.getString('users') ?? '[]') as List;
  for (final u in users) {
    if (u['id'] == sid) store.load(Map<String, dynamic>.from(u));
  }
  runApp(const App());
}

// ---------------------------------------------------------------- DATA MODEL
// user    : {id, role: candidate|faculty, name, login (mobile/email), h (sha256)}
// exam    : {id, name, cat, grp, kind, subject, at (ISO), priority, loc, prep 0-100}
// task    : {id, name, subject, date (yyyy-mm-dd), mins, done}
// session : {at (ISO), min}
String ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String fmt(DateTime d) => '${d.day}/${d.month}/${d.year}  ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class Store extends ChangeNotifier {
  Map<String, dynamic>? user;
  List<Map<String, dynamic>> exams = [], tasks = [], sessions = [];
  Map<String, dynamic> details = {};
  String get _key => 'data_${user!['id']}';

  void load(Map<String, dynamic> u) {
    user = u;
    final s = prefs.getString(_key);
    if (s != null) {
      final d = jsonDecode(s);
      exams = List<Map<String, dynamic>>.from(d['exams']);
      tasks = List<Map<String, dynamic>>.from(d['tasks']);
      sessions = List<Map<String, dynamic>>.from(d['sessions']);
      details = Map<String, dynamic>.from(d['details']);
    } else {
      exams = []; tasks = []; sessions = []; details = {};
    }
    notifyListeners();
  }

  void save() {
    prefs.setString(_key, jsonEncode({'exams': exams, 'tasks': tasks, 'sessions': sessions, 'details': details}));
    notifyListeners();
  }

  void logout() {
    prefs.remove('session');
    user = null;
    notifyListeners();
  }

  // Remaining time is always computed from the real exam date/time.
  List<Map<String, dynamic>> get upcoming => exams.where((e) => DateTime.parse(e['at']).isAfter(DateTime.now())).toList()
    ..sort((a, b) => DateTime.parse(a['at']).compareTo(DateTime.parse(b['at'])));

  int minsOn(DateTime d) =>
      sessions.where((s) => ymd(DateTime.parse(s['at'])) == ymd(d)).fold<int>(0, (a, s) => a + (s['min'] as int));

  int get streak {
    var n = 0, d = DateTime.now();
    if (minsOn(d) == 0) d = d.subtract(const Duration(days: 1));
    while (minsOn(d) > 0) { n++; d = d.subtract(const Duration(days: 1)); }
    return n;
  }
}

final store = Store();

// Exam taxonomy: category -> group -> exams (shortened; extend as needed)
const taxonomy = <String, Map<String, List<String>>>{
  'School Boards': {'CBSE': ['CBSE Class 10', 'CBSE Class 12'], 'State Boards': ['AP SSC', 'TS SSC', 'TN SSLC', 'Karnataka PUC']},
  'Engineering Entrance': {'National': ['JEE Main', 'JEE Advanced', 'BITSAT'], 'State CETs': ['TS EAPCET', 'AP EAPCET', 'KCET', 'MHT CET']},
  'Medical': {'UG': ['NEET UG'], 'PG': ['NEET PG', 'INI-CET']},
  'SSC': {'CGL': ['CGL Tier 1', 'CGL Tier 2'], 'CHSL': ['CHSL Tier 1', 'CHSL Tier 2'], 'Others': ['MTS', 'GD Constable', 'CPO']},
  'Railways (RRB)': {'NTPC': ['NTPC Graduate CBT 1', 'NTPC Undergraduate CBT 1'], 'Group D': ['Group D CBT'], 'ALP': ['ALP CBT 1', 'ALP CBT 2']},
  'Banking': {'IBPS': ['PO Prelims', 'Clerk Prelims', 'SO'], 'SBI': ['SBI PO', 'SBI Clerk']},
  'State PSC': {'Telangana': ['TSPSC Group 1', 'Group 2', 'Group 3', 'Group 4'], 'Andhra Pradesh': ['APPSC Group 1', 'Group 2'], 'Tamil Nadu': ['TNPSC Group 1', 'Group 2', 'Group 4']},
  'University': {'B.Tech / B.E.': ['Mid-1', 'Mid-2', 'Semester End Theory', 'Lab / Practical', 'Viva Voce']},
};

// ---------------------------------------------------------------- APP
class App extends StatelessWidget {
  const App({super.key});
  ThemeData _theme(Brightness b) => ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF5B5EF4), brightness: b);
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (_, __) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Exam Countdown',
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: store.user == null ? const AuthScreen() : const Shell(),
        ),
      );
}

// ---------------------------------------------------------------- LOGIN
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthState();
}

class _AuthState extends State<AuthScreen> {
  bool signUp = false, faculty = false, hide = true;
  String err = '';
  final name = TextEditingController(), id = TextEditingController(), pw = TextEditingController(), pw2 = TextEditingController();

  String hash(String p) => sha256.convert(utf8.encode('ec:$p')).toString();

  String? normalise(String v) {
    v = v.trim().toLowerCase();
    if (RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(v)) return v;
    final d = v.replaceAll(RegExp(r'[\s-]'), '').replaceFirst(RegExp(r'^(\+91|91|0)(?=\d{10}$)'), '');
    return RegExp(r'^[6-9]\d{9}$').hasMatch(d) ? d : null;
  }

  void fail(String m) => setState(() => err = m);

  void submit() {
    final login = normalise(id.text);
    final users = List<Map<String, dynamic>>.from(jsonDecode(prefs.getString('users') ?? '[]'));
    if (login == null) return fail('Enter a valid 10-digit mobile number or email.');
    if (pw.text.length < 6) return fail('Password must be at least 6 characters.');
    Map<String, dynamic>? user;
    if (signUp) {
      if (name.text.trim().length < 2) return fail('Please enter your full name.');
      if (pw.text != pw2.text) return fail('Passwords do not match.');
      if (users.any((u) => u['login'] == login)) return fail('Already registered. Please sign in.');
      user = {'id': '${DateTime.now().millisecondsSinceEpoch}', 'role': faculty ? 'faculty' : 'candidate', 'name': name.text.trim(), 'login': login, 'h': hash(pw.text)};
      users.add(user);
      prefs.setString('users', jsonEncode(users));
    } else {
      user = users.where((u) => u['login'] == login && u['h'] == hash(pw.text)).firstOrNull;
      if (user == null) return fail('Incorrect mobile/email or password.');
      if ((user['role'] == 'faculty') != faculty) return fail('This is a ${user['role']} account. Switch role above.');
    }
    prefs.setString('session', user['id']);
    store.load(user);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('⏳ Exam Countdown', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                  const Text('Count the days. Plan the study. Ace the exam.', textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  SegmentedButton<bool>(
                    segments: const [ButtonSegment(value: false, label: Text('Candidate'), icon: Icon(Icons.school)), ButtonSegment(value: true, label: Text('Faculty'), icon: Icon(Icons.badge))],
                    selected: {faculty},
                    onSelectionChanged: (s) => setState(() => faculty = s.first),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<bool>(
                    segments: const [ButtonSegment(value: false, label: Text('Sign in')), ButtonSegment(value: true, label: Text('Create account'))],
                    selected: {signUp},
                    onSelectionChanged: (s) => setState(() { signUp = s.first; err = ''; }),
                  ),
                  const SizedBox(height: 12),
                  if (signUp) TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name', border: OutlineInputBorder())),
                  if (signUp) const SizedBox(height: 12),
                  TextField(controller: id, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Mobile number or email', border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  TextField(
                    controller: pw, obscureText: hide,
                    decoration: InputDecoration(labelText: 'Password', border: const OutlineInputBorder(), suffixIcon: IconButton(icon: Icon(hide ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => hide = !hide))),
                  ),
                  if (signUp) const SizedBox(height: 12),
                  if (signUp) TextField(controller: pw2, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm password', border: OutlineInputBorder())),
                  if (err.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: submit, child: Padding(padding: const EdgeInsets.all(12), child: Text(signUp ? 'Create account' : 'Sign in'))),
                  const SizedBox(height: 8),
                  const Text('Accounts are stored on this device only.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
                ]),
              ),
            ),
          ),
        ),
      );
}

// ---------------------------------------------------------------- SHELL (nav, history, logout)
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int i = 0, hp = 0;
  final hist = <int>[0];
  static const titles = ['Home', 'Exams', 'Planner', 'Progress', 'Profile'];

  void go(int n) => setState(() {
        if (hist[hp] != n) { hist.removeRange(hp + 1, hist.length); hist.add(n); hp++; }
        i = n;
      });

  Future<void> logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(title: const Text('Log out?'), actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Log out')),
      ]),
    );
    if (ok == true) store.logout();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [HomePage(), ExamsPage(), PlannerPage(), ProgressPage(), ProfilePage(onLogout: logout)];
    return ListenableBuilder(
      listenable: store,
      builder: (_, __) => Scaffold(
        appBar: AppBar(
          title: Text(titles[i]),
          leading: IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back), onPressed: hp > 0 ? () => setState(() => i = hist[--hp]) : null),
          actions: [
            IconButton(tooltip: 'Forward', icon: const Icon(Icons.arrow_forward), onPressed: hp < hist.length - 1 ? () => setState(() => i = hist[++hp]) : null),
            IconButton(tooltip: 'Logout', icon: const Icon(Icons.logout), onPressed: logout),
          ],
        ),
        body: GestureDetector(
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -300 && i < 4) go(i + 1);
            if (v > 300 && i > 0) go(i - 1);
          },
          child: AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: KeyedSubtree(key: ValueKey(i), child: pages[i])),
        ),
        bottomNavigationBar: NavigationBar(selectedIndex: i, onDestinationSelected: go, destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.event_note_outlined), label: 'Exams'),
          NavigationDestination(icon: Icon(Icons.checklist), label: 'Planner'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Progress'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Profile'),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- COUNTDOWN (updates every second)
class Countdown extends StatefulWidget {
  final DateTime at;
  final Color color;
  const Countdown({super.key, required this.at, required this.color});
  @override
  State<Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<Countdown> {
  late final Timer t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  @override
  void initState() { super.initState(); t; }
  @override
  void dispose() { t.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final d = widget.at.difference(DateTime.now());
    if (d.isNegative) return Text('🎉 Exam completed', style: TextStyle(fontSize: 22, color: widget.color));
    final urgent = d.inHours < 24; // emphasise when under 24 hours
    final v = [d.inDays, d.inHours % 24, d.inMinutes % 60, d.inSeconds % 60];
    const l = ['DAYS', 'HOURS', 'MIN', 'SEC'];
    return Row(children: [
      for (var k = 0; k < 4; k++)
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(3), padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(color: urgent ? Colors.red.withOpacity(.5) : widget.color.withOpacity(.18), borderRadius: BorderRadius.circular(14)),
            child: Column(children: [
              Text(v[k].toString().padLeft(2, '0'), style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: widget.color)),
              Text(l[k], style: TextStyle(fontSize: 10, color: widget.color)),
            ]),
          ),
        ),
    ]);
  }
}

Widget emptyCard(String t, String s) => Card(child: Padding(padding: const EdgeInsets.all(28), child: Center(child: Column(children: [Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), const SizedBox(height: 4), Text(s, textAlign: TextAlign.center)]))));

// ---------------------------------------------------------------- HOME
class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final up = store.upcoming;
    final today = store.tasks.where((t) => t['date'] == ymd(DateTime.now())).toList();
    final done = today.where((t) => t['done'] == true).length;
    final pct = today.isEmpty ? 0.0 : done / today.length;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Hello, ${store.user!['name']} 👋', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 12),
      if (up.isEmpty) emptyCard('No exams yet', 'Add your first exam and start your countdown.')
      else Card(
        color: cs.primary,
        child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(up.first['name'], style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: cs.onPrimary)),
          Text('${fmt(DateTime.parse(up.first['at']))} · ${up.first['priority']} priority', style: TextStyle(color: cs.onPrimary)),
          const SizedBox(height: 8),
          Countdown(at: DateTime.parse(up.first['at']), color: cs.onPrimary),
          Text('Preparation ${up.first['prep']}%', style: TextStyle(color: cs.onPrimary)),
          LinearProgressIndicator(value: (up.first['prep'] as int) / 100),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(icon: const Icon(Icons.play_arrow), label: const Text('Start Studying'), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PomodoroPage()))),
        ])),
      ),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text("Today's progress  ${(pct * 100).round()}%", style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: pct),
        const SizedBox(height: 8),
        Text('🔥 ${store.streak} day streak · ${store.minsOn(DateTime.now())} min studied today'),
      ]))),
      Text("Today's tasks", style: Theme.of(context).textTheme.titleMedium),
      if (today.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Nothing planned today.')),
      for (final t in today)
        CheckboxListTile(value: t['done'] == true, title: Text(t['name']), subtitle: Text('${t['subject']} · ${t['mins']} min'), onChanged: (v) { t['done'] = v; store.save(); }),
    ]);
  }
}

// ---------------------------------------------------------------- EXAMS + ADD EXAM WIZARD
class ExamsPage extends StatelessWidget {
  const ExamsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final list = [...store.exams]..sort((a, b) => DateTime.parse(a['at']).compareTo(DateTime.parse(b['at'])));
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.add), label: const Text('Add Exam'), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AddExamPage()))),
      body: list.isEmpty
          ? Padding(padding: const EdgeInsets.all(16), child: emptyCard('No exams yet', 'Add your first exam and start your countdown.'))
          : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 90), children: [
              for (final e in list)
                Card(
                  child: ListTile(
                    title: Text(e['name']),
                    subtitle: Text('${e['kind']} · ${fmt(DateTime.parse(e['at']))}\n${DateTime.parse(e['at']).isAfter(DateTime.now()) ? '${DateTime.parse(e['at']).difference(DateTime.now()).inDays} days left' : 'Exam completed'} · Prep ${e['prep']}% · ${e['priority']}'),
                    isThreeLine: true,
                    onTap: () => _prep(context, e),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'del') store.exams.remove(e);
                        if (v == 'dup') store.exams.add({...e, 'id': '${DateTime.now().microsecondsSinceEpoch}', 'name': '${e['name']} (copy)'});
                        store.save();
                      },
                      itemBuilder: (_) => const [PopupMenuItem(value: 'dup', child: Text('Duplicate')), PopupMenuItem(value: 'del', child: Text('Delete'))],
                    ),
                  ),
                ),
            ]),
    );
  }

  void _prep(BuildContext c, Map e) => showModalBottomSheet(
        context: c,
        builder: (_) => StatefulBuilder(builder: (ctx, set) => Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Preparation: ${e['prep']}%', style: const TextStyle(fontSize: 18)),
          Slider(value: (e['prep'] as int).toDouble(), max: 100, divisions: 20, onChanged: (v) { set(() => e['prep'] = v.round()); store.save(); }),
        ]))),
      );
}

class AddExamPage extends StatefulWidget {
  const AddExamPage({super.key});
  @override
  State<AddExamPage> createState() => _AddState();
}

class _AddState extends State<AddExamPage> {
  int step = 0;
  String? cat, grp, kind, pri = 'Medium';
  DateTime at = DateTime.now().add(const Duration(days: 7));
  final name = TextEditingController(), subject = TextEditingController(), loc = TextEditingController(), custom = TextEditingController();

  void msg(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Widget chips(List<String> items, String? sel, void Function(String) pick) =>
      Wrap(spacing: 8, children: [for (final x in items) ChoiceChip(label: Text(x), selected: sel == x, onSelected: (_) => setState(() => pick(x)))]);

  void next() {
    if (step == 0 && cat == null) return msg('Select a category');
    if (step == 1 && grp == null) return msg('Select a group');
    if (step == 2) {
      if (custom.text.trim().isNotEmpty) kind = custom.text.trim();
      if (kind == null) return msg('Select or type your exam');
      if (name.text.isEmpty) name.text = kind!;
    }
    if (step == 3) {
      if (name.text.trim().isEmpty) return msg('Exam name is required');
      store.exams.add({'id': '${DateTime.now().microsecondsSinceEpoch}', 'name': name.text.trim(), 'cat': cat, 'grp': grp, 'kind': kind, 'subject': subject.text.trim().isEmpty ? kind : subject.text.trim(), 'at': at.toIso8601String(), 'priority': pri, 'loc': loc.text, 'prep': 0});
      store.save();
      return Navigator.pop(context);
    }
    setState(() => step++);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Add exam')),
        body: Stepper(
          currentStep: step,
          controlsBuilder: (_, __) => Padding(padding: const EdgeInsets.only(top: 12), child: Row(children: [
            FilledButton(onPressed: next, child: Text(step == 3 ? 'Save' : 'Next →')),
            const SizedBox(width: 8),
            TextButton(onPressed: () => step == 0 ? Navigator.pop(context) : setState(() => step--), child: Text(step == 0 ? 'Cancel' : '← Back')),
          ])),
          steps: [
            Step(title: const Text('Category'), isActive: step >= 0, content: chips(taxonomy.keys.toList(), cat, (x) { cat = x; grp = null; kind = null; })),
            Step(title: const Text('Group'), isActive: step >= 1, content: chips((taxonomy[cat] ?? {}).keys.toList(), grp, (x) { grp = x; kind = null; })),
            Step(title: const Text('Exam'), isActive: step >= 2, content: Column(children: [
              chips(taxonomy[cat]?[grp] ?? [], kind, (x) { kind = x; custom.clear(); }),
              TextField(controller: custom, decoration: const InputDecoration(labelText: 'Not listed? Type your own')),
            ])),
            Step(title: const Text('Details'), isActive: step >= 3, content: Column(children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Exam name *')),
              TextField(controller: subject, decoration: const InputDecoration(labelText: 'Subject (optional)')),
              TextField(controller: loc, decoration: const InputDecoration(labelText: 'Location')),
              ListTile(contentPadding: EdgeInsets.zero, title: Text('Date & time: ${fmt(at)}'), trailing: const Icon(Icons.edit_calendar), onTap: () async {
                final d = await showDatePicker(context: context, initialDate: at, firstDate: DateTime(2020), lastDate: DateTime(2100));
                if (d == null || !mounted) return;
                final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(at));
                setState(() => at = DateTime(d.year, d.month, d.day, t?.hour ?? at.hour, t?.minute ?? at.minute));
              }),
              DropdownButtonFormField<String>(value: pri, decoration: const InputDecoration(labelText: 'Priority'), items: const ['High', 'Medium', 'Low'].map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(), onChanged: (v) => pri = v),
            ])),
          ],
        ),
      );
}

// ---------------------------------------------------------------- PLANNER
class PlannerPage extends StatelessWidget {
  const PlannerPage({super.key});
  void add(BuildContext c) {
    final n = TextEditingController(), s = TextEditingController(), m = TextEditingController(text: '30');
    showDialog(context: c, builder: (_) => AlertDialog(
      title: const Text('New study task'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: n, decoration: const InputDecoration(labelText: 'Task name')),
        TextField(controller: s, decoration: const InputDecoration(labelText: 'Subject')),
        TextField(controller: m, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Minutes')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () {
          if (n.text.trim().isEmpty) return;
          store.tasks.add({'id': '${DateTime.now().microsecondsSinceEpoch}', 'name': n.text.trim(), 'subject': s.text.trim(), 'date': ymd(DateTime.now()), 'mins': int.tryParse(m.text) ?? 30, 'done': false});
          store.save();
          Navigator.pop(c);
        }, child: const Text('Add')),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton(onPressed: () => add(context), child: const Icon(Icons.add)),
        body: store.tasks.isEmpty
            ? Padding(padding: const EdgeInsets.all(16), child: emptyCard('Your study plan is empty.', 'Tap + to create a study task.'))
            : ReorderableListView(
                padding: const EdgeInsets.only(bottom: 90),
                onReorder: (a, b) { if (b > a) b--; store.tasks.insert(b, store.tasks.removeAt(a)); store.save(); },
                children: [
                  for (final t in store.tasks)
                    Dismissible(
                      key: ValueKey(t['id']),
                      background: Container(color: Colors.red),
                      onDismissed: (_) { store.tasks.remove(t); store.save(); },
                      child: CheckboxListTile(value: t['done'] == true, title: Text(t['name']), subtitle: Text('${t['subject']} · ${t['mins']} min · ${t['date']}'), onChanged: (v) { t['done'] = v; store.save(); }),
                    ),
                ],
              ),
      );
}

// ---------------------------------------------------------------- POMODORO TIMER
class PomodoroPage extends StatefulWidget {
  const PomodoroPage({super.key});
  @override
  State<PomodoroPage> createState() => _PomodoroState();
}

class _PomodoroState extends State<PomodoroPage> {
  int study = 25, brk = 5, left = 25 * 60;
  bool onBreak = false, running = false;
  Timer? t;

  int get total => (onBreak ? brk : study) * 60;
  void start() { t?.cancel(); setState(() => running = true); t = Timer.periodic(const Duration(seconds: 1), (_) => left <= 1 ? finish() : setState(() => left--)); }
  void pause() { t?.cancel(); setState(() => running = false); }
  void reset() { t?.cancel(); setState(() { running = false; left = total; }); }

  void finish() {
    t?.cancel();
    if (!onBreak) { // record the completed study session automatically
      store.sessions.add({'at': DateTime.now().toIso8601String(), 'min': study});
      store.save();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('🎉 Session saved: $study min')));
    }
    setState(() { onBreak = !onBreak; running = false; left = total; });
  }

  @override
  void dispose() { t?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(onBreak ? 'Break' : 'Focus')),
        body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 220, height: 220, child: Stack(alignment: Alignment.center, children: [
            SizedBox.expand(child: CircularProgressIndicator(value: 1 - left / total, strokeWidth: 10)),
            Text('${(left ~/ 60).toString().padLeft(2, '0')}:${(left % 60).toString().padLeft(2, '0')}', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
          ])),
          const SizedBox(height: 20),
          Row(mainAxisSize: MainAxisSize.min, children: [
            FilledButton(onPressed: running ? pause : start, child: Text(running ? 'Pause' : (left < total ? 'Resume' : 'Start'))),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: reset, child: const Text('Reset')),
          ]),
          if (!running) ...[
            Text('Study: $study min'),
            Slider(value: study.toDouble(), min: 5, max: 90, divisions: 17, onChanged: (v) => setState(() { study = v.round(); if (!onBreak) left = total; })),
            Text('Break: $brk min'),
            Slider(value: brk.toDouble(), min: 1, max: 30, divisions: 29, onChanged: (v) => setState(() { brk = v.round(); if (onBreak) left = total; })),
          ],
        ])),
      );
}

// ---------------------------------------------------------------- PROGRESS
class ProgressPage extends StatelessWidget {
  const ProgressPage({super.key});
  @override
  Widget build(BuildContext context) {
    final avg = store.exams.isEmpty ? 0 : store.exams.fold<int>(0, (a, e) => a + (e['prep'] as int)) ~/ store.exams.length;
    final days = [for (var i = 6; i >= 0; i--) DateTime.now().subtract(Duration(days: i))];
    final mins = days.map(store.minsOn).toList();
    final mx = mins.fold<int>(60, (a, b) => a > b ? a : b);
    final total = store.sessions.fold<int>(0, (a, s) => a + (s['min'] as int));
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(child: ListTile(title: Text('Overall preparation: $avg%'), subtitle: LinearProgressIndicator(value: avg / 100), trailing: Text('🔥 ${store.streak}'))),
      Card(child: ListTile(title: Text('Total study: ${(total / 60).toStringAsFixed(1)} h'), subtitle: Text('This week: ${mins.fold<int>(0, (a, b) => a + b)} min'))),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Weekly study (min)', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        SizedBox(height: 140, child: Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          for (var i = 0; i < 7; i++)
            Column(mainAxisAlignment: MainAxisAlignment.end, children: [
              Text('${mins[i]}', style: const TextStyle(fontSize: 10)),
              AnimatedContainer(duration: const Duration(milliseconds: 500), width: 26, height: 100 * mins[i] / mx + 2, decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(8))),
              Text(['M', 'T', 'W', 'T', 'F', 'S', 'S'][days[i].weekday - 1], style: const TextStyle(fontSize: 11)),
            ]),
        ])),
      ]))),
      for (final e in store.exams)
        Card(child: ListTile(title: Text(e['subject']), subtitle: LinearProgressIndicator(value: (e['prep'] as int) / 100), trailing: Text('${e['prep']}%'))),
    ]);
  }
}

// ---------------------------------------------------------------- PROFILE
class ProfilePage extends StatelessWidget {
  final VoidCallback onLogout;
  const ProfilePage({super.key, required this.onLogout});

  void edit(BuildContext c) {
    final keys = {'inst': 'School / College', 'course': 'Class / Course', 'branch': 'Branch', 'sem': 'Semester', 'sec': 'Section', 'city': 'City'};
    final ctl = {for (final k in keys.keys) k: TextEditingController(text: '${store.details[k] ?? ''}')};
    showDialog(context: c, builder: (_) => AlertDialog(
      title: const Text('Student details'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [for (final k in keys.keys) TextField(controller: ctl[k], decoration: InputDecoration(labelText: keys[k]))])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () { for (final k in keys.keys) store.details[k] = ctl[k]!.text.trim(); store.save(); Navigator.pop(c); }, child: const Text('Save')),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final u = store.user!;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(child: ListTile(leading: CircleAvatar(child: Text(u['role'] == 'faculty' ? '🧑‍🏫' : '🎓')), title: Text(u['name']), subtitle: Text('${u['login']} · ${u['role']}'))),
      Card(child: Column(children: [
        ListTile(title: const Text('Student details'), trailing: TextButton(onPressed: () => edit(context), child: const Text('Edit'))),
        for (final e in store.details.entries.where((e) => '${e.value}'.isNotEmpty)) ListTile(dense: true, title: Text(e.key), trailing: Text('${e.value}')),
      ])),
      FilledButton.tonalIcon(onPressed: onLogout, icon: const Icon(Icons.logout), label: const Text('Log out')),
    ]);
  }
}
