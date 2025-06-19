
import 'package:flutter/material.dart';
import 'package:flutter_chess_board/flutter_chess_board.dart';

class ChessGameScreen extends StatefulWidget {
  final String gameId;
  final String token;

  ChessGameScreen({required this.gameId, required this.token});

  @override
  _ChessGameScreenState createState() => _ChessGameScreenState();
}

class _ChessGameScreenState extends State<ChessGameScreen> {
  late ChessBoardController controller;
  late WebSocket _socket;

  @override
  void initState() {
    super.initState();
    controller = ChessBoardController();
    connectToGameStream();
  }

  void connectToGameStream() async {
    final url = 'wss://socket.lichess.org/api/board/game/stream/${widget.gameId}?token=${widget.token}';
    _socket = await WebSocket.connect(url);
    _socket.listen((event) {
      final data = json.decode(event);
      if (data['type'] == 'gameFull' || data['type'] == 'gameState') {
        final moves = data['state']?['moves'] ?? data['moves'];
        if (moves != null && moves.isNotEmpty) {
          final moveList = moves.split(' ');
          controller.resetBoard();
          for (var move in moveList) {
            controller.makeMoveWithAlgebraicNotation(move);
          }
        }
      }
    });
  }

  void sendMove(String from, String to) {
    final move = '$from$to';
    final msg = json.encode({'from': from, 'to': to});
    _socket.add(msg);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Playing Game')),
      body: Column(
        children: [
          ChessBoard(
            controller: controller,
            boardColor: BoardColor.brown,
            onMove: () {
              final lastMove = controller.getLastMove();
              sendMove(lastMove.from, lastMove.to);
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _socket.close();
    super.dispose();
  }
}
