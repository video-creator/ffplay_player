#!/usr/bin/env python3
"""
FireRedASR2S HTTP Service
A simple HTTP server that provides speech-to-text using FireRedASR2S.

Prerequisites:
1. Clone and install FireRedASR2S:
   git clone https://github.com/FireRedTeam/FireRedASR2S.git
   cd FireRedASR2S
   pip install -r requirements.txt
   export PYTHONPATH=$PWD/:$PYTHONPATH

2. Download models (choose one method):
   # Via Hugging Face:
   pip install -U "huggingface_hub[cli]"
   huggingface-cli download FireRedTeam/FireRedASR2-AED --local-dir ./pretrained_models/FireRedASR2-AED
   huggingface-cli download FireRedTeam/FireRedVAD --local-dir ./pretrained_models/FireRedVAD
   
   # Or via ModelScope (faster in China):
   pip install -U modelscope
   modelscope download --model xukaituo/FireRedASR2-AED --local_dir ./pretrained_models/FireRedASR2-AED
   modelscope download --model xukaituo/FireRedVAD --local_dir ./pretrained_models/FireRedVAD

3. Run this service:
   python asr_service.py

Usage:
    python asr_service.py [--port 8765] [--host 127.0.0.1]

API Endpoints:
    GET  /status              - Check service status
    GET  /models/status       - Check model download status
    POST /models/download     - Download models (requires huggingface_hub or modelscope)
    POST /transcribe          - Transcribe audio file
         Body: {"audio_path": "/path/to/audio.wav"}
         Returns: {"sentences": [{"start_ms": 0, "end_ms": 1000, "text": "..."}]}
"""

import argparse
import json
import os
import sys
import subprocess
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from typing import Optional, Dict, Any

# Configuration
DEFAULT_PORT = 8765
DEFAULT_HOST = "127.0.0.1"

# Model paths - relative to FireRedASR2S directory or can be absolute
DEFAULT_FIRERED_PATH = Path(__file__).parent / "FireRedASR2S"
MODEL_PATHS = {
    "FireRedASR2-AED": "pretrained_models/FireRedASR2-AED",
    "FireRedVAD": "pretrained_models/FireRedVAD",
}

# Global ASR system instance
asr_system = None
firered_path = None
download_progress = {"downloading": False, "progress": 0, "status": "", "error": None}


def find_firered_path() -> Optional[Path]:
    """Find FireRedASR2S installation path."""
    # Check common locations
    candidates = [
        DEFAULT_FIRERED_PATH,  # Same directory as this script
        Path.home() / "FireRedASR2S",  # Home directory
        Path("/opt/FireRedASR2S"),  # System-wide
    ]
    
    # Also check PYTHONPATH
    pythonpath = os.environ.get("PYTHONPATH", "")
    for p in pythonpath.split(":"):
        if p:
            candidates.append(Path(p))
    
    for candidate in candidates:
        if (candidate / "fireredasr2s").exists():
            return candidate
    
    return None


def get_model_dir(model_name: str) -> Optional[Path]:
    """Get the model directory."""
    global firered_path
    
    if firered_path is None:
        firered_path = find_firered_path()
    
    if firered_path is None:
        return None
    
    model_rel = MODEL_PATHS.get(model_name)
    if model_rel is None:
        return None
    
    model_path = firered_path / model_rel
    if model_path.exists():
        return model_path
    
    return None


def check_models_downloaded() -> Dict[str, bool]:
    """Check if required models are downloaded."""
    status = {}
    for model_name in MODEL_PATHS.keys():
        model_dir = get_model_dir(model_name)
        status[model_name] = model_dir is not None and model_dir.exists()
    return status


def download_models(progress_callback=None) -> bool:
    """Download models using huggingface_hub or modelscope."""
    global download_progress, firered_path
    
    if download_progress["downloading"]:
        return False
    
    download_progress["downloading"] = True
    download_progress["progress"] = 0
    download_progress["status"] = "Starting download..."
    download_progress["error"] = None
    
    try:
        # Check if huggingface_hub is installed
        try:
            import huggingface_hub
            use_hf = True
        except ImportError:
            use_hf = False
        
        # Check if modelscope is installed
        try:
            import modelscope
            use_ms = True
        except ImportError:
            use_ms = False
        
        if not use_hf and not use_ms:
            download_progress["error"] = "Please install huggingface_hub or modelscope"
            download_progress["status"] = "Error: huggingface_hub or modelscope not installed"
            download_progress["downloading"] = False
            return False
        
        # Determine base path for models
        if firered_path is None:
            firered_path = DEFAULT_FIRERED_PATH
        
        pretrained_dir = firered_path / "pretrained_models"
        pretrained_dir.mkdir(parents=True, exist_ok=True)
        
        total_models = len(MODEL_PATHS)
        current = 0
        
        for model_name, model_rel in MODEL_PATHS.items():
            download_progress["status"] = f"Downloading {model_name}..."
            current += 1
            download_progress["progress"] = int((current - 0.5) / total_models * 100)
            
            model_path = pretrained_dir / model_name.split("-")[-1]  # e.g., "AED" or "VAD"
            
            if model_path.exists():
                download_progress["status"] = f"{model_name} already exists, skipping..."
                download_progress["progress"] = int(current / total_models * 100)
                continue
            
            if use_hf:
                # Use Hugging Face
                download_progress["status"] = f"Downloading {model_name} from Hugging Face..."
                repo_id = f"FireRedTeam/{model_name}"
                try:
                    from huggingface_hub import snapshot_download
                    snapshot_download(repo_id=repo_id, local_dir=str(model_path))
                except Exception as e:
                    download_progress["error"] = f"Failed to download {model_name}: {e}"
                    download_progress["status"] = f"Error downloading {model_name}"
                    download_progress["downloading"] = False
                    return False
            elif use_ms:
                # Use ModelScope
                download_progress["status"] = f"Downloading {model_name} from ModelScope..."
                model_id = f"xukaituo/{model_name}"
                try:
                    from modelscope import snapshot_download
                    snapshot_download(model_id, local_dir=str(model_path))
                except Exception as e:
                    download_progress["error"] = f"Failed to download {model_name}: {e}"
                    download_progress["status"] = f"Error downloading {model_name}"
                    download_progress["downloading"] = False
                    return False
            
            download_progress["progress"] = int(current / total_models * 100)
        
        download_progress["status"] = "Download complete"
        download_progress["progress"] = 100
        download_progress["downloading"] = False
        return True
        
    except Exception as e:
        download_progress["error"] = str(e)
        download_progress["status"] = f"Error: {str(e)}"
        download_progress["downloading"] = False
        return False


def init_asr_system() -> bool:
    """Initialize the ASR system."""
    global asr_system, firered_path
    
    print(f"[ASR] init_asr_system called, current asr_system={asr_system is not None}")
    
    if asr_system is not None:
        print("[ASR] ASR system already initialized")
        return True
    
    # Find FireRedASR2S path
    if firered_path is None:
        firered_path = find_firered_path()
    
    print(f"[ASR] FireRedASR2S path: {firered_path}")
    
    if firered_path is None:
        print("[ASR ERROR] FireRedASR2S not found. Please clone and install it first:")
        print("  git clone https://github.com/FireRedTeam/FireRedASR2S.git")
        print("  cd FireRedASR2S && pip install -r requirements.txt")
        return False
    
    # Add to path
    sys.path.insert(0, str(firered_path))
    print(f"[ASR] Added to sys.path: {firered_path}")
    
    # Check models
    models_status = check_models_downloaded()
    print(f"[ASR] Models status: {models_status}")
    
    if not all(models_status.values()):
        print("[ASR ERROR] Not all models are downloaded. Available models:", models_status)
        return False
    
    try:
        # Import FireRedASR2S
        print("[ASR] Importing fireredasr2s...")
        from fireredasr2s import FireRedAsr2System, FireRedAsr2SystemConfig
        
        # Use default config - it will automatically find models in pretrained_models/
        print("[ASR] Creating FireRedAsr2SystemConfig...")
        asr_system_config = FireRedAsr2SystemConfig()
        
        print("[ASR] Creating FireRedAsr2System...")
        asr_system = FireRedAsr2System(asr_system_config)
        
        print("[ASR] ASR system initialized successfully")
        return True
        
    except ImportError as e:
        print(f"[ASR ERROR] Failed to import FireRedASR2S: {e}")
        print(f"[ASR ERROR] Make sure PYTHONPATH includes the FireRedASR2S directory")
        return False
    except Exception as e:
        print(f"[ASR ERROR] Failed to initialize ASR system: {e}")
        import traceback
        traceback.print_exc()
        return False


def transcribe_audio(audio_path: str) -> Optional[Dict[str, Any]]:
    """Transcribe audio file and return result."""
    global asr_system
    
    print(f"[ASR] transcribe_audio called with: {audio_path}")
    
    if not os.path.exists(audio_path):
        print(f"[ASR ERROR] Audio file not found: {audio_path}")
        return {"error": f"Audio file not found: {audio_path}"}
    
    # Check file size
    file_size = os.path.getsize(audio_path)
    print(f"[ASR] Audio file size: {file_size} bytes")
    
    # Initialize ASR if not already done
    if asr_system is None:
        print("[ASR] ASR system not initialized, calling init_asr_system...")
        if not init_asr_system():
            print("[ASR ERROR] ASR system initialization failed")
            return {"error": "ASR system not initialized. Check models and FireRedASR2S installation."}
    
    try:
        # Process audio
        print(f"[ASR] Processing audio with asr_system.process()...")
        result = asr_system.process(audio_path)
        print(f"[ASR] Process result: {result}")
        
        # Format result for JSON response
        sentences = []
        for sent in result.get("sentences", []):
            sentences.append({
                "start_ms": sent.get("start_ms", 0),
                "end_ms": sent.get("end_ms", 0),
                "text": sent.get("text", ""),
                "words": sent.get("words", [])
            })
        
        response = {
            "success": True,
            "sentences": sentences,
            "duration_ms": int(result.get("dur_s", 0) * 1000),
            "text": result.get("text", "")
        }
        print(f"[ASR] Returning response with {len(sentences)} sentences")
        return response
        
    except Exception as e:
        print(f"[ASR ERROR] Transcription failed: {str(e)}")
        import traceback
        traceback.print_exc()
        return {"error": f"Transcription failed: {str(e)}"}


class ASRHandler(BaseHTTPRequestHandler):
    """HTTP request handler for ASR service."""
    
    def log_message(self, format, *args):
        """Override to use custom logging."""
        print(f"[ASR Service] {args[0]}")
    
    def send_json_response(self, data: Dict[str, Any], status: int = 200):
        """Send JSON response."""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
        self.wfile.write(json.dumps(data, ensure_ascii=False).encode("utf-8"))
    
    def do_OPTIONS(self):
        """Handle CORS preflight requests."""
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()
    
    def do_GET(self):
        """Handle GET requests."""
        if self.path == "/status":
            firered = find_firered_path()
            self.send_json_response({
                "status": "running",
                "models_available": asr_system is not None,
                "firered_installed": firered is not None,
                "firered_path": str(firered) if firered else None
            })
        
        elif self.path == "/models/status":
            models_status = check_models_downloaded()
            firered = find_firered_path()
            self.send_json_response({
                "models": models_status,
                "all_downloaded": all(models_status.values()),
                "download_progress": download_progress,
                "firered_installed": firered is not None,
                "firered_path": str(firered) if firered else None
            })
        
        else:
            self.send_json_response({"error": "Not found"}, 404)
    
    def do_POST(self):
        """Handle POST requests."""
        content_length = int(self.headers.get("Content-Length", 0))
        print(f"[ASR] POST request: Content-Length={content_length}")
        body = self.rfile.read(content_length).decode("utf-8")
        print(f"[ASR] POST body: {body}")
        
        try:
            data = json.loads(body) if body else {}
            print(f"[ASR] Parsed JSON data: {data}")
        except json.JSONDecodeError as e:
            print(f"[ASR] JSON decode error: {e}")
            self.send_json_response({"error": "Invalid JSON"}, 400)
            return
        
        if self.path == "/transcribe":
            audio_path = data.get("audio_path")
            if not audio_path:
                self.send_json_response({"error": "audio_path is required"}, 400)
                return
            
            result = transcribe_audio(audio_path)
            if "error" in result:
                self.send_json_response(result, 500)
            else:
                self.send_json_response(result)
        
        elif self.path == "/models/download":
            if download_progress["downloading"]:
                self.send_json_response({
                    "error": "Download already in progress",
                    "progress": download_progress
                }, 400)
                return
            
            # Check if FireRedASR2S is installed
            if find_firered_path() is None:
                self.send_json_response({
                    "error": "FireRedASR2S not installed. Please clone and install it first.",
                    "hint": "git clone https://github.com/FireRedTeam/FireRedASR2S.git && cd FireRedASR2S && pip install -r requirements.txt"
                }, 400)
                return
            
            # Start download in background thread
            def download_thread():
                download_models()
            
            thread = threading.Thread(target=download_thread, daemon=True)
            thread.start()
            
            self.send_json_response({
                "status": "Download started",
                "progress": download_progress
            })
        
        else:
            self.send_json_response({"error": "Not found"}, 404)


def run_server(host: str, port: int):
    """Run the HTTP server."""
    server_address = (host, port)
    httpd = HTTPServer(server_address, ASRHandler)
    
    print(f"ASR Service running at http://{host}:{port}")
    print("Press Ctrl+C to stop")
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        httpd.shutdown()


def main():
    parser = argparse.ArgumentParser(description="FireRedASR2S HTTP Service")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Server port")
    parser.add_argument("--host", type=str, default=DEFAULT_HOST, help="Server host")
    parser.add_argument("--download-models", action="store_true", help="Download models and exit")
    
    args = parser.parse_args()
    
    if args.download_models:
        print("Downloading models...")
        if download_models():
            print("Models downloaded successfully")
        else:
            print("Failed to download models")
            sys.exit(1)
        return
    
    # Check FireRedASR2S installation
    firered = find_firered_path()
    if firered is None:
        print("WARNING: FireRedASR2S not found!")
        print("Please install it first:")
        print("  git clone https://github.com/FireRedTeam/FireRedASR2S.git")
        print("  cd FireRedASR2S && pip install -r requirements.txt")
        print("")
    else:
        print(f"Found FireRedASR2S at: {firered}")
        sys.path.insert(0, str(firered))
    
    # Check models on startup
    models_status = check_models_downloaded()
    if not all(models_status.values()):
        print("Warning: Not all models are downloaded.")
        print(f"Model status: {models_status}")
        print("Run with --download-models or call POST /models/download")
    
    run_server(args.host, args.port)


if __name__ == "__main__":
    main()
