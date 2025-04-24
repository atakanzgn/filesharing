import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Android-iPad Dosya Paylaşımı',
      theme: ThemeData.dark(),
      debugShowCheckedModeBanner: false,
      home: FileShareScreen(),
    );
  }
}

class FileShareScreen extends StatefulWidget {
  @override
  _FileShareScreenState createState() => _FileShareScreenState();
}

class _FileShareScreenState extends State<FileShareScreen> {
  HttpServer? _server;
  String _localIp = "Bağlantı bekleniyor...";
  String _serverUrl = "";
  String _status = "Başlatılıyor";
  bool _isServerRunning = false;
  String? _selectedFilePath;
  String? _selectedFileName;
  final int _port = 8080;
  final info = NetworkInfo();

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    await [
      Permission.location,
      Permission.storage,
    ].request();
  }

  Future<void> _startServer() async {
    if (_isServerRunning) return;

    try {
      // Yerel dosya dizini oluşturma
      final appDocDir = await getApplicationDocumentsDirectory();
      final sharedDir = Directory('${appDocDir.path}/shared');
      if (!sharedDir.existsSync()) {
        sharedDir.createSync(recursive: true);
      }

      // Statik dosya sunucusu oluşturma
      final staticHandler = createStaticHandler(
        sharedDir.path,
        defaultDocument: 'index.html',
      );

      // Ek yönlendirmeler için ara yazılım (middleware)
      final handler = const shelf.Pipeline()
          .addMiddleware(shelf.logRequests())
          .addHandler((request) async {
            if (request.method == 'POST' && request.url.path == 'upload') {
              try {
                final body = await request.read().toList();
                final bodyBytes = body.expand((b) => b).toList();
                final fileName = request.headers['filename'] ?? 'unnamed_file';
                
                final file = File('${sharedDir.path}/$fileName');
                await file.writeAsBytes(bodyBytes);
                
                return shelf.Response.ok('Dosya alındı: $fileName');
              } catch (e) {
                return shelf.Response.internalServerError(body: 'Hata: $e');
              }
            }
            return staticHandler(request);
          });

      // Sunucuyu başlatma
      _server = await shelf_io.serve(
        handler,
        InternetAddress.anyIPv4,
        _port,
      );

      // IP adresini alma
      _localIp = await info.getWifiIP() ?? "IP bulunamadı";
      _serverUrl = 'http://$_localIp:$_port';

      setState(() {
        _isServerRunning = true;
        _status = "Sunucu çalışıyor";
      });
      
      print('Sunucu çalışıyor: $_serverUrl');
    } catch (e) {
      setState(() {
        _status = "Sunucu başlatma hatası: $e";
      });
      print('Sunucu başlatma hatası: $e');
    }
  }

  Future<void> _stopServer() async {
    if (_server != null) {
      await _server!.close();
      _server = null;
      setState(() {
        _isServerRunning = false;
        _status = "Sunucu durduruldu";
        _localIp = "Bağlantı bekleniyor...";
        _serverUrl = "";
      });
    }
  }

  Future<void> _selectFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result != null) {
      setState(() {
        _selectedFilePath = result.files.single.path;
        _selectedFileName = result.files.single.name;
        _status = "Seçilen dosya: $_selectedFileName";
      });
      
      // Seçilen dosyayı paylaşım klasörüne kopyala
      if (_selectedFilePath != null) {
        final appDocDir = await getApplicationDocumentsDirectory();
        final sharedDir = Directory('${appDocDir.path}/shared');
        final File sourceFile = File(_selectedFilePath!);
        final targetPath = '${sharedDir.path}/$_selectedFileName';
        await sourceFile.copy(targetPath);
        setState(() {
          _status = "Dosya paylaşıma hazır: $_selectedFileName";
        });
      }
    }
  }

  Future<void> _downloadFile() async {
    final targetIpController = TextEditingController();
    final targetFileController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Dosya İndir'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: targetIpController,
              decoration: InputDecoration(
                labelText: 'Karşı Cihaz IP Adresi',
                hintText: 'Örn: 192.168.1.5',
              ),
            ),
            TextField(
              controller: targetFileController,
              decoration: InputDecoration(
                labelText: 'Dosya Adı',
                hintText: 'Örn: document.pdf',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('İptal'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              if (targetIpController.text.isNotEmpty && 
                  targetFileController.text.isNotEmpty) {
                final url = 'http://${targetIpController.text}:$_port/${targetFileController.text}';
                await _downloadFileFromUrl(url, targetFileController.text);
              }
            },
            child: Text('İndir'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadFileFromUrl(String url, String fileName) async {
    setState(() {
      _status = "İndiriliyor: $fileName...";
    });
    
    try {
      final response = await http.get(Uri.parse(url));
      
      if (response.statusCode == 200) {
        final appDocDir = await getApplicationDocumentsDirectory();
        final file = File('${appDocDir.path}/downloads/$fileName');
        
        // Klasör yoksa oluştur
        final dir = Directory('${appDocDir.path}/downloads');
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
        }
        
        await file.writeAsBytes(response.bodyBytes);
        setState(() {
          _status = "İndirme tamamlandı: $fileName";
        });
      } else {
        setState(() {
          _status = "İndirme başarısız: HTTP ${response.statusCode}";
        });
      }
    } catch (e) {
      setState(() {
        _status = "İndirme hatası: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Android-iPad Dosya Paylaşımı'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Durum: $_status',
                      style: TextStyle(fontSize: 16),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Sunucu Adresi: $_serverUrl',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 20),
            
            // Sunucu kontrol butonları
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isServerRunning ? null : _startServer,
                    icon: Icon(Icons.play_arrow),
                    label: Text('Sunucuyu Başlat'),
                    style: ElevatedButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isServerRunning ? _stopServer : null,
                    icon: Icon(Icons.stop),
                    label: Text('Sunucuyu Durdur'),
                    style: ElevatedButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 20),
            
            // Dosya işlemleri butonları
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Dosya İşlemleri',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 16),
                    Text(
                      _selectedFileName != null 
                          ? 'Seçili dosya: $_selectedFileName'
                          : 'Dosya seçilmedi',
                      style: TextStyle(fontSize: 16),
                    ),
                    SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _selectFile,
                            icon: Icon(Icons.upload_file),
                            label: Text('Dosya Seç ve Paylaş'),
                            style: ElevatedButton.styleFrom(
                              padding: EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _downloadFile,
                            icon: Icon(Icons.download),
                            label: Text('Dosya İndir'),
                            style: ElevatedButton.styleFrom(
                              padding: EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            
            SizedBox(height: 20),
            // Kullanım yönergeleri
            Expanded(
              child: SingleChildScrollView(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Kullanım Talimatları',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          '1. Android cihazınızda Hotspot açın\n'
                          '2. iPad\'inizi bu Hotspot\'a bağlayın\n'
                          '3. Bu uygulamada "Sunucuyu Başlat" düğmesine tıklayın\n'
                          '4. Dosya Seç ve Paylaş düğmesi ile paylaşmak istediğiniz dosyayı seçin\n'
                          '5. Diğer cihazda, web tarayıcısında sunucu adresini açın\n'
                          '6. Veya "Dosya İndir" seçeneğini kullanarak direkt indirebilirsiniz',
                          style: TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _stopServer();
    super.dispose();
  }
}