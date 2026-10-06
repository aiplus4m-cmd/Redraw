import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_info.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  void _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Giới thiệu')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.asset(
                    'assets/icon/app_icon.png',
                    width: 96,
                    height: 96,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                AppInfo.appName,
                textAlign: TextAlign.center,
                style: text.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              FutureBuilder<PackageInfo>(
                future: PackageInfo.fromPlatform(),
                builder: (context, snap) => Text(
                  snap.hasData ? 'Phiên bản ${snap.data!.version}' : ' ',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 12),
              Text(AppInfo.tagline, textAlign: TextAlign.center),
              const SizedBox(height: 28),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    Container(
                      color: Colors.white,
                      padding: const EdgeInsets.all(20),
                      child: Image.asset('assets/images/logo.png', height: 120),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.code),
                      title: const Text('Nhà phát triển'),
                      subtitle: const Text(AppInfo.developer),
                    ),
                    ListTile(
                      leading: const Icon(Icons.public),
                      title: const Text('Website'),
                      subtitle: const Text(AppInfo.website),
                      trailing: const Icon(Icons.open_in_new, size: 18),
                      onTap: () => _open(AppInfo.website),
                    ),
                    ListTile(
                      leading: const Icon(Icons.source_outlined),
                      title: const Text('Mã nguồn'),
                      subtitle: const Text(AppInfo.repository),
                      trailing: const Icon(Icons.open_in_new, size: 18),
                      onTap: () => _open(AppInfo.repository),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Dùng AI (Anthropic Claude, Google Gemini, OpenAI hoặc API tương thích OpenAI) '
                'để nhận diện và vẽ lại nội dung. '
                'Font chữ Be Vietnam Pro (SIL Open Font License).',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Text(
                '© ${DateTime.now().year} ${AppInfo.developer}',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => showLicensePage(
                  context: context,
                  applicationName: AppInfo.appName,
                  applicationLegalese: '© ${AppInfo.developer}',
                ),
                child: const Text('Giấy phép mã nguồn mở'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
