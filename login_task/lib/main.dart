import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';

// Enhanced Logger with different log levels
class GameLogger {
  static const bool _debugMode = true;

  static void debug(String message) {
    if (_debugMode) {
      _log('DEBUG', message);
    }
  }

  static void info(String message) {
    _log('INFO', message);
  }

  static void warning(String message) {
    _log('WARNING', message);
  }

  static void error(String message, [dynamic error, StackTrace? stackTrace]) {
    _log('ERROR', message, error, stackTrace);
  }

  static void _log(String level, String message,
      [dynamic error, StackTrace? stackTrace]) {
    final timestamp = DateTime.now().toIso8601String();
    final log = '$timestamp [$level] $message';
    debugPrint(log);

    if (error != null) {
      debugPrint('Error Details: $error');
    }
    if (stackTrace != null) {
      debugPrint('Stack Trace: $stackTrace');
    }
  }
}

void main() {
  runZonedGuarded(() {
    runApp(MyApp());
  }, (error, stackTrace) {
    GameLogger.error('Uncaught application error', error, stackTrace);
  });
}

const LICHESS_CLIENT_ID = 'lichess.org';
const REDIRECT_URI = 'com.example.lichessapp://oauthredirect';
const LICHESS_API = 'https://lichess.org/api';

final FlutterAppAuth appAuth = FlutterAppAuth();

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lichess Client',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
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
  bool isLoading = false;

  Future<void> loginWithLichess() async {
    setState(() => isLoading = true);
    GameLogger.info('Initiating Lichess OAuth flow');

    try {
      final result = await appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          LICHESS_CLIENT_ID,
          REDIRECT_URI,
          serviceConfiguration: AuthorizationServiceConfiguration(
            authorizationEndpoint: 'https://lichess.org/oauth',
            tokenEndpoint: 'https://lichess.org/api/token',
          ),
          scopes: ['preference:read', 'challenge:write', 'board:play'],
        ),
      );

      if (result?.accessToken != null) {
        GameLogger.info('OAuth successful, fetching user profile');
        final info = await fetchUserInfo(result!.accessToken!);
        setState(() {
          accessToken = result.accessToken;
          username = info['username'];
          blitzRating = info['perfs']?['blitz']?['rating'];
          isLoading = false;
        });
        GameLogger.debug('User profile loaded - Username: $username, Blitz Rating: $blitzRating');
      } else {
        GameLogger.warning('OAuth returned null access token');
        setState(() => isLoading = false);
      }
    } catch (e, stack) {
      GameLogger.error('OAuth flow failed', e, stack);
      setState(() => isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Login failed: ${e.toString()}')),
      );
    }
  }

  Future<Map<String, dynamic>> fetchUserInfo(String token) async {
    GameLogger.debug('Fetching user info from Lichess API');
    try {
      final response = await http.get(
        Uri.parse('$LICHESS_API/account'),
        headers: {'Authorization': 'Bearer $token'},
      );

      GameLogger.debug('User info response status: ${response.statusCode}');
      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        throw Exception('API request failed with status ${response.statusCode}: ${response.body}');
      }
    } catch (e, stack) {
      GameLogger.error('Failed to fetch user info', e, stack);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Lichess Login')),
      body: Center(
        child: isLoading
            ? CircularProgressIndicator()
            : username == null
            ? ElevatedButton(
          child: Text('Login with Lichess'),
          onPressed: loginWithLichess,
        )
            : Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Hello, $username!', style: TextStyle(fontSize: 24)),
            SizedBox(height: 8),
            Text('Blitz Rating: $blitzRating',
                style: TextStyle(fontSize: 18)),
            SizedBox(height: 20),
            ElevatedButton(
              child: Text('Start Game'),
              onPressed: () {
                GameLogger.info('Navigating to game page');
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => GamePage(
                      accessToken: accessToken!,
                      username: username!,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class GamePage extends StatefulWidget {
  final String accessToken;
  final String username;

  const GamePage({
    Key? key,
    required this.accessToken,
    required this.username,
  }) : super(key: key);

  @override
  _GamePageState createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> {
  String? gameId;
  String? myColor;
  String? opponentName;
  String? opponentRating;
  bool isMyTurn = false;
  bool gameActive = true;
  String gameState = 'Initializing game...';
  List<String> moveHistory = [];
  String? lastOpponentMove;
  String? gameStatus;

  int reconnectAttempts = 0;
  Timer? reconnectTimer;
  http.Client? eventClient;
  http.Client? gameClient;
  Timer? pingTimer;

  @override
  void initState() {
    super.initState();
    GameLogger.info('GamePage initialized for user ${widget.username}');
    startSeek();
  }

  Future<void> startSeek() async {
    GameLogger.info('Creating game seek request');
    setState(() => gameState = 'Creating game seek...');

    try {
      final response = await http.post(
        Uri.parse('$LICHESS_API/board/seek'),
        headers: {
          'Authorization': 'Bearer ${widget.accessToken}',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'rated=false&clock.limit=300&clock.increment=0&color=random',
      );

      GameLogger.debug('Seek response: ${response.statusCode} - ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 204) {
        GameLogger.info('Game seek created successfully');
        setState(() => gameState = 'Seek created - waiting for opponent...');
        listenToEventStream();
      } else {
        GameLogger.error('Failed to create seek',
            'Status: ${response.statusCode}, Body: ${response.body}');
        setState(() => gameState = 'Failed to create seek: ${response.body}');
      }
    } catch (e, stack) {
      GameLogger.error('Exception while creating seek', e, stack);
      setState(() => gameState = 'Error creating seek: ${e.toString()}');
    }
  }

  void listenToEventStream() {
    GameLogger.info('Initializing event stream listener');

    eventClient?.close();
    eventClient = http.Client();
    final request = http.Request(
      'GET',
      Uri.parse('https://lichess.org/api/stream/event'),
    );
    request.headers.addAll({
      'Authorization': 'Bearer ${widget.accessToken}',
      'Accept': 'application/x-ndjson',
    });

    GameLogger.debug('Sending event stream request');

    eventClient!.send(request).then((response) {
      GameLogger.info('Event stream connected, HTTP status: ${response.statusCode}');

      response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        _handleEventStreamLine(line);
      }, onError: (e) {
        GameLogger.error('Event stream error occurred', e);
        scheduleReconnect('Event stream error');
      }, onDone: () {
        GameLogger.warning('Event stream closed by server');
        scheduleReconnect('Event stream closed');
      });
    }).catchError((e) {
      GameLogger.error('Failed to establish event stream connection', e);
      scheduleReconnect('Event stream connection failed');
    });
  }

  void _handleEventStreamLine(String line) {
    if (line.trim().isEmpty) {
      GameLogger.debug('Received empty line from event stream (keep-alive)');
      return;
    }

    try {
      GameLogger.debug('Raw event stream message: $line');
      final data = json.decode(line);

      if (data['type'] == 'gameStart') {
        final gameId = data['game']['id'];
        GameLogger.info('Game started notification received, gameId: $gameId');
        setState(() {
          this.gameId = gameId;
          gameState = 'Game started! Connecting...';
        });
        connectToGame();
      } else {
        GameLogger.debug('Unhandled event type: ${data['type']}');
      }
    } catch (e, stack) {
      GameLogger.error('Error parsing event stream message', e, stack);
    }
  }

  void connectToGame() {
    if (gameId == null) {
      GameLogger.error('Aborting game connection - gameId is null');
      return;
    }

    GameLogger.info('Connecting to game stream for game $gameId');

    gameClient?.close();
    gameClient = http.Client();
    final request = http.Request(
      'GET',
      Uri.parse('https://lichess.org/api/board/game/stream/$gameId'),
    );
    request.headers.addAll({
      'Authorization': 'Bearer ${widget.accessToken}',
      'Accept': 'application/x-ndjson',
    });

    GameLogger.debug('Sending game stream request');

    gameClient!.send(request).then((response) {
      GameLogger.info('Game stream connected, HTTP status: ${response.statusCode}');
      setState(() => gameState = 'Connected to game $gameId');

      // Start ping timer to maintain connection
      pingTimer?.cancel();
      pingTimer = Timer.periodic(Duration(seconds: 20), (_) {
        GameLogger.debug('Sending keep-alive ping');
      });

      response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) => _handleGameStreamLine(line),
        onError: (e) => _handleGameStreamError(e),
        onDone: () => _handleGameStreamDone(),
        cancelOnError: true,
      );
    }).catchError((e) {
      GameLogger.error('Failed to connect to game stream', e);
      scheduleReconnect('Game stream connection failed');
    });
  }

  void _handleGameStreamLine(String line) {
    if (line.trim().isEmpty) {
      GameLogger.debug('Received empty line from game stream (keep-alive)');
      return;
    }

    try {
      GameLogger.debug('Raw game stream message: $line');
      handleGameMessage(line);
    } catch (e, stack) {
      GameLogger.error('Error processing game stream message', e, stack);
    }
  }

  void _handleGameStreamError(dynamic e) {
    GameLogger.error('Game stream error occurred', e);
    scheduleReconnect('Game stream error');
  }

  void _handleGameStreamDone() {
    GameLogger.warning('Game stream closed by server');
    scheduleReconnect('Game stream closed');
  }

  void handleGameMessage(String msg) {
    try {
      final data = json.decode(msg);
      GameLogger.info('Processing game message of type: ${data['type']}');

      if (data['type'] == 'gameFull') {
        final opponent = data[data['white']['id'] == widget.username ? 'black' : 'white'];
        GameLogger.debug('Game full details: ${{
          'opponent': opponent['username'],
          'opponentRating': opponent['rating'],
          'color': data['white']['id'] == widget.username ? 'white' : 'black',
          'status': data['status'],
          'initialMoves': data['state']['moves']?.toString().split(' ') ?? []
        }}');

        setState(() {
          myColor = data['white']['id'] == widget.username ? 'white' : 'black';
          isMyTurn = myColor == 'white';
          opponentName = opponent['username'];
          opponentRating = opponent['rating']?.toString();
          gameStatus = data['status'];
          gameState = 'Game started - you are $myColor';
          moveHistory = (data['state']['moves']?.toString().split(' ') ?? []);
          GameLogger.debug('Initial move history: $moveHistory');
        });
      } else if (data['type'] == 'gameState') {
        final moves = data['moves']?.toString().split(' ') ?? [];
        final lastMove = moves.isNotEmpty ? moves.last : null;
        final opponentJustMoved = myColor == 'white'
            ? (moves.length.isOdd ? lastMove : null)
            : (moves.length.isEven ? lastMove : null);

        GameLogger.debug('Game state update: ${{
          'moveCount': moves.length,
          'lastMove': lastMove,
          'isMyTurn': data['isMyTurn'],
          'status': data['status'],
          'wtime': data['wtime'],
          'btime': data['btime']
        }}');

        setState(() {
          moveHistory = moves;
          lastOpponentMove = opponentJustMoved;
          isMyTurn = data['isMyTurn'] ?? false;
          gameState = isMyTurn ? 'Your turn to move!' : 'Waiting for opponent...';
          gameStatus = data['status'];
        });
      } else if (data['type'] == 'gameFinish') {
        GameLogger.info('Game finished with status: ${data['status']}');
        setState(() {
          gameActive = false;
          gameState = 'Game finished: ${data['status']}';
          gameStatus = data['status'];
          isMyTurn = false;
        });
      } else if (data['type'] == 'chatLine') {
        GameLogger.debug('Chat message: ${data['username']}: ${data['text']}');
      } else {
        GameLogger.debug('Unhandled game message type: ${data['type']}');
      }
    } catch (e, stack) {
      GameLogger.error('Failed to handle game message', e, stack);
    }
  }

  void scheduleReconnect(String reason) {
    if (!gameActive) {
      GameLogger.debug('Not scheduling reconnect - game is not active');
      return;
    }

    if (reconnectAttempts >= 3) {
      GameLogger.warning('Maximum reconnection attempts (3) reached');
      setState(() {
        gameState = 'Connection failed after multiple attempts';
        gameActive = false;
      });
      return;
    }

    reconnectAttempts++;
    final delay = Duration(seconds: reconnectAttempts * 2);
    GameLogger.warning('$reason - Scheduling reconnect in ${delay.inSeconds}s (attempt $reconnectAttempts/3)');

    setState(() {
      gameState = '$reason - Reconnecting in ${delay.inSeconds}s...';
    });

    reconnectTimer?.cancel();
    reconnectTimer = Timer(delay, () {
      if (gameId == null) {
        GameLogger.info('Attempting to reconnect event stream');
        listenToEventStream();
      } else {
        GameLogger.info('Attempting to reconnect game stream');
        connectToGame();
      }
    });
  }

  Future<void> makeMove(String move) async {
    if (!isMyTurn || !gameActive || gameId == null) {
      GameLogger.warning('Invalid move attempt - isMyTurn: $isMyTurn, gameActive: $gameActive, gameId: $gameId');
      return;
    }

    GameLogger.info('Attempting to make move: $move');
    try {
      final response = await http.post(
        Uri.parse('$LICHESS_API/board/game/$gameId/move/$move'),
        headers: {'Authorization': 'Bearer ${widget.accessToken}'},
      );

      GameLogger.debug('Move response: ${response.statusCode} - ${response.body}');
      if (response.statusCode != 200) {
        GameLogger.error('Move failed', 'Status: ${response.statusCode}, Body: ${response.body}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Move failed: ${response.body}')),
        );
      }
    } catch (e, stack) {
      GameLogger.error('Exception while making move', e, stack);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error making move: ${e.toString()}')),
      );
    }
  }

  @override
  void dispose() {
    GameLogger.info('Disposing GamePage resources');
    reconnectTimer?.cancel();
    pingTimer?.cancel();
    eventClient?.close();
    gameClient?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(opponentName != null
            ? 'vs $opponentName${opponentRating != null ? ' ($opponentRating)' : ''}'
            : 'Lichess Game'),
        actions: [
          if (!gameActive)
            IconButton(
              icon: Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Game status card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(gameState, style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isMyTurn ? Colors.green : Colors.blue,
                    )),
                    if (gameId != null) SizedBox(height: 8),
                    if (gameId != null) Text('Game ID: $gameId'),
                    if (myColor != null) SizedBox(height: 8),
                    if (myColor != null) Text('You are: ${myColor!.toUpperCase()}'),
                    if (gameStatus != null) SizedBox(height: 8),
                    if (gameStatus != null) Text('Status: $gameStatus'),
                  ],
                ),
              ),
            ),

            SizedBox(height: 20),

            // Last move section
            if (lastOpponentMove != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    children: [
                      Text('Last opponent move: ',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(lastOpponentMove!,
                          style: TextStyle(fontSize: 16)),
                    ],
                  ),
                ),
              ),

            SizedBox(height: 20),

            // Move buttons (only shown when it's the player's turn)
            if (isMyTurn && gameActive && myColor != null)
              Column(
                children: [
                  Text('Make your move:', style: TextStyle(fontSize: 16)),
                  SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: myColor == 'white'
                        ? [
                      _buildMoveButton('e2e4'),
                      _buildMoveButton('g1f3'),
                      _buildMoveButton('d2d4'),
                      _buildMoveButton('c2c4'),
                    ]
                        : [
                      _buildMoveButton('e7e5'),
                      _buildMoveButton('g8f6'),
                      _buildMoveButton('d7d5'),
                      _buildMoveButton('c7c5'),
                    ],
                  ),
                ],
              )
            else if (gameActive)
              Text('Waiting for opponent to move...',
                  style: TextStyle(fontSize: 16, color: Colors.blue)),

            SizedBox(height: 20),

            // Move history section
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Move History:',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      SizedBox(height: 8),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Text(
                            moveHistory.isEmpty ? 'No moves yet' : moveHistory.join(' '),
                            style: TextStyle(fontSize: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMoveButton(String move) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      onPressed: () => makeMove(move),
      child: Text(move),
    );
  }
}