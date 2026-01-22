from flask import Flask, request, jsonify
from flask_cors import CORS
import chess
import chess.engine
import atexit
import os
import sys
from threading import Lock
from pathlib import Path

app = Flask(__name__)
CORS(app)

def find_stockfish():
    """Find stockfish.exe in same directory as the executable"""
    # Get the directory where the EXE is actually located
    if getattr(sys, 'frozen', False):
        # Running as compiled exe - use argv[0] to get actual exe path
        application_path = os.path.dirname(os.path.abspath(sys.argv[0]))
    else:
        # Running as script
        application_path = os.path.dirname(os.path.abspath(__file__))
    
    application_path = Path(application_path)
    stockfish_path = application_path / 'stockfish.exe'
    
    print(f"[DEBUG] Looking for stockfish.exe in: {application_path}")
    print(f"[DEBUG] Full path: {stockfish_path}")
    print(f"[DEBUG] Exists: {stockfish_path.exists()}")
    
    if stockfish_path.exists():
        print(f"[OK] Found Stockfish: {stockfish_path}")
        return str(stockfish_path)
    
    print(f"[ERROR] stockfish.exe not found in: {application_path}")
    print("Please place stockfish.exe next to ChessServer.exe")
    
    # List files in directory for debugging
    print("\n[DEBUG] Files in directory:")
    try:
        for file in os.listdir(application_path):
            print(f"  - {file}")
    except:
        pass
    
    input("\nPress Enter to exit...")
    sys.exit(1)

STOCKFISH_PATH = find_stockfish()

engine = None
engine_lock = Lock()
position_cache = {}
MAX_CACHE_SIZE = 512

def initialize_engine():
    global engine
    try:
        if engine:
            engine.quit()
    except:
        pass
    
    engine = chess.engine.SimpleEngine.popen_uci(STOCKFISH_PATH)
    engine.configure({
        "Threads": 2,
        "Hash": 128,
        "Move Overhead": 0,
    })
    print("[OK] Stockfish engine ready")

initialize_engine()

def cleanup():
    global engine
    if engine:
        try:
            engine.quit()
        except:
            pass

atexit.register(cleanup)

@app.route('/analyze', methods=['POST'])
def analyze():
    global engine, position_cache
    
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Invalid JSON'}), 400
        
        fen = data.get('fen')
        
        if not fen:
            return jsonify({'error': 'No FEN provided'}), 400
        
        # Check cache
        if fen in position_cache:
            cached = position_cache[fen].copy()
            cached['cached'] = True
            return jsonify(cached)
        
        board = chess.Board(fen)
        
        with engine_lock:
            try:
                result = engine.analyse(board, chess.engine.Limit(time=0.15))
                bestmove_result = engine.play(board, chess.engine.Limit(time=0.15))
            except:
                initialize_engine()
                result = engine.analyse(board, chess.engine.Limit(time=0.15))
                bestmove_result = engine.play(board, chess.engine.Limit(time=0.15))
        
        score = result['score'].white()
        if score.is_mate():
            evaluation = 10000 if score.mate() > 0 else -10000
        else:
            evaluation = score.score()
        
        response_data = {
            'bestmove': bestmove_result.move.uci(),
            'evaluation': evaluation,
            'fen': fen,
            'cached': False
        }
        
        if len(position_cache) >= MAX_CACHE_SIZE:
            position_cache.pop(next(iter(position_cache)))
        position_cache[fen] = response_data.copy()
        
        return jsonify(response_data)
    
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/health', methods=['GET'])
def health():
    return jsonify({
        'status': 'ok',
        'engine': 'Stockfish'
    })

if __name__ == '__main__':
    print("="*50)
    print(" Stockfish Chess Server")
    print("="*50)
    print(f"[OK] Server running on http://127.0.0.1:5000")
    print("[OK] Ready to analyze positions")
    print("="*50)
    app.run(host='127.0.0.1', port=5000, debug=False, threaded=True, use_reloader=False)
