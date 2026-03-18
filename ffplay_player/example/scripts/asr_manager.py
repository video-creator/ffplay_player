#!/usr/bin/env python3
"""
ASR Manager Script
Handles ASR installation, model download, service management, and more.

Usage:
    python asr_manager.py install [--download-models] [--base-dir DIR]
    python asr_manager.py download-models [--base-dir DIR]
    python asr_manager.py start-service [--host HOST] [--port PORT] [--base-dir DIR]
    python asr_manager.py repair [--base-dir DIR]
    python asr_manager.py uninstall [--base-dir DIR]
    python asr_manager.py check-status [--base-dir DIR]
"""

import sys
import os

# IMPORTANT: Change to a safe working directory to avoid import conflicts
# This fixes the "you should not try to import numpy from its source directory" error
# when running from a directory containing numpy source code
_original_cwd = os.getcwd()
_script_dir = os.path.dirname(os.path.abspath(__file__))
# Change to script directory or user home directory
_safe_cwd = _script_dir if os.path.isdir(_script_dir) else os.path.expanduser('~')
os.chdir(_safe_cwd)

# Also remove current directory from sys.path to prevent accidental imports
if '' in sys.path:
    sys.path.remove('')
if _original_cwd in sys.path:
    try:
        sys.path.remove(_original_cwd)
    except ValueError:
        pass

import json
import time
import argparse
import subprocess
import shutil
import threading
import signal
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Optional, Dict, Any, List

# Global variables
_base_dir: Optional[str] = None
_venv_path: Optional[str] = None
_pip_path: Optional[str] = None
_asr_path: Optional[str] = None
_install_canceled = False
_service_process = None


def output_json(event: str, data: Dict[str, Any] = None):
    """Output a JSON event for Dart to parse."""
    if data is None:
        data = {}
    output = {"event": event, **data}
    print(json.dumps(output), flush=True)


def get_base_dir(args) -> str:
    """Get the base directory for ASR installation."""
    global _base_dir
    if _base_dir:
        return _base_dir
    
    if args and hasattr(args, 'base_dir') and args.base_dir:
        _base_dir = args.base_dir
    else:
        # Default to Application Support directory
        if sys.platform == 'darwin':
            home = os.path.expanduser('~')
            _base_dir = os.path.join(home, 'Library', 'Application Support', 'com.example.ffplayPlayerExample', 'asr')
        else:
            _base_dir = os.path.join(os.path.expanduser('~'), '.ffplay_player', 'asr')
    
    os.makedirs(_base_dir, exist_ok=True)
    return _base_dir


def get_venv_site_packages(venv_path: str) -> Optional[str]:
    """Get the site-packages directory for a virtual environment."""
    # Try different Python versions
    for py_version in ['python3.11', 'python3.10', 'python3.9', 'python3.8', 'python3']:
        site_packages = os.path.join(venv_path, 'lib', py_version, 'site-packages')
        if os.path.exists(site_packages):
            return site_packages
    
    # Try to find site-packages dynamically
    venv_python = os.path.join(venv_path, 'bin', 'python')
    if os.path.exists(venv_python):
        try:
            result = subprocess.run(
                [venv_python, '-c', 'import site; print(site.getsitepackages()[0])'],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0:
                return result.stdout.strip()
        except:
            pass
    
    return None


def activate_venv(base_dir: str) -> bool:
    """Activate virtual environment and set up sys.path."""
    global _venv_path, _pip_path
    
    venv_path = os.path.join(base_dir, 'venv')
    venv_python = os.path.join(venv_path, 'bin', 'python')
    
    if not os.path.exists(venv_python):
        output_json("warning", {"message": f"venv not found at {venv_path}"})
        return False
    
    _venv_path = venv_path
    _pip_path = os.path.join(venv_path, 'bin', 'pip')
    
    # Get site-packages directory
    site_packages = get_venv_site_packages(venv_path)
    if site_packages and os.path.exists(site_packages):
        # Add to sys.path if not already there
        if site_packages not in sys.path:
            sys.path.insert(0, site_packages)
            output_json("debug", {"message": f"Added to sys.path: {site_packages}"})
        return True
    else:
        output_json("warning", {"message": f"Could not find site-packages for {venv_path}"})
        return False


def find_python() -> Optional[str]:
    """Find Python 3 executable."""
    # Check common paths
    common_paths = [
        '/opt/homebrew/bin/python3',
        '/usr/local/bin/python3',
        '/usr/bin/python3',
    ]
    
    for path in common_paths:
        if os.path.exists(path):
            try:
                result = subprocess.run([path, '--version'], capture_output=True, timeout=5)
                if result.returncode == 0:
                    return path
            except:
                continue
    
    # Try 'which python3'
    try:
        result = subprocess.run(['which', 'python3'], capture_output=True, timeout=5)
        if result.returncode == 0:
            path = result.stdout.decode().strip()
            if path and os.path.exists(path):
                return path
    except:
        pass
    
    return None


def check_homebrew() -> bool:
    """Check if Homebrew is installed."""
    try:
        result = subprocess.run(['which', 'brew'], capture_output=True, timeout=5)
        return result.returncode == 0
    except:
        return False


def install_python_via_homebrew() -> bool:
    """Install Python via Homebrew."""
    output_json("progress", {"status": "Installing Python via Homebrew...", "percent": 5})
    
    if not check_homebrew():
        output_json("error", {"message": "Homebrew is not installed. Please install Homebrew first."})
        return False
    
    try:
        # Try python@3.11 first
        result = subprocess.run(['brew', 'install', 'python@3.11'], capture_output=True, timeout=600)
        if result.returncode != 0:
            # Try python3 without version
            result = subprocess.run(['brew', 'install', 'python3'], capture_output=True, timeout=600)
            if result.returncode != 0:
                output_json("error", {"message": "Failed to install Python via Homebrew"})
                return False
        
        # Find installed Python
        python_path = find_python()
        if python_path:
            output_json("progress", {"status": f"Python installed: {python_path}", "percent": 10})
            return True
        else:
            output_json("error", {"message": "Python installed but could not find executable"})
            return False
    except Exception as e:
        output_json("error", {"message": f"Error installing Python: {e}"})
        return False


def create_venv(base_dir: str, python_path: str) -> bool:
    """Create Python virtual environment."""
    global _venv_path, _pip_path
    
    venv_path = os.path.join(base_dir, 'venv')
    venv_python = os.path.join(venv_path, 'bin', 'python')
    
    # Check if venv already exists
    if os.path.exists(venv_python):
        output_json("progress", {"status": "Virtual environment already exists", "percent": 15})
        _venv_path = venv_path
        _pip_path = os.path.join(venv_path, 'bin', 'pip')
        return True
    
    output_json("progress", {"status": "Creating Python virtual environment...", "percent": 12})
    
    try:
        result = subprocess.run([python_path, '-m', 'venv', venv_path], capture_output=True, timeout=120)
        if result.returncode != 0:
            output_json("error", {"message": f"Failed to create venv: {result.stderr.decode()}"})
            return False
        
        _venv_path = venv_path
        _pip_path = os.path.join(venv_path, 'bin', 'pip')
        
        # Upgrade pip
        output_json("progress", {"status": "Upgrading pip...", "percent": 14})
        subprocess.run([_pip_path, 'install', '--upgrade', 'pip', '--quiet'], capture_output=True, timeout=60)
        
        return True
    except Exception as e:
        output_json("error", {"message": f"Error creating venv: {e}"})
        return False


def clone_firered(base_dir: str) -> bool:
    """Extract FireRedASR2S from local ZIP file."""
    global _asr_path
    
    firered_dir = os.path.join(base_dir, 'FireRedASR2S')
    
    # Check if already extracted with source code
    # Must have both the directory and the fireredasr2s module
    if os.path.exists(firered_dir) and os.path.exists(os.path.join(firered_dir, 'fireredasr2s')):
        output_json("progress", {"status": "FireRedASR2S already installed", "percent": 20})
        _asr_path = firered_dir
        return True
    
    # Directory exists but no source code - need to extract
    pretrained_backup = None
    if os.path.exists(firered_dir):
        # Backup pretrained_models if exists
        pretrained_dir = os.path.join(firered_dir, 'pretrained_models')
        if os.path.exists(pretrained_dir):
            import tempfile
            pretrained_backup = tempfile.mkdtemp(prefix='pretrained_backup_')
            output_json("progress", {"status": "Backing up pretrained models...", "percent": 17})
            import shutil
            shutil.copytree(pretrained_dir, os.path.join(pretrained_backup, 'pretrained_models'))
        
        # Remove the directory using rm -rf
        output_json("progress", {"status": "Removing incomplete installation...", "percent": 18})
        try:
            subprocess.run(['rm', '-rf', firered_dir], check=True, timeout=60)
        except subprocess.CalledProcessError as e:
            output_json("error", {"message": f"Failed to remove directory: {e}"})
            return False
    
    output_json("progress", {"status": "Extracting FireRedASR2S...", "percent": 19})
    
    try:
        import zipfile
        import tempfile
        import shutil
        
        # Find the ZIP file (same directory as this script)
        script_dir = os.path.dirname(os.path.abspath(__file__))
        zip_path = os.path.join(script_dir, 'FireRedASR2S-main.zip')
        
        if not os.path.exists(zip_path):
            output_json("error", {"message": f"FireRedASR2S ZIP file not found at {zip_path}"})
            return False
        
        # Extract to temp directory first
        temp_extract = tempfile.mkdtemp()
        with zipfile.ZipFile(zip_path, 'r') as zf:
            zf.extractall(temp_extract)
        
        # Move the extracted directory to target
        extracted_dir = os.path.join(temp_extract, 'FireRedASR2S-main')
        if os.path.exists(extracted_dir):
            shutil.move(extracted_dir, firered_dir)
            shutil.rmtree(temp_extract)
        else:
            output_json("error", {"message": "Failed to find extracted directory in ZIP"})
            shutil.rmtree(temp_extract)
            return False
        
        # Restore pretrained_models if backed up
        if pretrained_backup:
            output_json("progress", {"status": "Restoring pretrained models...", "percent": 20})
            pretrained_dir = os.path.join(firered_dir, 'pretrained_models')
            os.makedirs(pretrained_dir, exist_ok=True)
            shutil.copytree(os.path.join(pretrained_backup, 'pretrained_models'), pretrained_dir, dirs_exist_ok=True)
            shutil.rmtree(pretrained_backup)
        
        _asr_path = firered_dir
        output_json("progress", {"status": "FireRedASR2S extracted successfully", "percent": 21})
        return True
    except Exception as e:
        output_json("error", {"message": f"Failed to extract FireRedASR2S: {e}"})
        return False
        
        # Restore pretrained_models if backed up
        if pretrained_backup:
            output_json("progress", {"status": "Restoring pretrained models...", "percent": 20})
            pretrained_dir = os.path.join(firered_dir, 'pretrained_models')
            os.makedirs(pretrained_dir, exist_ok=True)
            shutil.copytree(os.path.join(pretrained_backup, 'pretrained_models'), pretrained_dir, dirs_exist_ok=True)
            shutil.rmtree(pretrained_backup)
        
        _asr_path = firered_dir
        return True
    except Exception as e:
        output_json("error", {"message": f"Error cloning FireRedASR2S: {e}"})
        return False


def install_dependencies(base_dir: str) -> bool:
    """Install Python dependencies."""
    if not _pip_path:
        output_json("error", {"message": "pip not available"})
        return False
    
    output_json("progress", {"status": "Installing dependencies...", "percent": 25})
    
    # Install dependencies one by one with progress
    dependencies = [
        ('torch', 30),
        ('torchaudio', 35),
        ('transformers>=4.40.0', 40),
        ('numpy>=1.24.0', 42),
        ('cn2an', 44),
        ('kaldiio', 46),
        ('kaldi_native_fbank', 48),
        ('sentencepiece', 50),
        ('soundfile', 52),
        ('textgrid', 54),
        ('peft>=0.13.2', 56),
        ('huggingface_hub>=0.34.0', 58),
        ('modelscope', 60),
    ]
    
    for dep, percent in dependencies:
        if _install_canceled:
            output_json("canceled", {})
            return False
        
        output_json("progress", {"status": f"Installing {dep}...", "percent": percent})
        try:
            result = subprocess.run(
                [_pip_path, 'install', dep, '--quiet'],
                capture_output=True, timeout=300
            )
            if result.returncode != 0:
                output_json("warning", {"message": f"Warning: Failed to install {dep}"})
        except Exception as e:
            output_json("warning", {"message": f"Warning: Error installing {dep}: {e}"})
    
    output_json("progress", {"status": "Dependencies installed", "percent": 65})
    return True


def get_dir_size(path: str) -> int:
    """Get total size of directory using os.scandir for better performance."""
    total = 0
    try:
        # Use os.scandir which is much faster than Path.rglob
        for entry in os.scandir(path):
            try:
                if entry.is_file(follow_symlinks=False):
                    total += entry.stat(follow_symlinks=False).st_size
                elif entry.is_dir(follow_symlinks=False):
                    total += get_dir_size(entry.path)
            except (OSError, PermissionError):
                pass
    except (OSError, PermissionError):
        pass
    return total


def get_dir_size_fast(path: str) -> int:
    """Get directory size using du command (faster for large directories on macOS/Linux)."""
    try:
        # Use du command for faster size calculation
        result = subprocess.run(
            ['du', '-sk', path],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            # du -sk returns size in 1KB blocks
            size_kb = int(result.stdout.split()[0])
            return size_kb * 1024
    except (subprocess.TimeoutExpired, ValueError, IndexError):
        pass
    
    # Fallback to Python method
    return get_dir_size(path)


def download_model(model_id: str, local_dir: str, progress_start: float, progress_end: float, test_mode: bool = False, test_size_mb: int = 1) -> bool:
    """Download a model from ModelScope.
    
    Args:
        model_id: Model ID on ModelScope
        local_dir: Local directory to save model
        progress_start: Start progress percentage (0.0-1.0)
        progress_end: End progress percentage (0.0-1.0)
        test_mode: If True, only download test_size_mb MB for testing
        test_size_mb: Size in MB to download in test mode
    """
    output_json("debug", {"message": f"download_model called: model_id={model_id}, local_dir={local_dir}, test_mode={test_mode}"})
    
    marker_file = os.path.join(local_dir, '.download_complete')
    
    # Check if already downloaded
    if os.path.exists(marker_file):
        output_json("progress", {"status": f"Model {model_id} already downloaded", "percent": progress_end * 100})
        output_json("debug", {"message": f"Model {model_id} already exists, skipping download"})
        return True
    
    output_json("progress", {"status": f"Downloading {model_id}...", "percent": progress_start * 100})
    output_json("debug", {"message": f"Starting download for {model_id}"})
    
    # Test mode: simulate download
    if test_mode:
        output_json("progress", {"status": f"[TEST MODE] Simulating download of {test_size_mb}MB...", "percent": progress_start * 100})
        os.makedirs(local_dir, exist_ok=True)
        
        # Simulate download progress
        test_size_bytes = test_size_mb * 1024 * 1024
        chunk_size = 100 * 1024  # 100KB chunks
        downloaded = 0
        
        while downloaded < test_size_bytes:
            # Write dummy data
            chunk = min(chunk_size, test_size_bytes - downloaded)
            dummy_file = os.path.join(local_dir, f'test_data_{downloaded}.bin')
            with open(dummy_file, 'wb') as f:
                f.write(b'\x00' * chunk)
            
            downloaded += chunk
            progress = progress_start + (progress_end - progress_start) * (downloaded / test_size_bytes)
            size_mb = downloaded / (1024 * 1024)
            output_json("download_progress", {
                "model": model_id,
                "size_mb": round(size_mb, 1),
                "size_bytes": downloaded
            })
            output_json("progress", {"status": f"[TEST] Downloaded {round(size_mb, 1)}MB", "percent": round(progress * 100, 1)})
            time.sleep(0.1)  # Simulate network delay
        
        # Create completion marker
        with open(marker_file, 'w') as f:
            f.write(f"model_id: {model_id}\n")
            f.write(f"download_time: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"size: {downloaded}\n")
            f.write(f"test_mode: true\n")
        
        output_json("progress", {"status": f"[TEST] Downloaded {model_id} ({test_size_mb}MB)", "percent": progress_end * 100})
        return True
    
    try:
        # Use modelscope download command instead of Python API
        # This is more reliable and provides better progress output
        output_json("debug", {"message": f"Starting model download using modelscope CLI: {model_id}"})
        
        # Create directory
        os.makedirs(local_dir, exist_ok=True)
        
        # Build command
        modelscope_cmd = os.path.join(os.path.dirname(_pip_path), 'modelscope')
        cmd = [
            modelscope_cmd,
            'download',
            '--model', model_id,
            '--local_dir', local_dir,
        ]
        
        output_json("debug", {"message": f"Running command: {' '.join(cmd)}"})
        
        # Start download process in background
        download_process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        
        # Progress reporter thread
        stop_reporter = threading.Event()
        last_size = [0]
        report_count = [0]
        
        def report_progress():
            while not stop_reporter.is_set():
                try:
                    report_count[0] += 1
                    size = get_dir_size_fast(local_dir) if os.path.exists(local_dir) else 0
                    
                    if size != last_size[0]:
                        last_size[0] = size
                        size_mb = size / (1024 * 1024)
                        output_json("download_progress", {
                            "model": model_id,
                            "size_mb": round(size_mb, 1),
                            "size_bytes": size
                        })
                        output_json("progress", {
                            "status": f"Downloading {model_id.split('/')[-1]}: {round(size_mb, 1)} MB",
                            "percent": progress_start * 100
                        })
                except Exception as e:
                    pass
                time.sleep(2)
        
        reporter = threading.Thread(target=report_progress)
        reporter.daemon = True
        reporter.start()
        
        # Wait for download to complete
        stdout, stderr = download_process.communicate(timeout=7200)  # 2 hour timeout
        stop_reporter.set()
        reporter.join(timeout=2)
        
        if download_process.returncode != 0:
            output_json("error", {"message": f"Download failed: {stderr}"})
            return False
        
        output_json("debug", {"message": f"Download completed. stdout: {stdout[:500] if stdout else 'empty'}"})
        
        # Create completion marker
        final_size = get_dir_size(local_dir)
        with open(marker_file, 'w') as f:
            f.write(f"model_id: {model_id}\n")
            f.write(f"download_time: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"size: {final_size}\n")
        
        output_json("progress", {"status": f"Downloaded {model_id}", "percent": progress_end * 100})
        return True
        
    except Exception as e:
        output_json("error", {"message": f"Failed to download {model_id}: {e}"})
        return False


def download_models(base_dir: str, test_mode: bool = False, test_size_mb: int = 1) -> bool:
    """Download required ASR models.
    
    Args:
        base_dir: Base directory for ASR installation
        test_mode: If True, only download test_size_mb MB for testing
        test_size_mb: Size in MB to download in test mode
    """
    global _asr_path
    
    if not _asr_path:
        _asr_path = os.path.join(base_dir, 'FireRedASR2S')
    
    models_dir = os.path.join(_asr_path, 'pretrained_models')
    os.makedirs(models_dir, exist_ok=True)
    
    # Download FireRedASR2-AED (progress: 0.65 - 0.85)
    if not download_model('xukaituo/FireRedASR2-AED', os.path.join(models_dir, 'FireRedASR2-AED'), 0.65, 0.85, test_mode, test_size_mb):
        return False
    
    # Download FireRedVAD (progress: 0.85 - 0.95)
    if not download_model('xukaituo/FireRedVAD', os.path.join(models_dir, 'FireRedVAD'), 0.85, 0.95, test_mode, test_size_mb):
        return False
    
    return True


def check_installed(base_dir: str) -> Dict[str, Any]:
    """Check if ASR is installed."""
    venv_python = os.path.join(base_dir, 'venv', 'bin', 'python')
    models_dir = os.path.join(base_dir, 'FireRedASR2S', 'pretrained_models')
    
    result = {
        "venv_exists": os.path.exists(venv_python),
        "firered_exists": os.path.exists(os.path.join(base_dir, 'FireRedASR2S')),
        "models": {},
        "installed": False
    }
    
    # Check models
    for model in ['FireRedASR2-AED', 'FireRedVAD']:
        marker = os.path.join(models_dir, model, '.download_complete')
        result["models"][model] = os.path.exists(marker)
    
    # Check if fully installed
    if result["venv_exists"] and all(result["models"].values()):
        result["installed"] = True
    
    return result


def cmd_install(args):
    """Install ASR environment."""
    base_dir = get_base_dir(args)
    
    test_mode = getattr(args, 'test_mode', False)
    test_size_mb = getattr(args, 'test_size_mb', 1)
    
    output_json("progress", {"status": "Starting installation...", "percent": 0})
    
    # Step 1: Find or install Python
    python_path = find_python()
    if not python_path:
        output_json("progress", {"status": "Python not found, installing via Homebrew...", "percent": 2})
        if not install_python_via_homebrew():
            return 1
        python_path = find_python()
        if not python_path:
            output_json("error", {"message": "Could not find Python after installation"})
            return 1
    
    output_json("progress", {"status": f"Python found: {python_path}", "percent": 10})
    
    # Step 2: Create virtual environment
    if not create_venv(base_dir, python_path):
        return 1
    
    # Step 3: Clone FireRedASR2S
    if not clone_firered(base_dir):
        return 1
    
    # Step 4: Install dependencies
    if not install_dependencies(base_dir):
        return 1
    
    # Step 5: Download models (if requested)
    # Debug output for parameter
    output_json("debug", {"download_models_param": getattr(args, 'download_models', 'NOT_SET')})
    
    if args.download_models:
        output_json("progress", {"status": "Activating virtual environment for model download...", "percent": 66})
        # Activate venv to ensure modelscope is accessible
        if not activate_venv(base_dir):
            output_json("error", {"message": "Failed to activate virtual environment for model download"})
            return 1
        if not download_models(base_dir, test_mode, test_size_mb):
            return 1
    else:
        output_json("debug", {"message": "Skipping model download (download_models=False)"})
    
    output_json("progress", {"status": "Installation complete!", "percent": 100})
    output_json("complete", {"success": True})
    return 0


def cmd_download_models(args):
    """Download models only."""
    base_dir = get_base_dir(args)
    
    test_mode = getattr(args, 'test_mode', False)
    test_size_mb = getattr(args, 'test_size_mb', 1)
    
    output_json("progress", {"status": "Starting model download...", "percent": 0})
    
    # Check if venv exists and activate it
    if not activate_venv(base_dir):
        output_json("error", {"message": "ASR not installed or venv activation failed. Run 'install' first."})
        return 1
    
    # Verify modelscope is available
    try:
        import modelscope
        output_json("debug", {"message": f"modelscope found at {modelscope.__file__}"})
    except ImportError as e:
        output_json("error", {"message": f"modelscope not found in venv. Please reinstall dependencies. Error: {e}"})
        return 1
    
    if not download_models(base_dir, test_mode, test_size_mb):
        return 1
    
    output_json("complete", {"success": True})
    return 0


def cmd_start_service(args):
    """Start ASR service."""
    global _service_process
    
    base_dir = get_base_dir(args)
    host = args.host or '127.0.0.1'
    port = args.port or 8765
    
    # Check if installed
    status = check_installed(base_dir)
    if not status["installed"]:
        output_json("error", {"message": "ASR not fully installed"})
        return 1
    
    venv_python = os.path.join(base_dir, 'venv', 'bin', 'python')
    asr_path = os.path.join(base_dir, 'FireRedASR2S')
    service_script = os.path.join(base_dir, 'asr_service.py')
    
    # Create service script if not exists
    if not os.path.exists(service_script):
        create_service_script(service_script)
    
    output_json("progress", {"status": f"Starting ASR service on {host}:{port}...", "percent": 0})
    
    # Set up environment
    env = os.environ.copy()
    env['PYTHONPATH'] = asr_path
    
    try:
        _service_process = subprocess.Popen(
            [venv_python, service_script, '--host', host, '--port', str(port), '--asr-path', asr_path],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        
        # Wait for service to start
        time.sleep(3)
        
        # Check if running
        import urllib.request
        try:
            response = urllib.request.urlopen(f'http://{host}:{port}/status', timeout=5)
            if response.status == 200:
                output_json("service_started", {"host": host, "port": port})
                return 0
        except:
            pass
        
        output_json("error", {"message": "Service failed to start"})
        return 1
        
    except Exception as e:
        output_json("error", {"message": f"Error starting service: {e}"})
        return 1


def cmd_repair(args):
    """Repair ASR installation."""
    base_dir = get_base_dir(args)
    
    output_json("progress", {"status": "Starting repair...", "percent": 0})
    
    # Check if models are complete (to restore them later)
    models_dir = os.path.join(base_dir, 'FireRedASR2S', 'pretrained_models')
    models_backup = None
    
    aed_marker = os.path.join(models_dir, 'FireRedASR2-AED', '.download_complete')
    vad_marker = os.path.join(models_dir, 'FireRedVAD', '.download_complete')
    
    if os.path.exists(aed_marker) and os.path.exists(vad_marker):
        # Backup models
        models_backup = os.path.join(base_dir, f'models_backup_{int(time.time())}')
        output_json("progress", {"status": "Backing up models...", "percent": 5})
        shutil.copytree(models_dir, models_backup)
    
    # Uninstall
    output_json("progress", {"status": "Uninstalling...", "percent": 10})
    cmd_uninstall_args = argparse.Namespace(base_dir=base_dir)
    cmd_uninstall(cmd_uninstall_args)
    
    # Reinstall
    output_json("progress", {"status": "Reinstalling...", "percent": 30})
    cmd_install_args = argparse.Namespace(base_dir=base_dir, download_models=False)
    result = cmd_install(cmd_install_args)
    if result != 0:
        output_json("error", {"message": "Reinstall failed"})
        return 1
    
    # Restore models if backup exists
    if models_backup and os.path.exists(models_backup):
        output_json("progress", {"status": "Restoring models...", "percent": 80})
        os.makedirs(models_dir, exist_ok=True)
        for model in ['FireRedASR2-AED', 'FireRedVAD']:
            src = os.path.join(models_backup, model)
            dst = os.path.join(models_dir, model)
            if os.path.exists(src):
                shutil.copytree(src, dst)
        
        # Clean up backup
        shutil.rmtree(models_backup)
        output_json("progress", {"status": "Models restored", "percent": 95})
    else:
        # Download models
        if not download_models(base_dir):
            return 1
    
    output_json("progress", {"status": "Repair complete!", "percent": 100})
    output_json("complete", {"success": True})
    return 0


def cmd_uninstall(args):
    """Uninstall ASR."""
    base_dir = get_base_dir(args)
    
    output_json("progress", {"status": "Uninstalling...", "percent": 0})
    
    # Stop service if running
    global _service_process
    if _service_process:
        _service_process.terminate()
        _service_process = None
    
    # Delete venv
    venv_path = os.path.join(base_dir, 'venv')
    if os.path.exists(venv_path):
        output_json("progress", {"status": "Removing virtual environment...", "percent": 30})
        shutil.rmtree(venv_path)
    
    # Delete FireRedASR2S
    firered_path = os.path.join(base_dir, 'FireRedASR2S')
    if os.path.exists(firered_path):
        output_json("progress", {"status": "Removing FireRedASR2S...", "percent": 60})
        shutil.rmtree(firered_path)
    
    # Delete service script
    service_script = os.path.join(base_dir, 'asr_service.py')
    if os.path.exists(service_script):
        os.remove(service_script)
    
    output_json("progress", {"status": "Uninstall complete!", "percent": 100})
    output_json("complete", {"success": True})
    return 0


def cmd_check_status(args):
    """Check ASR installation status."""
    base_dir = get_base_dir(args)
    status = check_installed(base_dir)
    output_json("status", status)
    return 0


def cmd_transcribe(args):
    """Transcribe audio file and return subtitles."""
    base_dir = get_base_dir(args)
    audio_path = args.audio_path
    
    print(f"[Transcribe] Base dir: {base_dir}", file=sys.stderr)
    print(f"[Transcribe] Audio path: {audio_path}", file=sys.stderr)
    
    # Check if audio file exists
    if not os.path.exists(audio_path):
        output_json("error", {"message": f"Audio file not found: {audio_path}"})
        return 1
    
    # Check if ASR is installed
    status = check_installed(base_dir)
    if not status.get("installed", False):
        output_json("error", {"message": "ASR not installed. Please install first."})
        return 1
    
    # Activate virtual environment
    if not activate_venv(base_dir):
        output_json("error", {"message": "Failed to activate virtual environment"})
        return 1
    
    # Find FireRedASR2S path
    firered_path = os.path.join(base_dir, "FireRedASR2S")
    if not os.path.exists(firered_path):
        output_json("error", {"message": f"FireRedASR2S not found at {firered_path}"})
        return 1
    
    # Add to sys.path
    if firered_path not in sys.path:
        sys.path.insert(0, firered_path)
        print(f"[Transcribe] Added to sys.path: {firered_path}", file=sys.stderr)
    
    # Check models
    models_dir = os.path.join(firered_path, "pretrained_models")
    required_models = ["FireRedASR2-AED", "FireRedVAD"]
    for model in required_models:
        model_path = os.path.join(models_dir, model)
        if not os.path.exists(model_path):
            output_json("error", {"message": f"Model not found: {model}"})
            return 1
    
    try:
        # Change to FireRedASR2S directory for relative paths in config
        original_cwd = os.getcwd()
        os.chdir(firered_path)
        print(f"[Transcribe] Changed working directory to: {firered_path}", file=sys.stderr)
        
        # Import and initialize ASR system
        print("[Transcribe] Importing FireRedASR2S...", file=sys.stderr)
        from fireredasr2s import FireRedAsr2System, FireRedAsr2SystemConfig
        from fireredasr2s.fireredvad.vad import FireRedVadConfig
        from fireredasr2s.fireredasr2.asr import FireRedAsr2Config
        
        print("[Transcribe] Creating ASR system...", file=sys.stderr)
        # Create configs with GPU disabled (macOS doesn't have CUDA)
        vad_config = FireRedVadConfig(use_gpu=False)
        asr_config = FireRedAsr2Config(use_gpu=False)
        
        # Create main config with only available models
        config = FireRedAsr2SystemConfig(
            enable_vad=True,
            enable_lid=False,  # FireRedLID model not available
            enable_punc=False,  # FireRedPunc model not available
            vad_config=vad_config,
            asr_config=asr_config,
        )
        asr_system = FireRedAsr2System(config)
        
        print("[Transcribe] Processing audio...", file=sys.stderr)
        result = asr_system.process(audio_path)
        
        # Restore original working directory
        os.chdir(original_cwd)
        
        print(f"[Transcribe] Result: {result}", file=sys.stderr)
        
        # Format result
        sentences = []
        for sent in result.get("sentences", []):
            sentences.append({
                "start_ms": sent.get("start_ms", 0),
                "end_ms": sent.get("end_ms", 0),
                "text": sent.get("text", ""),
            })
        
        output_json("transcription", {
            "success": True,
            "sentences": sentences,
            "duration_ms": int(result.get("dur_s", 0) * 1000),
            "text": result.get("text", "")
        })
        return 0
        
    except ImportError as e:
        output_json("error", {"message": f"Failed to import FireRedASR2S: {e}"})
        return 1
    except Exception as e:
        import traceback
        traceback.print_exc(file=sys.stderr)
        output_json("error", {"message": f"Transcription failed: {e}"})
        return 1


def create_service_script(script_path: str):
    """Create the ASR service script."""
    script_content = '''#!/usr/bin/env python3
"""Embedded FireRedASR2S HTTP Service"""
import argparse
import json
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

# Add FireRedASR2S to path
firered_path = os.environ.get("ASR_PATH", "") or os.environ.get("PYTHONPATH", "")
if firered_path:
    sys.path.insert(0, firered_path)

asr_system = None

class ASRHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass
    
    def _send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())
    
    def do_GET(self):
        if self.path == '/status':
            self._send_json({'running': True})
        else:
            self.send_error(404)
    
    def do_POST(self):
        if self.path == '/transcribe':
            try:
                content_length = int(self.headers.get('Content-Length', 0))
                data = json.loads(self.rfile.read(content_length).decode())
                audio_path = data.get('audio_path')
                
                if not audio_path or not os.path.exists(audio_path):
                    self._send_json({'error': 'Audio file not found'}, 400)
                    return
                
                global asr_system
                if asr_system is None:
                    from fireredasr2s import FireRedASR2S
                    asr_system = FireRedASR2S()
                
                result = asr_system.transcribe(audio_path)
                self._send_json({'text': result})
            except Exception as e:
                self._send_json({'error': str(e)}, 500)
        else:
            self.send_error(404)

def main():
    parser = argparse.ArgumentParser(description='ASR HTTP Service')
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--asr-path', required=True)
    args = parser.parse_args()
    
    os.environ['ASR_PATH'] = args.asr_path
    
    server = HTTPServer((args.host, args.port), ASRHandler)
    print(f"ASR service running on {args.host}:{args.port}")
    server.serve_forever()

if __name__ == '__main__':
    main()
'''
    
    with open(script_path, 'w') as f:
        f.write(script_content)


def signal_handler(sig, frame):
    """Handle interrupt signals."""
    global _install_canceled
    _install_canceled = True
    output_json("canceled", {})
    sys.exit(1)


def main():
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    parser = argparse.ArgumentParser(description='ASR Manager')
    subparsers = parser.add_subparsers(dest='command', help='Command to run')
    
    # Install command
    install_parser = subparsers.add_parser('install', help='Install ASR environment')
    install_parser.add_argument('--download-models', action='store_true', help='Download models')
    install_parser.add_argument('--base-dir', help='Base directory for installation')
    install_parser.add_argument('--test-mode', action='store_true', help='Test mode: simulate download')
    install_parser.add_argument('--test-size-mb', type=int, default=1, help='Size in MB for test mode (default: 1)')
    
    # Download models command
    download_parser = subparsers.add_parser('download-models', help='Download ASR models')
    download_parser.add_argument('--base-dir', help='Base directory')
    download_parser.add_argument('--test-mode', action='store_true', help='Test mode: simulate download')
    download_parser.add_argument('--test-size-mb', type=int, default=1, help='Size in MB for test mode (default: 1)')
    
    # Start service command
    service_parser = subparsers.add_parser('start-service', help='Start ASR HTTP service')
    service_parser.add_argument('--host', default='127.0.0.1', help='Host to bind')
    service_parser.add_argument('--port', type=int, default=8765, help='Port to bind')
    service_parser.add_argument('--base-dir', help='Base directory')
    
    # Repair command
    repair_parser = subparsers.add_parser('repair', help='Repair ASR installation')
    repair_parser.add_argument('--base-dir', help='Base directory')
    
    # Uninstall command
    uninstall_parser = subparsers.add_parser('uninstall', help='Uninstall ASR')
    uninstall_parser.add_argument('--base-dir', help='Base directory')
    
    # Check status command
    status_parser = subparsers.add_parser('check-status', help='Check installation status')
    status_parser.add_argument('--base-dir', help='Base directory')
    
    # Transcribe command
    transcribe_parser = subparsers.add_parser('transcribe', help='Transcribe audio file')
    transcribe_parser.add_argument('audio_path', help='Path to audio file (16kHz mono WAV)')
    transcribe_parser.add_argument('--base-dir', help='Base directory')
    
    args = parser.parse_args()
    
    if args.command == 'install':
        return cmd_install(args)
    elif args.command == 'download-models':
        return cmd_download_models(args)
    elif args.command == 'start-service':
        return cmd_start_service(args)
    elif args.command == 'repair':
        return cmd_repair(args)
    elif args.command == 'uninstall':
        return cmd_uninstall(args)
    elif args.command == 'check-status':
        return cmd_check_status(args)
    elif args.command == 'transcribe':
        return cmd_transcribe(args)
    else:
        parser.print_help()
        return 1


if __name__ == '__main__':
    sys.exit(main())
