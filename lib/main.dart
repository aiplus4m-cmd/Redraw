import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/app_info.dart';
import 'services/settings_service.dart';

const brandBlue = Color(0xFF2272B9);
const brandOrange = Color(0xFFF28A30);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await SettingsService.load();
  runApp(RedrawApp(settings: settings));
}

class RedrawApp extends StatelessWidget {
  const RedrawApp({super.key, required this.settings});

  final SettingsService settings;

  ThemeData _theme(Brightness brightness) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: brandBlue,
          brightness: brightness,
        ).copyWith(
          primary: brightness == Brightness.light ? brandBlue : null,
          secondary: brandOrange,
          tertiary: brandOrange,
        );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: 'Be Vietnam Pro',
      appBarTheme: const AppBarTheme(centerTitle: false),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppInfo.appName,
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: HomeScreen(settings: settings),
    );
  }
}
