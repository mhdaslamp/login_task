import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

void main() => runApp(MyApp());

const LICHESS_CLIENT_ID = 'lichess.org'; // Public client
const REDIRECT_URI = 'com.example.lichessapp://oauthredirect';
const LICHESS_API = 'https://lichess.org/api';

final FlutterAppAuth appAuth = FlutterAppAuth();

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lichess Login',
      home: LichessLoginPage(),
    );
  }
}

class LichessLoginPage extends StatefulWidget {
  @override
  _LichessLoginPageState createState() => _LichessLoginPageState();
}

class _LichessLoginPageState extends State<LichessLoginPage> {
  String? username;
  int? blitzRating;
  String? accessToken;
  WebSocketChannel? eventChannel;
  StreamSubscription? eventSubscription;

  Future<void> loginWithLichess() async {
    try {
      final request = AuthorizationTokenRequest(
        LICHESS_CLIENT_ID,
        REDIRECT_URI,
        serviceConfiguration: AuthorizationServiceConfiguration(
          authorizationEndpoint: 'https://lichess.org/oauth',
          tokenEndpoint: 'https://lichess.org/api/token',
        ),
        scopes: ['preference:read', 'challenge:write', 'board:play'],
      );

      print('🔑 OAuth request: ${jsonEncode({
        'clientId': request.clientId,
        'redirectUrl': request.redirectUrl,
        'scopes': request.scopes,
        'authorizationEndpoint': request.serviceConfiguration?.authorizationEndpoint ?? 'N/A',
        'tokenEndpoint': request.serviceConfiguration?.tokenEndpoint ?? 'N/A',
      })}');

      final result = await appAuth.authorizeAndExchangeCode(request);

      if (result != null) {
        final userInfo = await fetchUserInfo(result.accessToken!);
        setState(() {
          accessToken = result.accessToken;
          username = userInfo['username'];
          blitzRating = userInfo['perfs']?['blitz']?['rating'];
        });
      }
    } catch (e) {
      print('❌ Error during login: $e');
    }
  }

  Future<Map<String, dynamic>> fetchUserInfo(String token) async {
    final response = await http.get(
      Uri.parse('$LICHESS_API/account'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception('❌ Failed to fetch user info');
    }
  }

  Future<void> createChallenge() async {
    if (accessToken == null) return;

    try {
      final response = await http.post(
        Uri.parse('$LICHESS_API/board/seek'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'rated=false&clock.limit=300&clock.increment=0&color=random',
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        print('✅ Seek created. Waiting for player...');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Game created. Waiting for player...')),
        );
        listenToEventStream(accessToken!);
      } else {
        print('❌ Failed to create seek: ${response.body}');
      }
    } catch (e) {
      print('❌ Error creating challenge: $e');
    }
  }

  void listenToEventStream(String token) async {
    // Close any existing connection
    await eventChannel?.sink.close();
    await eventSubscription?.cancel();

    try {
      final channel = IOWebSocketChannel.connect(
        Uri.parse('wss://lichess.org/api/stream/event'),
        headers: {
          'Authorization': 'Bearer $token',
          'User-Agent': 'LichessApp/1.0',
          'Accept': 'application/vnd.lichess.v3+json',
        },
      );

      setState(() {
        eventChannel = channel;
      });

      print('✅ WebSocket connection established');

      eventSubscription = channel.stream.listen(
            (message) {
          print('📩 Event: $message');
          try {
            final data = jsonDecode(message);
            if (data['type'] == 'gameStart') {
              final gameId = data['game']['id'];
              final opponent = data['game']['opponent']['username'];
              print('🎮 Game started with $opponent (ID: $gameId)');

              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ChessGameScreen(
                    gameId: gameId,
                    token: token,
                    opponent: opponent,
                  ),
                ),
              );
            }
          } catch (e) {
            print('❌ Error parsing event: $e');
          }
        },
        onError: (error) {
          print('❌ WebSocket error: $error');
        },
        onDone: () {
          print('ℹ️ WebSocket connection closed');
        },
      );
    } catch (e) {
      print('❌ WebSocket connection failed: $e');
      fallbackToHttpStream(token);
    }
  }
  void fallbackToHttpStream(String token) async {
    print('🔄 Attempting HTTP event stream fallback');

    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse('https://lichess.org/api/stream/event'));
      request.headers['Authorization'] = 'Bearer $token';
      request.headers['Accept'] = 'application/vnd.lichess.v3+json';

      final response = await client.send(request);
      response.stream
          .transform(utf8.decoder)
          .listen((data) {
        print('📩 HTTP Stream event: $data');
        // Handle events same as WebSocket
      }, onError: (e) {
        print('❌ HTTP Stream error: $e');
      }, onDone: () {
        print('ℹ️ HTTP Stream closed');
      });
    } catch (e) {
      print('❌ HTTP Stream failed: $e');
    }
  }

  @override
  void dispose() {
    eventChannel?.sink.close();
    eventSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Login with Lichess')),
      body: Center(
        child: username == null
            ? ElevatedButton(
          onPressed: loginWithLichess,
          child: Text('Login with Lichess'),
        )
            : Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Hello, $username!'),
            Text('Blitz Rating: $blitzRating'),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: createChallenge,
              child: Text('Play Game'),
            ),
          ],
        ),
      ),
    );
  }
}

class ChessGameScreen extends StatefulWidget {
  final String gameId;
  final String token;
  final String opponent;

  ChessGameScreen({
    required this.gameId,
    required this.token,
    required this.opponent,
  });

  @override
  _ChessGameScreenState createState() => _ChessGameScreenState();
}

class _ChessGameScreenState extends State<ChessGameScreen> {
  late IOWebSocketChannel gameChannel;
  String gameState = 'Loading...';

  @override
  void initState() {
    super.initState();
    connectToGame();
  }

  void connectToGame() {
    final uri = Uri.parse('wss://lichess.org/api/board/game/stream/${widget.gameId}');

    gameChannel = IOWebSocketChannel.connect(
      uri,
      headers: {
        'Authorization': 'Bearer ${widget.token}',
      },
    );

    gameChannel.stream.listen((message) {
      if (message.trim().isEmpty) return;

      try {
        final data = jsonDecode(message);
        print('Game update: $data');

        if (data['type'] == 'gameFull') {
          setState(() {
            gameState = 'Game started with ${widget.opponent}';
          });
        } else if (data['type'] == 'gameState') {
          setState(() {
            gameState = 'Game in progress - moves: ${data['moves']}';
          });
        }
      } catch (e) {
        print('Error parsing game message: $e');
      }
    }, onError: (err) {
      print('Game WebSocket error: $err');
    }, onDone: () {
      print('Game WebSocket closed');
    });
  }

  @override
  void dispose() {
    gameChannel.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Game vs ${widget.opponent}')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Game ID: ${widget.gameId}'),
            Text('Opponent: ${widget.opponent}'),
            SizedBox(height: 20),
            Text(gameState),
          ],
        ),
      ),
    );
  }
}