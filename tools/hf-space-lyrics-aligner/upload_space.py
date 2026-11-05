"""Uploads the static Space (only the files the page needs) to Hugging Face.

    uv run --with huggingface_hub python upload_space.py [--repo aaatmy/lyrics-aligner]

The token is read from ~/.cache/huggingface/token (huggingface_hub default).
eval/ (local evaluation scripts) and any audio stay out of the Space.
"""
import argparse
from pathlib import Path

from huggingface_hub import HfApi

HERE = Path(__file__).resolve().parent
FILES = ["README.md", "index.html", "style.css", "main.js", "worker.js", "whisper_worker.js", "models.js", "i18n.js", "study.json"]

parser = argparse.ArgumentParser()
parser.add_argument("--repo", default="aaatmy/lyrics-aligner")
parser.add_argument("--message", default="Update the Space")
args = parser.parse_args()

api = HfApi()
api.create_repo(args.repo, repo_type="space", space_sdk="static", private=False, exist_ok=True)
allow = FILES + ["lib/*.js"]
api.upload_folder(
    folder_path=str(HERE),
    repo_id=args.repo,
    repo_type="space",
    allow_patterns=allow,
    delete_patterns=["*.js", "lib/*.js", "*.json", "*.css", "*.html"],
    commit_message=args.message,
)
print(f"https://huggingface.co/spaces/{args.repo}")
