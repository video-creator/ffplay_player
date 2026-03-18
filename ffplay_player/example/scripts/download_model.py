#!/usr/bin/env python3
"""
Model download script with progress tracking and auto-retry.
Outputs progress in a structured format for Flutter to parse.
"""

import sys
import os
import time
import argparse
from pathlib import Path

# Progress tracking globals
_downloaded = 0
_total = 0
_start_time = 0
_last_update = 0
_last_downloaded = 0

def format_size(size_bytes):
    """Format size in human readable format."""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    elif size_bytes < 1024 * 1024 * 1024:
        return f"{size_bytes / 1024 / 1024:.1f} MB"
    else:
        return f"{size_bytes / 1024 / 1024 / 1024:.2f} GB"


def download_with_progress(repo_id: str, local_dir: str, max_retries: int = 3):
    """Download model with progress output and auto-retry."""
    global _downloaded, _total, _start_time, _last_update, _last_downloaded
    
    for attempt in range(max_retries):
        try:
            if attempt > 0:
                print(f"[RETRY] Attempt {attempt + 1}/{max_retries}...")
                sys.stdout.flush()
            
            from huggingface_hub import snapshot_download, configure_http_backend
            from huggingface_hub.utils import tqdm as hf_tqdm
            import io
            
            # Check if directory already exists and has content
            if os.path.exists(local_dir):
                existing_files = list(Path(local_dir).rglob('*'))
                existing_size = sum(f.stat().st_size for f in existing_files if f.is_file())
                if existing_size > 100 * 1024 * 1024:  # > 100MB
                    print(f"[INFO] Found existing download ({format_size(existing_size)}), resuming...")
                    sys.stdout.flush()
            
            print(f"[START] Downloading {repo_id}...")
            sys.stdout.flush()
            
            _start_time = time.time()
            _last_update = _start_time
            
            # Create a custom tqdm class that outputs progress
            class ProgressTqdm(hf_tqdm):
                def __init__(self, *args, **kwargs):
                    super().__init__(*args, **kwargs)
                    self._last_n = 0
                    self._last_update = time.time()
                
                def update(self, n=1):
                    result = super().update(n)
                    current_time = time.time()
                    elapsed = current_time - self._last_update
                    
                    # Update every 0.3 seconds
                    if elapsed >= 0.3:
                        try:
                            downloaded = self.n
                            total = self.total if self.total else 0
                            desc = self.desc if self.desc else ""
                            
                            if total > 0:
                                pct = downloaded / total * 100
                                speed = (downloaded - self._last_n) / elapsed if elapsed > 0 else 0
                                
                                # Output: [PROGRESS] downloaded,total,percent,speed_bps,filename
                                print(f"[PROGRESS] {downloaded},{total},{pct:.1f},{int(speed)},{desc}")
                                sys.stdout.flush()
                                
                                self._last_n = downloaded
                                self._last_update = current_time
                        except Exception as e:
                            pass
                    
                    return result
            
            # Monkey-patch tqdm
            import huggingface_hub.file_download
            original_tqdm = huggingface_hub.file_download.tqdm
            huggingface_hub.file_download.tqdm = ProgressTqdm
            
            try:
                # Download with progress
                snapshot_download(
                    repo_id=repo_id,
                    local_dir=local_dir,
                    resume_download=True,
                    max_workers=4,
                    tqdm_class=ProgressTqdm,
                )
            finally:
                # Restore original tqdm
                huggingface_hub.file_download.tqdm = original_tqdm
            
            # Calculate total time
            total_time = time.time() - _start_time
            
            # Get final size
            final_size = 0
            if os.path.exists(local_dir):
                final_size = sum(f.stat().st_size for f in Path(local_dir).rglob('*') if f.is_file())
            
            print(f"[COMPLETE] Download finished in {total_time:.1f}s, total size: {format_size(final_size)}")
            sys.stdout.flush()
            return 0
            
        except KeyboardInterrupt:
            print("[ABORT] Download interrupted by user")
            sys.stdout.flush()
            return 1
        except Exception as e:
            print(f"[ERROR] {str(e)}")
            sys.stdout.flush()
            if attempt < max_retries - 1:
                wait_time = 5 * (attempt + 1)
                print(f"[WAIT] Retrying in {wait_time} seconds...")
                sys.stdout.flush()
                time.sleep(wait_time)
            else:
                print("[FAILED] Max retries reached")
                sys.stdout.flush()
                return 1
    
    return 1


def main():
    parser = argparse.ArgumentParser(description='Download Hugging Face model with progress')
    parser.add_argument('--repo', required=True, help='Repository ID (e.g., FireRedTeam/FireRedASR2-AED)')
    parser.add_argument('--local-dir', required=True, help='Local directory to save model')
    parser.add_argument('--max-retries', type=int, default=3, help='Maximum retry attempts')
    
    args = parser.parse_args()
    
    # Ensure output directory exists
    os.makedirs(args.local_dir, exist_ok=True)
    
    exit_code = download_with_progress(args.repo, args.local_dir, args.max_retries)
    sys.exit(exit_code)


if __name__ == '__main__':
    main()
