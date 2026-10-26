import 'package:flutter/material.dart';
import 'services/session_client.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'services/api_service.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: sessionExpired,
      builder: (context, expired, child) => MaterialApp(
        title: 'Helping Hand Worker',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeMode
            .light, // Default to light theme which has our custom purple elements
        home: AuthSessionWrapper(key: ValueKey(expired)),
      ),
    );
  }
}

class AuthSessionWrapper extends StatefulWidget {
  const AuthSessionWrapper({super.key});

  @override
  State<AuthSessionWrapper> createState() => _AuthSessionWrapperState();
}

class _AuthSessionWrapperState extends State<AuthSessionWrapper> {
  final _apiService = ApiService();
  bool _checkingSession = true;
  bool _isLoggedIn = false;

  @override
  void initState() {
    super.initState();
    _checkSession();
  }

  Future<void> _checkSession() async {
    final loggedIn = await _apiService.isLoggedIn();
    setState(() {
      _isLoggedIn = loggedIn;
      _checkingSession = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSession) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF6C3CE0)),
        ),
      );
    }

    return _isLoggedIn ? const HomeScreen() : const LoginScreen();
  }
}
