import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:hiddify/bootstrap.dart';
import 'package:hiddify/core/model/environment.dart';

Future<void> main() async {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent, systemNavigationBarColor: Colors.transparent),
  );

  // Диагностика: если запуск падает или зависает — показываем причину на экране,
  // а не белый экран. Помогает найти корень проблемы старта на iOS.
  try {
    await lazyBootstrap(widgetsBinding, Environment.prod)
        .timeout(const Duration(seconds: 25));
  } catch (e, st) {
    try {
      FlutterNativeSplash.remove();
    } catch (_) {}
    runApp(_BootError(error: e.toString(), stack: st.toString()));
  }
}

class _BootError extends StatelessWidget {
  const _BootError({required this.error, required this.stack});
  final String error;
  final String stack;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF101418),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 12),
                const Text(
                  'Окно — ошибка запуска',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 16),
                SelectableText(
                  error,
                  style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 14),
                ),
                const SizedBox(height: 16),
                SelectableText(
                  stack,
                  style: const TextStyle(color: Color(0xFF9AA0A6), fontSize: 11, height: 1.35),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
